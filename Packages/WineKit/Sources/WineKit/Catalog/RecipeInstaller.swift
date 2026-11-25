import Foundation

/// Schritt einer Katalog-Installation, für die Fortschrittsanzeige.
public enum RecipeInstallPhase: Sendable, Equatable {
    case preparing(String)
    case creatingBottle
    case initializingBottle
    case prerequisite(name: String, downloading: InstallPhase?)
    case downloadingInstaller(received: Int64, expected: Int64)
    case runningInstaller(interactive: Bool)
    case waitingForFiles
    case finishing

    public var label: String {
        switch self {
        case let .preparing(text): return text
        case .creatingBottle: return "Lege Bottle an …"
        case .initializingBottle: return "Richte die Bottle ein (wineboot, 1–2 Minuten) …"
        case let .prerequisite(name, phase):
            if let phase { return "\(name): \(phase.label)" }
            return "Installiere \(name) …"
        case let .downloadingInstaller(received, expected):
            return InstallPhase.downloading(received: received, expected: expected).label.replacingOccurrences(of: "Lade", with: "Lade Installer")
        case let .runningInstaller(interactive):
            return interactive ? "Installer läuft – bitte im Installer-Fenster durchklicken …" : "Installer läuft …"
        case .waitingForFiles: return "Warte auf das Ende der Installation …"
        case .finishing: return "Trage die App ein …"
        }
    }

    public var fraction: Double? {
        switch self {
        case let .downloadingInstaller(received, expected) where expected > 0:
            return min(1, Double(received) / Double(expected))
        case let .prerequisite(_, phase?):
            return phase.fraction
        default:
            return nil
        }
    }
}

/// Führt ein Rezept in einer bereits eingerichteten Bottle aus: Komponenten, Installer, Eintrag.
public struct RecipeInstaller: Sendable {
    public let paths: KelterPaths
    private let downloader: FileDownloader

    public init(paths: KelterPaths, downloader: FileDownloader = FileDownloader()) {
        self.paths = paths
        self.downloader = downloader
    }

    @concurrent
    public func install(
        _ recipe: AppRecipe,
        in bottle: Bottle,
        wine: Wine,
        prerequisites: [Prerequisite],
        progress: @escaping @Sendable (RecipeInstallPhase) -> Void
    ) async throws -> InstalledApp {
        // 1. Laufzeitkomponenten
        for prerequisite in prerequisites {
            try Task.checkCancellation()
            try await PrerequisiteInstaller(paths: paths, downloader: downloader)
                .install(prerequisite, in: bottle, wine: wine) { phase in
                    progress(.prerequisite(name: prerequisite.name, downloading: phase))
                }
        }

        // Schon installiert (z. B. zweiter Versuch)? Dann nur eintragen.
        if let existing = Self.findExecutable(of: recipe, in: bottle) {
            progress(.finishing)
            return Self.makeApp(recipe, executable: existing)
        }

        // 2. Offiziellen Installer laden
        let folder = paths.downloads.appending(path: "Installer", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let installer = folder.appending(path: "\(recipe.id)-\(recipe.installer.resolvedFileName)")
        defer { try? FileManager.default.removeItem(at: installer) }
        progress(.downloadingInstaller(received: 0, expected: recipe.installer.approximateSize ?? 0))
        _ = try await downloader.download(from: recipe.installer.url, to: installer) { received, expected in
            progress(.downloadingInstaller(received: received, expected: expected > 0 ? expected : (recipe.installer.approximateSize ?? 0)))
        }
        if let expected = recipe.installer.sha256.map(Checksum.normalize), !expected.isEmpty {
            let actual = try Checksum.sha256(of: installer)
            guard actual == expected else { throw KelterError.checksumMismatch(expected: expected, actual: actual) }
        }
        try Task.checkCancellation()

        // 3. Installer ausführen
        progress(.runningInstaller(interactive: recipe.isInteractive))
        guard let windowsPath = WindowsPath.windowsPath(for: installer, prefix: bottle.url) else {
            throw RecipeError.invalid("Installer-Pfad lässt sich nicht nach Windows übersetzen.")
        }
        let arguments: [String]
        switch recipe.installer.resolvedType {
        case .exe: arguments = [windowsPath] + (recipe.installer.arguments ?? [])
        case .msi: arguments = ["msiexec", "/i", windowsPath] + (recipe.installer.arguments ?? [])
        }
        let request = WineLaunchRequest(label: "\(recipe.name)-Installation", arguments: arguments, workingDirectory: folder)
        let exit = ExitStatusBox()
        let process = try wine.launch(request, in: bottle) { _, status in exit.set(status) }
        let log = process.logURL
        // Fertig, wenn der Installer sich beendet – oder wenn die Start-EXE schon 20 s existiert
        // (manche Installer starten die App selbst und laufen weiter, bis man sie schließt).
        var executableSeen: Date?
        do {
            while exit.value == nil {
                if Self.findExecutable(of: recipe, in: bottle) != nil {
                    let seen = executableSeen ?? .now
                    executableSeen = seen
                    if Date.now.timeIntervalSince(seen) > 20 { break }
                }
                try await Task.sleep(for: .seconds(2))
            }
        } catch {
            process.terminate()
            throw error
        }
        let status = exit.value ?? 0

        // 4. Warten, bis die Start-EXE da ist (manche Installer arbeiten in Kindprozessen weiter)
        progress(.waitingForFiles)
        guard let executable = try await waitForExecutable(of: recipe, in: bottle) else {
            if status != 0 { throw RecipeError.installerFailed(status, log.path) }
            throw RecipeError.executableNotFound(recipe.allExecutables)
        }
        progress(.finishing)
        return Self.makeApp(recipe, executable: executable)
    }

    static func makeApp(_ recipe: AppRecipe, executable: String) -> InstalledApp {
        InstalledApp(
            name: recipe.name,
            executable: executable,
            arguments: recipe.arguments ?? [],
            environment: recipe.environment ?? [:],
            recipeID: recipe.id
        )
    }

    static func findExecutable(of recipe: AppRecipe, in bottle: Bottle) -> String? {
        recipe.allExecutables.first { path in
            WindowsPath.unixURL(for: path, prefix: bottle.url).map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        }
    }

    /// Wartet bis zu 30 Minuten auf die Start-EXE – aber nur, solange in der Bottle noch ein
    /// Programm (Installer, Updater) läuft. Ist 20 Sekunden lang nichts mehr aktiv, gibt es auf.
    private func waitForExecutable(of recipe: AppRecipe, in bottle: Bottle) async throws -> String? {
        let deadline = Date.now.addingTimeInterval(30 * 60)
        var idleSince: Date?
        let bottlePath = bottle.url.standardizedFileURL.path
        while Date.now < deadline {
            if let found = Self.findExecutable(of: recipe, in: bottle) { return found }
            let busy = WineProcessScanner.scanNow(enginesDirectory: paths.engines)
                .contains { $0.prefixPath == bottlePath && !$0.isSystemProcess }
            if busy {
                idleSince = nil
            } else if let since = idleSince {
                if Date.now.timeIntervalSince(since) > 20 { return nil }
            } else {
                idleSince = .now
            }
            try await Task.sleep(for: .seconds(2))
        }
        return Self.findExecutable(of: recipe, in: bottle)
    }
}

/// Exit-Code eines Prozesses, der aus dem Beendigungs-Handler gesetzt wird.
final class ExitStatusBox: @unchecked Sendable {
    private let lock = NSLock()
    private var status: Int32?

    var value: Int32? { lock.withLock { status } }
    func set(_ value: Int32) { lock.withLock { status = value } }
}

/// Installiert Laufzeitkomponenten und merkt sich in `kelter-prerequisites.json`, was schon da ist.
public struct PrerequisiteInstaller: Sendable {
    public static let recordFile = "kelter-prerequisites.json"
    public let paths: KelterPaths
    let downloader: FileDownloader

    public init(paths: KelterPaths, downloader: FileDownloader = FileDownloader()) {
        self.paths = paths
        self.downloader = downloader
    }

    public static func installed(in bottle: Bottle) -> Set<String> {
        guard let data = try? Data(contentsOf: bottle.url.appending(path: recordFile)),
              let list = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return Set(list)
    }

    static func markInstalled(_ id: String, in bottle: Bottle) throws {
        var list = installed(in: bottle)
        list.insert(id)
        try JSONEncoder.kelter.encode(list.sorted()).write(to: bottle.url.appending(path: recordFile), options: .atomic)
    }

    public func install(
        _ prerequisite: Prerequisite,
        in bottle: Bottle,
        wine: Wine,
        progress: @escaping @Sendable (InstallPhase?) -> Void
    ) async throws {
        guard !Self.installed(in: bottle).contains(prerequisite.id) else { return }
        progress(nil)
        switch prerequisite.kind {
        case .macosFonts:
            try Self.copyMacOSFonts(prerequisite.fonts ?? [], into: bottle)
        case .installer:
            guard let url = prerequisite.url else { throw RecipeError.invalid("Komponente „\(prerequisite.id)“ hat keine URL.") }
            let folder = paths.downloads.appending(path: "Installer", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appending(path: prerequisite.fileName ?? url.lastPathComponent)
            defer { try? FileManager.default.removeItem(at: file) }
            _ = try await downloader.download(from: url, to: file) { received, expected in
                progress(.downloading(received: received, expected: expected > 0 ? expected : (prerequisite.approximateSize ?? 0)))
            }
            progress(nil)
            guard let windowsPath = WindowsPath.windowsPath(for: file, prefix: bottle.url) else { return }
            let request = WineLaunchRequest(label: "Komponente-\(prerequisite.id)", arguments: [windowsPath] + (prerequisite.arguments ?? []), workingDirectory: folder)
            let (status, log) = try await wine.runAndWait(request, in: bottle)
            guard (prerequisite.successCodes ?? [0]).contains(status) else {
                throw KelterError.commandFailed(command: prerequisite.name, status: status, log: log.path)
            }
            if let overrides = prerequisite.dllOverrides, !overrides.isEmpty {
                let edits = overrides.sorted { $0.key < $1.key }.map {
                    RegistryEdit.setString(key: RegistryKeys.dllOverrides, name: $0.key, value: $0.value)
                }
                try await wine.applyRegistry(edits, in: bottle)
            }
        }
        try Self.markInstalled(prerequisite.id, in: bottle)
    }

    /// Kopiert Windows-kompatible Schriften aus macOS nach `C:\windows\Fonts`.
    static func copyMacOSFonts(_ names: [String], into bottle: Bottle, source: URL = URL(fileURLWithPath: "/System/Library/Fonts/Supplemental")) throws {
        let target = bottle.driveC.appending(path: "windows/Fonts", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        for name in names {
            let from = source.appending(path: name)
            let to = target.appending(path: name)
            guard FileManager.default.fileExists(atPath: from.path), !FileManager.default.fileExists(atPath: to.path) else { continue }
            try FileManager.default.copyItem(at: from, to: to)
        }
    }
}
