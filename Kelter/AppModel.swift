import AppKit
import Darwin
import Observation
import WineKit

enum SidebarItem: Hashable {
    case catalog
    case recipe(String)
    case myApps
    case app(UUID)
    case controllers
    case setup
    case components
    case bottle(String)
}

/// Zentraler Zustand der App. Die eigentliche Arbeit erledigt WineKit.
@Observable
final class AppModel {
    enum RosettaState: Equatable {
        case checking
        case notNeeded
        case installed
        case missing
        case installing
        case failed(String)
    }

    /// Läuft in einer Bottle gerade etwas?
    enum BottleRunState: Equatable {
        case stopped
        /// Nur Wines Hintergrunddienste (wineserver, services.exe …).
        case background
        case running(Int)
    }

    /// Ein eingebautes Wine-Werkzeug, das in jeder Bottle vorhanden ist.
    enum BuiltinProgram: String, CaseIterable, Identifiable {
        case winecfg, notepad, regedit, winefile, taskmgr, joystick

        var id: String { rawValue }

        var title: String {
            switch self {
            case .winecfg: "Wine-Konfiguration"
            case .notepad: "Editor (Notepad)"
            case .regedit: "Registrierungs-Editor"
            case .winefile: "Dateimanager"
            case .taskmgr: "Task-Manager"
            case .joystick: "Joystick-Einstellungen"
            }
        }

        var systemImage: String {
            switch self {
            case .winecfg: "gearshape"
            case .notepad: "doc.text"
            case .regedit: "list.bullet.indent"
            case .winefile: "folder"
            case .taskmgr: "chart.bar.xaxis"
            case .joystick: "gamecontroller"
            }
        }

        var arguments: [String] {
            switch self {
            case .joystick: ["control", "joy.cpl"]
            default: [rawValue]
            }
        }
    }

    /// Eine App samt ihrer Bottle.
    struct AppRef: Identifiable, Hashable {
        let bottle: Bottle
        let app: InstalledApp
        var id: UUID { app.id }
    }

    /// CPU und RAM einer Gruppe von Prozessen.
    struct Usage: Equatable {
        var cpuPercent: Double = 0
        var residentBytes: UInt64 = 0
    }

    let paths = KelterPaths.standard

    // Navigation (hier statt in der Ansicht, damit Menübefehle sie ändern können)
    var selection: SidebarItem? = .setup
    var showNewBottle = false

    var rosetta: RosettaState = .checking
    var catalog = ComponentCatalog()
    var catalogWarning: String?
    var recipes = RecipeCatalog()
    var installed: [InstalledComponent] = []
    var settings = KelterSettings()
    /// Laufende Komponenten-Installationen: ID → aktueller Schritt.
    var installs: [String: InstallPhase] = [:]
    /// Laufende Katalog-Installationen: Rezept-ID → aktueller Schritt.
    var recipeInstalls: [String: RecipeInstallPhase] = [:]
    var recipeInstallStarted: [String: Date] = [:]
    var bottles: [Bottle] = []
    /// Apps je Bottle-ID.
    var appsByBottle: [String: [InstalledApp]] = [:]
    var icons: [UUID: NSImage] = [:]
    /// Bottle-ID → was gerade passiert („Wird eingerichtet …“).
    var bottleActivity: [String: String] = [:]
    /// Bottle-ID → Wine-Prozesse dieser Bottle (alle 2 s aktualisiert).
    var processesByBottle: [String: [WineProcessInfo]] = [:]
    /// PID → CPU-Auslastung in Prozent (100 % = ein voller Kern).
    var cpuPercent: [Int32: Double] = [:]
    /// Bottle-ID bzw. App-ID → zuletzt geschriebenes Log.
    var lastLog: [String: URL] = [:]
    var freeDiskSpace: Int64?
    var errorMessage: String?
    private(set) var hasStarted = false

    @ObservationIgnored private var installTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var recipeTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var recipeBottles: [String: String] = [:]
    @ObservationIgnored private var monitorTask: Task<Void, Never>?
    @ObservationIgnored private var cpuSamples: [Int32: (cpu: UInt64, time: Date)] = [:]
    @ObservationIgnored private let downloader = FileDownloader()

    private var componentStore: ComponentStore { ComponentStore(paths: paths) }
    private var bottleStore: BottleStore { BottleStore(paths: paths) }

    // MARK: Start

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        do {
            try paths.createDirectories()
        } catch {
            errorMessage = "Kelter kann seinen Datenordner nicht anlegen: \(error.localizedDescription)"
        }
        do {
            (catalog, catalogWarning) = try ComponentCatalog.load(paths: paths)
        } catch {
            errorMessage = error.localizedDescription
        }
        reloadRecipes()
        settings = KelterSettings.load(paths: paths)
        refreshInstalled()
        refreshBottles()
        freeDiskSpace = paths.availableDiskSpace()
        startMonitoring()
        await checkRosetta()
        selection = isReady ? .catalog : .setup
    }

    func reloadRecipes() {
        recipes = RecipeCatalog.load(paths: paths)
    }

    // MARK: Rosetta

    func checkRosetta() async {
        guard Rosetta.isAppleSilicon else {
            rosetta = .notNeeded
            return
        }
        rosetta = .checking
        rosetta = await Rosetta.isInstalled() ? .installed : .missing
    }

    func installRosetta(asAdministrator: Bool) async {
        rosetta = .installing
        do {
            if asAdministrator {
                try await Rosetta.installWithAdministratorPrivileges()
            } else {
                try await Rosetta.install()
            }
            await checkRosetta()
            if rosetta != .installed {
                rosetta = .failed("Die Installation ist durchgelaufen, aber Rosetta startet noch nicht. Ein Neustart des Macs hilft meist.")
            }
        } catch {
            rosetta = .failed(error.localizedDescription)
        }
    }

    var rosettaReady: Bool { rosetta == .installed || rosetta == .notNeeded }

    // MARK: Engines & Komponenten

    func refreshInstalled() {
        installed = componentStore.installed()
        // Standard-Engine reparieren, falls sie gelöscht wurde.
        if let id = settings.defaultEngineID, !installed.contains(where: { $0.id == id && $0.kind == .wine }) {
            settings.defaultEngineID = nil
        }
        // Läuft die Standard-Engine auf diesem Mac nicht, aber eine andere schon: umstellen.
        let usable = installedEngines.first { engineProblem($0.id) == nil }
        if let id = settings.defaultEngineID, engineProblem(id) != nil, let usable {
            settings.defaultEngineID = usable.id
        }
        if settings.defaultEngineID == nil, let first = usable ?? installedEngines.first {
            settings.defaultEngineID = first.id
        }
        try? settings.save(paths: paths)
    }

    /// Bekanntes Problem einer Komponente auf diesem Mac (aus dem Katalog), sonst nil.
    func engineProblem(_ id: String) -> String? {
        catalog.source(id: id)?.problem()
    }

    /// Wirft, wenn die Engine auf diesem Mac bekanntermaßen nicht funktioniert.
    private func checkCompatible(_ engine: WineEngine) throws {
        if let problem = engineProblem(engine.id) {
            throw KelterError.engineIncompatible(name: engine.name, problem: problem)
        }
    }

    /// Hängt die Erklärung aus dem Log an eine Fehlermeldung an (z. B. „Engine passt nicht“).
    private func explain(_ message: String, log: URL?) -> String {
        guard let log, let text = try? String(contentsOf: log, encoding: .utf8),
              let finding = LogAnalyzer.analyze(text).first(where: { $0.kind != .crash })
        else { return message }
        return message + "\n\n\(finding.title): \(finding.detail)"
    }

    var installedEngines: [InstalledComponent] { installed.filter { $0.kind == .wine } }

    func installedComponent(id: String) -> InstalledComponent? {
        installed.first { $0.id == id }
    }

    var defaultEngine: WineEngine? {
        guard let id = settings.defaultEngineID else { return nil }
        return componentStore.engine(id: id)
    }

    /// Bereit für Bottles: Rosetta da und Standard-Engine vollständig.
    var isReady: Bool {
        guard rosettaReady, let engine = defaultEngine else { return false }
        return engine.isComplete && engineProblem(engine.id) == nil
    }

    func setDefaultEngine(_ id: String) {
        settings.defaultEngineID = id
        save(settings)
    }

    /// Was für `source` geladen werden muss: fehlende Abhängigkeiten zuerst, dann `source` selbst.
    func installPlan(for source: ComponentSource) -> [ComponentSource] {
        catalog.installOrder(for: source).filter { $0.id == source.id || installedComponent(id: $0.id) == nil }
    }

    /// Gesamtgröße aller Downloads für `source` (inkl. fehlender Abhängigkeiten).
    func downloadSize(for source: ComponentSource) -> Int64 {
        installPlan(for: source).reduce(0) { $0 + ($1.sizeBytes ?? 0) }
    }

    /// Startet die Installation im Hintergrund (Fehler erscheinen als Hinweis).
    func install(_ source: ComponentSource) {
        let plan = installPlan(for: source)
        guard !plan.contains(where: { installTasks[$0.id] != nil }) else { return }
        let task = Task {
            do {
                try await runInstall(plan)
            } catch is CancellationError {
                // Vom Nutzer abgebrochen.
            } catch {
                errorMessage = error.localizedDescription
            }
            for item in plan { installTasks[item.id] = nil }
        }
        for item in plan { installTasks[item.id] = task }
    }

    /// Installiert und wartet (für Katalog-Installationen).
    func installAndWait(_ source: ComponentSource) async throws {
        try await runInstall(installPlan(for: source))
    }

    private func runInstall(_ plan: [ComponentSource]) async throws {
        for item in plan {
            installs[item.id] = .downloading(received: 0, expected: item.sizeBytes ?? 0)
        }
        defer {
            for item in plan { installs[item.id] = nil }
            refreshInstalled()
            freeDiskSpace = paths.availableDiskSpace()
        }
        let installer = ComponentInstaller(paths: paths, downloader: downloader)
        for item in plan {
            do {
                let component = try await installer.install(item) { phase in
                    Task { @MainActor in
                        // Nur übernehmen, solange die Installation noch läuft.
                        if self.installs[item.id] != nil { self.installs[item.id] = phase }
                    }
                }
                installs[item.id] = nil
                refreshInstalled()
                if component.kind == .wine, settings.defaultEngineID == nil {
                    setDefaultEngine(component.id)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw ComponentError(name: item.name, underlying: error.localizedDescription)
            }
        }
    }

    struct ComponentError: LocalizedError {
        let name: String
        let underlying: String
        var errorDescription: String? { "„\(name)“ konnte nicht installiert werden.\n\n\(underlying)" }
    }

    func cancelInstall(_ id: String) {
        installTasks[id]?.cancel()
    }

    /// Lädt fehlende Abhängigkeiten einer bereits installierten Engine nach.
    func installMissingRequirements(of engine: WineEngine) {
        for id in engine.missingRequirements {
            if let source = catalog.source(id: id) { install(source) }
        }
    }

    func remove(_ component: InstalledComponent) {
        do {
            try componentStore.remove(id: component.id)
        } catch {
            errorMessage = "„\(component.name)“ konnte nicht gelöscht werden: \(error.localizedDescription)"
        }
        refreshInstalled()
        freeDiskSpace = paths.availableDiskSpace()
    }

    func bottlesUsing(_ engineID: String) -> [Bottle] {
        bottles.filter { ($0.settings.engineID ?? settings.defaultEngineID) == engineID }
    }

    /// Installierte Engines, die diese Komponente brauchen.
    func enginesRequiring(_ componentID: String) -> [InstalledComponent] {
        installedEngines.filter { ($0.requires ?? []).contains(componentID) }
    }

    func folder(of component: InstalledComponent) -> URL {
        componentStore.directory(for: component.id)
    }

    var isDXVKInstalled: Bool { installed.contains { $0.kind == .dxvk } }

    /// Lädt DXVK, falls eine Einstellung es braucht und es fehlt.
    func ensureDXVKIfNeeded(for settings: BottleSettings) {
        let needsDXVK = settings.graphicsBackend == .dxvk || settings.executableBackends.values.contains(.dxvk)
        guard needsDXVK, !isDXVKInstalled, let source = catalog.components(of: .dxvk).first else { return }
        install(source)
    }

    // MARK: Bottles

    func refreshBottles() {
        bottles = bottleStore.list()
        var apps: [String: [InstalledApp]] = [:]
        for bottle in bottles {
            let list = AppStore.load(for: bottle)
            apps[bottle.id] = list
            for app in list where icons[app.id] == nil {
                loadIcon(for: app, in: bottle)
            }
        }
        appsByBottle = apps
    }

    func bottle(id: String) -> Bottle? {
        bottles.first { $0.id == id }
    }

    func engine(for bottle: Bottle) -> WineEngine? {
        if let id = bottle.settings.engineID { return componentStore.engine(id: id) }
        return defaultEngine
    }

    private func wine(for bottle: Bottle) throws -> Wine {
        guard let engine = engine(for: bottle) else {
            if let id = bottle.settings.engineID { throw KelterError.engineMissing(id) }
            throw KelterError.noEngineInstalled
        }
        return Wine(engine: engine, paths: paths)
    }

    /// Wie würde die Grafik beim nächsten Start umgesetzt? (Für die Anzeige in „Erweitert“.)
    func plannedLaunch(for bottle: Bottle) -> LaunchPlan? {
        guard let engine = engine(for: bottle) else { return nil }
        return LaunchPlanner.plan(
            settings: bottle.settings,
            engine: engine,
            sources: componentStore.graphicsSources(for: engine),
            dllPathVariable: WineLayout.dllPathVariable(root: engine.root)
        )
    }

    func graphicsSources(for bottle: Bottle) -> GraphicsSources? {
        engine(for: bottle).map { componentStore.graphicsSources(for: $0) }
    }

    /// Wendet Grafik-/Controller-Einstellungen an (falls geändert) und liefert die Start-Engine.
    func prepare(_ bottle: Bottle) async throws -> PreparedLaunch {
        let wine = try wine(for: bottle)
        let prepared = try await wine.prepare(bottle, sources: componentStore.graphicsSources(for: wine.engine))
        if let updated = prepared.updatedSettings {
            var saved = bottle
            saved.settings = updated
            try bottleStore.save(saved)
            refreshBottles()
        }
        return prepared
    }

    /// Legt eine Bottle an und richtet sie mit `wineboot --init` ein.
    /// - Returns: Die ID der neuen Bottle (auch wenn das Einrichten fehlschlägt).
    @discardableResult
    func createBottle(name: String, engineID: String?) async -> String? {
        let bottle: Bottle
        do {
            guard let engine = engineID.flatMap(componentStore.engine(id:)) ?? defaultEngine else {
                throw KelterError.noEngineInstalled
            }
            try checkCompatible(engine)
            bottle = try bottleStore.create(name: name, engineID: engineID)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
        refreshBottles()
        await initialize(bottle)
        return bottle.id
    }

    func initialize(_ bottle: Bottle) async {
        bottleActivity[bottle.id] = "Bottle wird eingerichtet … (beim ersten Mal 1–2 Minuten)"
        defer { bottleActivity[bottle.id] = nil }
        do {
            let wine = try wine(for: bottle)
            try checkCompatible(wine.engine)
            lastLog[bottle.id] = try await wine.initialize(bottle)
            refreshBottles()
            if let current = self.bottle(id: bottle.id) {
                _ = try await prepare(current)
            }
        } catch {
            var log: URL?
            if case let KelterError.commandFailed(_, _, path?) = error {
                log = URL(fileURLWithPath: path)
                lastLog[bottle.id] = log
            }
            errorMessage = explain("Die Bottle „\(bottle.name)“ konnte nicht eingerichtet werden.\n\n\(error.localizedDescription)", log: log)
        }
        refreshBottles()
    }

    /// Speichert geänderte Einstellungen. Eine neue Windows-Version wird sofort in Wine gesetzt.
    func update(_ bottle: Bottle, settings newSettings: BottleSettings) async {
        let oldSettings = bottle.settings
        // Ein laufender wineserver passt nur zu seiner eigenen Engine (bzw. DXMT-Engine-Kopie).
        let engineChanged = oldSettings.engineID != newSettings.engineID || oldSettings.graphicsBackend != newSettings.graphicsBackend
        if engineChanged, runState(of: bottle) != .stopped {
            await killAll(in: bottle)
        }
        var updated = bottle
        updated.settings = newSettings
        do {
            try bottleStore.save(updated)
        } catch {
            errorMessage = "Einstellungen konnten nicht gespeichert werden: \(error.localizedDescription)"
            return
        }
        refreshBottles()
        ensureDXVKIfNeeded(for: newSettings)

        guard oldSettings.windowsVersion != newSettings.windowsVersion, updated.isInitialized else { return }
        bottleActivity[bottle.id] = "Setze \(newSettings.windowsVersion.displayName) …"
        defer { bottleActivity[bottle.id] = nil }
        do {
            try await wine(for: updated).setWindowsVersion(newSettings.windowsVersion, in: updated)
        } catch {
            errorMessage = "Die Windows-Version konnte nicht gesetzt werden.\n\n\(error.localizedDescription)"
        }
    }

    /// Setzt oder entfernt eine Grafik-Ausnahme für ein Programm.
    func setException(_ backend: GraphicsBackend?, for executable: String, in bottle: Bottle) async {
        var settings = bottle.settings
        settings.executableBackends[executable] = backend
        await update(bottle, settings: settings)
    }

    func launch(_ program: BuiltinProgram, in bottle: Bottle) {
        do {
            let process = try wine(for: bottle).launch(
                WineLaunchRequest(label: "\(program.rawValue)-\(bottle.id)", arguments: program.arguments),
                in: bottle
            )
            lastLog[bottle.id] = process.logURL
            scanSoon()
        } catch {
            errorMessage = "„\(program.title)“ konnte nicht gestartet werden.\n\n\(error.localizedDescription)"
        }
    }

    func killAll(in bottle: Bottle) async {
        bottleActivity[bottle.id] = "Beende alle Programme …"
        defer { bottleActivity[bottle.id] = nil }
        do {
            try await wine(for: bottle).killAll(in: bottle)
        } catch {
            errorMessage = error.localizedDescription
        }
        await scanNow()
    }

    func moveToTrash(_ bottle: Bottle) async {
        if runState(of: bottle) != .stopped {
            await killAll(in: bottle)
        }
        do {
            try bottleStore.moveToTrash(bottle)
        } catch {
            errorMessage = "„\(bottle.name)“ konnte nicht in den Papierkorb gelegt werden: \(error.localizedDescription)"
        }
        for app in appsByBottle[bottle.id] ?? [] {
            icons[app.id] = nil
            lastLog[app.id.uuidString] = nil
        }
        lastLog[bottle.id] = nil
        refreshBottles()
    }

    // MARK: Katalog

    func installedApp(for recipe: AppRecipe) -> AppRef? {
        allApps.first { $0.app.recipeID == recipe.id }
    }

    func recipe(for app: InstalledApp) -> AppRecipe? {
        app.recipeID.flatMap(recipes.recipe(id:))
    }

    /// Größe aller Downloads einer Katalog-Installation (soweit bekannt).
    func downloadSize(for recipe: AppRecipe) -> Int64 {
        var size = recipe.installer.approximateSize ?? 0
        for id in recipe.requiredComponents ?? [] {
            if let source = catalog.source(id: id), installedComponent(id: id) == nil { size += source.sizeBytes ?? 0 }
        }
        for id in recipe.prerequisites ?? [] {
            size += recipes.prerequisite(id: id)?.approximateSize ?? 0
        }
        return size
    }

    /// Bottle anlegen → einrichten → Komponenten → offiziellen Installer laden und ausführen → eintragen.
    func installRecipe(_ recipe: AppRecipe) {
        guard recipeTasks[recipe.id] == nil else { return }
        recipeInstalls[recipe.id] = .preparing("Bereite vor …")
        recipeInstallStarted[recipe.id] = .now
        recipeTasks[recipe.id] = Task {
            defer {
                recipeInstalls[recipe.id] = nil
                recipeInstallStarted[recipe.id] = nil
                recipeTasks[recipe.id] = nil
                recipeBottles[recipe.id] = nil
                freeDiskSpace = paths.availableDiskSpace()
            }
            var createdBottle: Bottle?
            do {
                if let engine = defaultEngine { try checkCompatible(engine) }
                guard isReady else { throw KelterError.noEngineInstalled }

                for id in recipe.requiredComponents ?? [] where installedComponent(id: id) == nil {
                    guard let source = catalog.source(id: id) else { continue }
                    recipeInstalls[recipe.id] = .preparing("Lade \(source.name) …")
                    try await installAndWait(source)
                }

                var bottle: Bottle
                if let leftover = leftoverBottle(for: recipe) {
                    // Ein früherer Versuch ist gescheitert: dieselbe Bottle weiterverwenden.
                    bottle = leftover
                } else {
                    recipeInstalls[recipe.id] = .creatingBottle
                    bottle = try bottleStore.create(name: uniqueBottleName(recipe.name), engineID: nil)
                    bottle.settings.recipeID = recipe.id
                    if let backend = recipe.graphicsBackend { bottle.settings.graphicsBackend = backend }
                    bottle.settings.executableBackends = recipe.executableBackends ?? [:]
                    if let version = recipe.windowsVersion { bottle.settings.windowsVersion = version }
                    try bottleStore.save(bottle)
                }
                createdBottle = bottle
                recipeBottles[recipe.id] = bottle.id
                refreshBottles()

                if !bottle.isInitialized {
                    recipeInstalls[recipe.id] = .initializingBottle
                    let wine = try wine(for: bottle)
                    try checkCompatible(wine.engine)
                    lastLog[bottle.id] = try await wine.initialize(bottle)
                    refreshBottles()
                }
                bottle = self.bottle(id: bottle.id) ?? bottle
                let prepared = try await prepare(bottle)
                bottle = self.bottle(id: bottle.id) ?? bottle

                let prerequisites = (recipe.prerequisites ?? []).compactMap(recipes.prerequisite(id:))
                let app = try await RecipeInstaller(paths: paths, downloader: downloader).install(
                    recipe, in: bottle, wine: prepared.wine, prerequisites: prerequisites
                ) { phase in
                    Task { @MainActor in
                        if self.recipeInstalls[recipe.id] != nil { self.recipeInstalls[recipe.id] = phase }
                    }
                }

                refreshBottles()
                var apps = appsByBottle[bottle.id] ?? []
                apps.append(app)
                if save(apps, for: bottle) {
                    loadIcon(for: app, in: bottle)
                    selection = .app(app.id)
                }
            } catch is CancellationError {
                if let bottle = createdBottle { await killAll(in: bottle) }
            } catch {
                var log: URL?
                if case let KelterError.commandFailed(_, _, path?) = error {
                    log = URL(fileURLWithPath: path)
                    if let bottle = createdBottle { lastLog[bottle.id] = log }
                }
                var message = explain("„\(recipe.name)“ konnte nicht installiert werden.\n\n\(error.localizedDescription)", log: log)
                if let bottle = createdBottle {
                    message += "\n\nDie Bottle „\(bottle.name)“ bleibt bestehen, damit du ins Log schauen kannst. Ein neuer Klick auf „Installieren“ macht mit ihr weiter."
                }
                errorMessage = message
            }
            refreshBottles()
        }
    }

    func cancelRecipeInstall(_ recipe: AppRecipe) {
        recipeTasks[recipe.id]?.cancel()
        // Laufende Installer beenden, damit das Warten endet.
        if let id = recipeBottles[recipe.id], let bottle = bottle(id: id) {
            Task { await killAll(in: bottle) }
        }
    }

    /// Bottle eines früheren, gescheiterten Versuchs: gleiches Rezept, aber noch keine App darin.
    private func leftoverBottle(for recipe: AppRecipe) -> Bottle? {
        bottles.first { $0.settings.recipeID == recipe.id && (appsByBottle[$0.id] ?? []).isEmpty }
    }

    private func uniqueBottleName(_ base: String) -> String {
        let taken = Set(bottles.map { $0.id.lowercased() })
        guard taken.contains((try? BottleStore.folderName(for: base))?.lowercased() ?? base.lowercased()) else { return base }
        var counter = 2
        while taken.contains("\(base) \(counter)".lowercased()) { counter += 1 }
        return "\(base) \(counter)"
    }

    /// Das neueste Log seit `date` (für die Anzeige während einer Katalog-Installation).
    func newestLog(since date: Date) -> URL? {
        let entries = (try? FileManager.default.contentsOfDirectory(at: paths.logs, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles)) ?? []
        return entries
            .compactMap { url -> (URL, Date)? in
                guard let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                      modified >= date.addingTimeInterval(-2)
                else { return nil }
                return (url, modified)
            }
            .max { $0.1 < $1.1 }?.0
    }

    // MARK: Meine Apps

    var allApps: [AppRef] {
        bottles.flatMap { bottle in (appsByBottle[bottle.id] ?? []).map { AppRef(bottle: bottle, app: $0) } }
            .sorted { $0.app.name.localizedStandardCompare($1.app.name) == .orderedAscending }
    }

    func apps(in bottle: Bottle) -> [InstalledApp] {
        appsByBottle[bottle.id] ?? []
    }

    func app(id: UUID) -> AppRef? {
        allApps.first { $0.app.id == id }
    }

    /// Trägt eine EXE, die schon in der Bottle liegt, unter „Meine Apps“ ein.
    @discardableResult
    func addApp(executable url: URL, to bottle: Bottle) -> UUID? {
        let bottlePath = bottle.url.standardizedFileURL.path + "/"
        guard url.standardizedFileURL.path.hasPrefix(bottlePath),
              let windowsPath = WindowsPath.windowsPath(for: url, prefix: bottle.url)
        else {
            errorMessage = KelterError.executableOutsideBottle.localizedDescription
            return nil
        }
        var apps = appsByBottle[bottle.id] ?? []
        if let existing = apps.first(where: { $0.executable.caseInsensitiveCompare(windowsPath) == .orderedSame && $0.steamAppID == nil }) {
            errorMessage = KelterError.appExists(existing.name).localizedDescription
            return nil
        }
        let app = InstalledApp(name: url.deletingPathExtension().lastPathComponent, executable: windowsPath)
        apps.append(app)
        guard save(apps, for: bottle) else { return nil }
        loadIcon(for: app, in: bottle)
        return app.id
    }

    func update(_ app: InstalledApp, in bottle: Bottle) {
        var apps = appsByBottle[bottle.id] ?? []
        guard let index = apps.firstIndex(where: { $0.id == app.id }) else { return }
        apps[index] = app
        save(apps, for: bottle)
    }

    /// Nimmt die App aus „Meine Apps“. Die Dateien in der Bottle bleiben.
    func remove(_ app: InstalledApp, from bottle: Bottle) {
        let apps = (appsByBottle[bottle.id] ?? []).filter { $0.id != app.id }
        if save(apps, for: bottle) {
            AppStore.removeIcon(for: app, in: bottle)
            icons[app.id] = nil
        }
    }

    func launch(_ app: InstalledApp, in bottle: Bottle) async {
        do {
            let prepared = try await prepare(bottle)
            let current = self.bottle(id: bottle.id) ?? bottle
            let process = try prepared.wine.launch(app, in: current, plan: prepared.plan)
            lastLog[app.id.uuidString] = process.logURL
            lastLog[bottle.id] = process.logURL
            scanSoon()
        } catch {
            errorMessage = "„\(app.name)“ konnte nicht gestartet werden.\n\n\(error.localizedDescription)"
        }
    }

    /// Bittet die App, sich zu beenden (wie Fenster schließen).
    func stop(_ app: InstalledApp, in bottle: Bottle) async {
        do {
            let wine = try wine(for: bottle)
            if app.processFolder != nil {
                // Steam-Spiel: die Programme im Spielordner schließen, nicht Steam.
                let names = Set(processes(of: app, in: bottle).map(\.displayName))
                for name in names { try await wine.close(executable: name, in: bottle) }
            } else {
                try await wine.close(executable: app.executable, in: bottle)
            }
        } catch {
            errorMessage = "„\(app.name)“ ließ sich nicht beenden.\n\n\(error.localizedDescription)"
        }
        await scanNow()
    }

    /// Beendet alle Prozesse der App sofort (Daten können verloren gehen).
    func forceStop(_ app: InstalledApp, in bottle: Bottle) async {
        for process in processes(of: app, in: bottle) {
            kill(process.pid, SIGKILL)
        }
        await scanNow()
    }

    func terminate(_ process: WineProcessInfo) {
        kill(process.pid, SIGTERM)
        scanSoon()
    }

    func logs(for app: InstalledApp) -> [URL] {
        LogStore.logs(in: paths.logs, label: app.name)
    }

    // MARK: Steam

    func steamGames(for steam: InstalledApp, in bottle: Bottle) -> [SteamGame] {
        SteamLibrary.games(steamExecutable: steam.executable, prefix: bottle.url)
    }

    func launch(_ game: SteamGame, via steam: InstalledApp, in bottle: Bottle) async {
        var request = steam
        request.name = game.name
        request.arguments = steam.arguments + ["-applaunch", game.appID]
        await launch(request, in: bottle)
    }

    func isRunning(_ game: SteamGame, in bottle: Bottle) -> Bool {
        processes(in: bottle).contains { $0.isInside(windowsFolder: game.folder) }
    }

    /// Legt das Steam-Spiel als eigenen Eintrag unter „Meine Apps“ an.
    func addToMyApps(_ game: SteamGame, steam: InstalledApp, in bottle: Bottle) {
        var apps = appsByBottle[bottle.id] ?? []
        guard !apps.contains(where: { $0.steamAppID == game.appID }) else {
            errorMessage = KelterError.appExists(game.name).localizedDescription
            return
        }
        let exe = SteamLibrary.executables(of: game, prefix: bottle.url).first
        let app = InstalledApp(
            name: game.name,
            executable: steam.executable,
            arguments: steam.arguments + ["-applaunch", game.appID],
            environment: steam.environment,
            performanceHUD: steam.performanceHUD,
            steamAppID: game.appID,
            processFolder: game.folder,
            iconExecutable: exe.map { findExecutablePath(named: $0, in: game, bottle: bottle) ?? (game.folder + "\\" + $0) }
        )
        apps.append(app)
        if save(apps, for: bottle) {
            loadIcon(for: app, in: bottle)
            selection = .app(app.id)
        }
    }

    private func findExecutablePath(named name: String, in game: SteamGame, bottle: Bottle) -> String? {
        guard let folder = WindowsPath.unixURL(for: game.folder, prefix: bottle.url),
              let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)
        else { return nil }
        for case let url as URL in enumerator where url.lastPathComponent == name {
            return WindowsPath.windowsPath(for: url, prefix: bottle.url)
        }
        return nil
    }

    // MARK: Icons & Speichern

    private func loadIcon(for app: InstalledApp, in bottle: Bottle) {
        if let url = AppStore.cachedIcon(for: app, in: bottle), let image = NSImage(contentsOf: url) {
            icons[app.id] = image
        }
    }

    @discardableResult
    private func save(_ apps: [InstalledApp], for bottle: Bottle) -> Bool {
        do {
            try AppStore.save(apps, for: bottle)
            appsByBottle[bottle.id] = apps
            return true
        } catch {
            errorMessage = "„Meine Apps“ konnte nicht gespeichert werden: \(error.localizedDescription)"
            return false
        }
    }

    // MARK: Prozess-Überwachung

    func processes(in bottle: Bottle) -> [WineProcessInfo] {
        processesByBottle[bottle.id] ?? []
    }

    func processes(of app: InstalledApp, in bottle: Bottle) -> [WineProcessInfo] {
        processes(in: bottle).filter { app.owns($0) }
    }

    func isRunning(_ app: InstalledApp, in bottle: Bottle) -> Bool {
        !processes(of: app, in: bottle).isEmpty
    }

    func runState(of bottle: Bottle) -> BottleRunState {
        let all = processes(in: bottle)
        let visible = all.filter { !$0.isSystemProcess }
        if !visible.isEmpty { return .running(visible.count) }
        return all.isEmpty ? .stopped : .background
    }

    func usage(of processes: [WineProcessInfo]) -> Usage {
        processes.reduce(into: Usage()) { usage, process in
            usage.cpuPercent += cpuPercent[process.pid] ?? 0
            usage.residentBytes += process.residentBytes
        }
    }

    /// Alle 2 Sekunden nachsehen, welche Wine-Prozesse laufen – auch solche, die Kelter nicht
    /// selbst gestartet hat (Steam startet sich z. B. nach Updates neu).
    private func startMonitoring() {
        guard monitorTask == nil else { return }
        monitorTask = Task {
            while !Task.isCancelled {
                await scanNow()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func scanNow() async {
        let found = await WineProcessScanner.scan(enginesDirectory: paths.engines)
        let bottleIDs = Dictionary(bottles.map { ($0.url.standardizedFileURL.path, $0.id) }, uniquingKeysWith: { first, _ in first })
        var grouped: [String: [WineProcessInfo]] = [:]
        for process in found {
            guard let prefix = process.prefixPath, let id = bottleIDs[prefix] else { continue }
            grouped[id, default: []].append(process)
        }
        for key in grouped.keys {
            grouped[key]?.sort { $0.pid < $1.pid }
        }

        // CPU-Auslastung aus der Differenz zur letzten Messung.
        let now = Date.now
        var percents: [Int32: Double] = [:]
        var samples: [Int32: (cpu: UInt64, time: Date)] = [:]
        for process in found {
            if let last = cpuSamples[process.pid], process.cpuNanoseconds >= last.cpu {
                let seconds = now.timeIntervalSince(last.time)
                if seconds > 0.2 {
                    percents[process.pid] = Double(process.cpuNanoseconds - last.cpu) / (seconds * 1e9) * 100
                }
            }
            samples[process.pid] = (process.cpuNanoseconds, now)
        }
        cpuSamples = samples
        if percents != cpuPercent { cpuPercent = percents }
        if grouped != processesByBottle { processesByBottle = grouped }
    }

    /// Kurz nach einem Start erneut schauen, damit der Status schnell umspringt.
    private func scanSoon() {
        Task {
            try? await Task.sleep(for: .milliseconds(800))
            await scanNow()
        }
    }

    // MARK: Hilfen

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    private func save(_ settings: KelterSettings) {
        do {
            try settings.save(paths: paths)
        } catch {
            errorMessage = "Einstellungen konnten nicht gespeichert werden: \(error.localizedDescription)"
        }
    }
}
