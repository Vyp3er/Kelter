import Foundation

/// Eine Änderung an der Windows-Registry einer Bottle.
public enum RegistryEdit: Sendable, Hashable {
    case setString(key: String, name: String, value: String)
    case setDWord(key: String, name: String, value: UInt32)
    /// Löscht einen Schlüssel samt Inhalt.
    case deleteKey(String)

    var key: String {
        switch self {
        case let .setString(key, _, _), let .setDWord(key, _, _): key
        case let .deleteKey(key): key
        }
    }
}

public enum RegistryKeys {
    public static let dllOverrides = #"HKEY_CURRENT_USER\Software\Wine\DllOverrides"#
    public static let wineBus = #"HKEY_LOCAL_MACHINE\System\CurrentControlSet\Services\WineBus"#

    public static func appDefaultsOverrides(for executable: String) -> String {
        #"HKEY_CURRENT_USER\Software\Wine\AppDefaults\"# + executable + #"\DllOverrides"#
    }
}

/// Erzeugt `.reg`-Dateien, die `regedit /S` in einem Rutsch importiert.
public enum RegistryFile {
    public static func render(_ edits: [RegistryEdit]) -> String {
        var lines = ["Windows Registry Editor Version 5.00", ""]
        var currentKey: String?
        for edit in edits {
            switch edit {
            case let .deleteKey(key):
                if currentKey != nil { lines.append("") }
                lines.append("[-\(key)]")
                lines.append("")
                currentKey = nil
            case let .setString(key, name, value):
                openKey(key, current: &currentKey, lines: &lines)
                lines.append("\"\(escape(name))\"=\"\(escape(value))\"")
            case let .setDWord(key, name, value):
                openKey(key, current: &currentKey, lines: &lines)
                lines.append("\"\(escape(name))\"=dword:\(String(format: "%08x", value))")
            }
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// UTF-16LE mit BOM – so erwartet regedit Dateien im Format „Version 5.00“.
    public static func data(_ edits: [RegistryEdit]) -> Data {
        var data = Data([0xFF, 0xFE])
        for unit in render(edits).utf16 {
            data.append(UInt8(unit & 0xFF))
            data.append(UInt8(unit >> 8))
        }
        return data
    }

    private static func openKey(_ key: String, current: inout String?, lines: inout [String]) {
        guard current != key else { return }
        if current != nil { lines.append("") }
        lines.append("[\(key)]")
        current = key
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}

extension Wine {
    /// Importiert Registry-Änderungen über `regedit /S` in die Bottle.
    public func applyRegistry(_ edits: [RegistryEdit], in bottle: Bottle) async throws {
        guard !edits.isEmpty else { return }
        let temp = bottle.driveC.appending(path: "windows/temp", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let file = temp.appending(path: "kelter-\(UUID().uuidString.prefix(8)).reg")
        try RegistryFile.data(edits).write(to: file, options: .atomic)
        defer { try? FileManager.default.removeItem(at: file) }
        let windowsPath = "C:\\windows\\temp\\" + file.lastPathComponent
        let result = try await run(["regedit", "/S", windowsPath], in: bottle, timeout: .seconds(90))
        guard result.succeeded else {
            throw KelterError.commandFailed(command: "regedit /S", status: result.status, log: nil)
        }
    }
}
