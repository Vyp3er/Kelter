import Foundation

/// Was gestartet werden soll.
public struct WineLaunchRequest: Sendable {
    /// Für Anzeige und Logdateinamen, z. B. „winecfg“ oder „Steam“.
    public var label: String
    /// Argumente für `wine`, z. B. `["winecfg"]` oder `["C:\\Program Files (x86)\\Steam\\steam.exe"]`.
    public var arguments: [String]
    /// Zusätzliche Umgebungsvariablen (z. B. aus einem Katalog-Rezept).
    public var environment: [String: String]
    public var workingDirectory: URL?
    /// Startargumente der Bottle anhängen (nur bei Apps, nie bei Installern oder Wine-Werkzeugen).
    public var includeBottleArguments: Bool
    /// Für den Log-Kopf: wie die Grafik umgesetzt wird und was dabei auffiel.
    public var graphicsSummary: String?
    public var notes: [String]

    public init(
        label: String, arguments: [String], environment: [String: String] = [:], workingDirectory: URL? = nil,
        includeBottleArguments: Bool = false, graphicsSummary: String? = nil, notes: [String] = []
    ) {
        self.label = label
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.includeBottleArguments = includeBottleArguments
        self.graphicsSummary = graphicsSummary
        self.notes = notes
    }
}

/// Ein laufender (oder beendeter) Wine-Prozess.
public final class WineProcess: Identifiable, @unchecked Sendable {
    public let id = UUID()
    public let label: String
    public let bottleID: String
    public let logURL: URL
    public let startedAt = Date.now
    private let process: Process

    init(label: String, bottleID: String, logURL: URL, process: Process) {
        self.label = label
        self.bottleID = bottleID
        self.logURL = logURL
        self.process = process
    }

    public var processIdentifier: Int32 { process.processIdentifier }
    public var isRunning: Bool { process.isRunning }

    /// Beendet nur diesen Prozess. Kinder (z. B. von Steam gestartete Spiele) laufen weiter –
    /// dafür gibt es ``Wine/killAll(in:)``.
    public func terminate() {
        if process.isRunning { process.terminate() }
    }
}

/// Startet Programme mit einer bestimmten Engine in einer Bottle.
public struct Wine: Sendable {
    public let engine: WineEngine
    public let paths: KelterPaths

    public init(engine: WineEngine, paths: KelterPaths) {
        self.engine = engine
        self.paths = paths
    }

    public func environment(for bottle: Bottle, extra: [String: String] = [:]) -> [String: String] {
        WineEnvironment.build(
            base: ProcessInfo.processInfo.environment,
            prefix: bottle.url,
            engine: engine,
            settings: bottle.settings,
            extra: extra
        )
    }

    /// Startet ein Programm und kehrt sofort zurück. stdout/stderr landen in `Logs/`.
    public func launch(
        _ request: WineLaunchRequest,
        in bottle: Bottle,
        onExit: @escaping @Sendable (WineProcess, Int32) -> Void = { _, _ in }
    ) throws -> WineProcess {
        guard engine.isComplete else {
            throw KelterError.engineIncomplete(name: engine.name, missing: engine.missingRequirements)
        }
        let environment = environment(for: bottle, extra: request.environment)
        let arguments = request.includeBottleArguments
            ? request.arguments + bottle.settings.launchArguments
            : request.arguments
        let log = try LogFile.create(in: paths.logs, label: request.label)
        log.writeHeader(
            title: request.label, bottle: bottle, engine: engine, command: arguments, environment: environment,
            graphics: request.graphicsSummary, notes: request.notes
        )

        let process = Process()
        process.executableURL = engine.wineBinary
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = request.workingDirectory
            ?? (FileManager.default.fileExists(atPath: bottle.driveC.path) ? bottle.driveC : bottle.url)
        process.standardOutput = log.handle
        process.standardError = log.handle
        process.standardInput = FileHandle.nullDevice

        let wineProcess = WineProcess(label: request.label, bottleID: bottle.id, logURL: log.url, process: process)
        process.terminationHandler = { finished in
            log.writeFooter(status: finished.terminationStatus, reason: finished.terminationReason)
            log.close()
            onExit(wineProcess, finished.terminationStatus)
        }
        do {
            try process.run()
        } catch {
            log.write("\nStart fehlgeschlagen: \(error.localizedDescription)\n")
            log.close()
            throw error
        }
        return wineProcess
    }

    /// Startet eine App aus „Meine Apps“. Arbeitsverzeichnis ist der Ordner der EXE – viele Spiele
    /// finden ihre Dateien sonst nicht.
    public func launch(
        _ app: InstalledApp,
        in bottle: Bottle,
        plan: LaunchPlan? = nil,
        onExit: @escaping @Sendable (WineProcess, Int32) -> Void = { _, _ in }
    ) throws -> WineProcess {
        guard let executable = WindowsPath.unixURL(for: app.executable, prefix: bottle.url),
              FileManager.default.fileExists(atPath: executable.path)
        else { throw KelterError.executableMissing(app.executable) }
        var environment = plan?.environment ?? [:]
        environment.merge(app.performanceHUD.environment) { $1 }
        environment.merge(app.environment) { $1 }
        let request = WineLaunchRequest(
            label: app.name,
            arguments: [app.executable] + app.arguments,
            environment: environment,
            workingDirectory: executable.deletingLastPathComponent(),
            includeBottleArguments: true,
            graphicsSummary: plan?.summary,
            notes: plan?.notes ?? []
        )
        let process = try launch(request, in: bottle, onExit: onExit)
        LogStore.prune(in: paths.logs, label: app.name)
        return process
    }

    /// Kurzer Wine-Aufruf ohne eigenes Log (z. B. `taskkill`).
    public func run(_ arguments: [String], in bottle: Bottle, timeout: Duration = .seconds(30)) async throws -> CommandOutput {
        guard engine.isComplete else {
            throw KelterError.engineIncomplete(name: engine.name, missing: engine.missingRequirements)
        }
        return try await Command.run(engine.wineBinary, arguments, environment: environment(for: bottle), timeout: timeout)
    }

    /// Bittet ein Programm, sich zu beenden (wie „Fenster schließen“). Mit `force` hart beenden.
    public func close(executable windowsPath: String, in bottle: Bottle, force: Bool = false) async throws {
        var arguments = ["taskkill", "/im", WindowsPath.fileName(windowsPath)]
        if force { arguments.insert("/f", at: 1) }
        _ = try await run(arguments, in: bottle)
    }

    /// Startet ein Programm und wartet, bis es sich beendet.
    public func runAndWait(_ request: WineLaunchRequest, in bottle: Bottle) async throws -> (status: Int32, log: URL) {
        try await withCheckedThrowingContinuation { continuation in
            do {
                _ = try launch(request, in: bottle) { process, status in
                    continuation.resume(returning: (status, process.logURL))
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Richtet eine leere Bottle mit `wineboot --init` ein und wartet, bis Wine alles geschrieben hat.
    @discardableResult
    public func initialize(_ bottle: Bottle) async throws -> URL {
        // Reste eines früheren, gescheiterten Versuchs (z. B. mit einer anderen Engine) entfernen.
        try bottle.removeIncompleteSetup()
        let request = WineLaunchRequest(label: "wineboot-\(bottle.id)", arguments: ["wineboot", "--init"])
        let (status, log) = try await runAndWait(request, in: bottle)
        // wineboot kehrt zurück, bevor der wineserver die Registry fertig geschrieben hat.
        try? await waitForServer(in: bottle)
        guard status == 0, bottle.isInitialized else {
            throw KelterError.commandFailed(command: "wineboot --init", status: status, log: log.path)
        }
        if bottle.settings.windowsVersion != .win10 {
            try await setWindowsVersion(bottle.settings.windowsVersion, in: bottle)
        }
        return log
    }

    /// Setzt die gemeldete Windows-Version (`winecfg /v win11`).
    public func setWindowsVersion(_ version: WindowsVersion, in bottle: Bottle) async throws {
        let request = WineLaunchRequest(label: "winecfg-version-\(bottle.id)", arguments: ["winecfg", "/v", version.rawValue])
        let (status, log) = try await runAndWait(request, in: bottle)
        try? await waitForServer(in: bottle)
        guard status == 0 else {
            throw KelterError.commandFailed(command: "winecfg /v \(version.rawValue)", status: status, log: log.path)
        }
    }

    /// Beendet alle Windows-Programme der Bottle (`wineserver -k`).
    public func killAll(in bottle: Bottle) async throws {
        let result = try await Command.run(engine.wineserverBinary, ["-k"], environment: environment(for: bottle), timeout: .seconds(30))
        // Code 1 heißt: es lief gar kein wineserver – das ist kein Fehler.
        guard result.status == 0 || result.status == 1 else {
            throw KelterError.commandFailed(command: "wineserver -k", status: result.status, log: nil)
        }
    }

    /// Wartet, bis der wineserver der Bottle sich beendet hat (`wineserver -w`).
    public func waitForServer(in bottle: Bottle, timeout: Duration = .seconds(60)) async throws {
        _ = try await Command.run(engine.wineserverBinary, ["-w"], environment: environment(for: bottle), timeout: timeout)
    }
}

