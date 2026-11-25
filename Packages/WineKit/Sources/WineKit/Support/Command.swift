import Foundation

/// Ergebnis eines kurzen Hilfsprogramms (`tar`, `xattr`, `wine --version` …).
public struct CommandOutput: Sendable {
    public let status: Int32
    public let output: String
    public var succeeded: Bool { status == 0 }
}

/// Startet kurze Hilfsprogramme und wartet auf ihr Ende.
///
/// Die Ausgabe landet in einer temporären Datei statt in einer Pipe: Wine startet den
/// `wineserver` als Hintergrundprozess, der eine Pipe erben und offen halten würde –
/// das Lesen bis zum Ende würde dann hängen.
public enum Command {
    @concurrent
    public static func run(
        _ executable: URL,
        _ arguments: [String] = [],
        environment: [String: String]? = nil,
        timeout: Duration? = nil
    ) async throws -> CommandOutput {
        let fileManager = FileManager.default
        let outputURL = fileManager.temporaryDirectory.appending(path: "kelter-\(UUID().uuidString).out")
        fileManager.createFile(atPath: outputURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: outputURL)
        defer {
            try? handle.close()
            try? fileManager.removeItem(at: outputURL)
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        process.standardOutput = handle
        process.standardError = handle
        process.standardInput = FileHandle.nullDevice
        let box = ProcessBox(process)

        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { finished in
                    continuation.resume(returning: finished.terminationStatus)
                }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                    return
                }
                if let timeout {
                    Task.detached {
                        try? await Task.sleep(for: timeout)
                        box.terminate()
                    }
                }
            }
        } onCancel: {
            box.terminate()
        }

        let data = (try? Data(contentsOf: outputURL)) ?? Data()
        return CommandOutput(status: status, output: String(decoding: data, as: UTF8.self))
    }
}

/// Hält einen `Process` für Abbruch-Handler fest, die `Sendable` sein müssen.
final class ProcessBox: @unchecked Sendable {
    let process: Process

    init(_ process: Process) {
        self.process = process
    }

    func terminate() {
        if process.isRunning { process.terminate() }
    }
}
