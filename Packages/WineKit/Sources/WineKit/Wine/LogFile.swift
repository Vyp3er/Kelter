import Foundation

/// Eine Logdatei `Logs/<Programm>-<Datum>.log`, in die stdout und stderr direkt geschrieben werden.
public final class LogFile: @unchecked Sendable {
    public let url: URL
    let handle: FileHandle
    private let lock = NSLock()

    private init(url: URL, handle: FileHandle) {
        self.url = url
        self.handle = handle
    }

    public static func create(in directory: URL, label: String, date: Date = .now) throws -> LogFile {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var url = directory.appending(path: fileName(label: label, date: date))
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appending(path: fileName(label: label, date: date, suffix: "-\(counter)"))
            counter += 1
        }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return LogFile(url: url, handle: try FileHandle(forWritingTo: url))
    }

    public static func fileName(label: String, date: Date, suffix: String = "") -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return "\(sanitize(label))-\(formatter.string(from: date))\(suffix).log"
    }

    /// Nur Zeichen, die in Dateinamen keinen Ärger machen.
    public static func sanitize(_ label: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let mapped = label.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let result = String(mapped).trimmingCharacters(in: CharacterSet(charactersIn: "_."))
        return result.isEmpty ? "log" : result
    }

    public func write(_ text: String) {
        lock.withLock {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(text.utf8))
        }
    }

    public func close() {
        lock.withLock { try? handle.close() }
    }

    /// Kopfzeilen, damit ein Log auch ohne Kelter verständlich ist.
    func writeHeader(
        title: String, bottle: Bottle, engine: WineEngine, command: [String], environment: [String: String],
        graphics: String?, notes: [String]
    ) {
        // Ortszeit wie in der Schlusszeile (ISO-Format wäre UTC und damit um Stunden verschoben).
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss xxx"
        let date = formatter.string(from: .now)
        var lines = [
            "Kelter-Log: \(title)",
            "Datum:   \(date)",
            "Bottle:  \(bottle.name) (\(bottle.url.path))",
            "Engine:  \(engine.name) – \(engine.component.detectedVersion ?? engine.component.version)",
            "Biblio.: \(engine.runtime?.frameworks.path ?? "in der Engine enthalten")",
            "Grafik:  \(graphics ?? "Wine-Standard (WineD3D)")"
        ]
        let exceptions = bottle.settings.executableBackends.sorted { $0.key < $1.key }
        if !exceptions.isEmpty {
            lines.append("Ausnahmen: " + exceptions.map { "\($0.key) → \($0.value.displayName)" }.joined(separator: ", "))
        }
        lines += notes.map { "Hinweis: \($0)" }
        lines += [
            "Befehl:  wine \(command.joined(separator: " "))",
            "Umgebung:"
        ]
        lines += WineEnvironment.loggableKeys(of: environment).map { "  \($0)=\($1)" }
        lines.append(String(repeating: "─", count: 72))
        write(lines.joined(separator: "\n") + "\n")
    }

    func writeFooter(status: Int32, reason: Process.TerminationReason) {
        let how = reason == .uncaughtSignal ? "durch Signal \(status) beendet" : "beendet mit Code \(status)"
        write("\n" + String(repeating: "─", count: 72) + "\nProzess \(how) um \(Date.now.formatted(date: .omitted, time: .standard)).\n")
    }
}
