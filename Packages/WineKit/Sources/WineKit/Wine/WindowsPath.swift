import Foundation

/// Umrechnung zwischen Windows-Pfaden (`C:\Programme\…`) und Mac-Pfaden in einer Bottle.
///
/// Wine bildet Laufwerke über Symlinks in `<Bottle>/dosdevices/` ab:
/// `c:` → `../drive_c`, `z:` → `/` (das ganze Mac-Dateisystem).
public enum WindowsPath {
    /// Letzter Bestandteil, egal ob mit `\` oder `/` getrennt: `C:\a\steam.exe` → `steam.exe`.
    public static func fileName(_ path: String) -> String {
        path.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last.map(String.init) ?? path
    }

    /// Vergleichbarer Programmname: klein geschrieben, ohne `.exe`. `C:\a\Steam.exe` → `steam`.
    public static func baseName(_ path: String) -> String {
        var name = fileName(path).lowercased()
        if name.hasSuffix(".exe") { name.removeLast(4) }
        return name
    }

    /// `C:\Program Files\x.exe` → `<prefix>/drive_c/Program Files/x.exe`.
    public static func unixURL(for windowsPath: String, prefix: URL) -> URL? {
        let characters = Array(windowsPath)
        guard characters.count >= 2, characters[1] == ":", characters[0].isLetter else { return nil }
        let letter = characters[0].lowercased()
        let rest = String(characters.dropFirst(2))
        let components = rest.split(whereSeparator: { $0 == "\\" || $0 == "/" }).map(String.init)

        guard var base = driveRoot(letter: letter, prefix: prefix) else { return nil }
        for component in components {
            base.append(path: component)
        }
        return base.standardizedFileURL
    }

    /// Mac-Pfad → Windows-Pfad. In `drive_c` wird daraus `C:\…`, alles andere über `Z:\…`.
    public static func windowsPath(for url: URL, prefix: URL) -> String? {
        let path = url.standardizedFileURL.path
        let driveC = prefix.appending(path: "drive_c").standardizedFileURL.path
        if path == driveC { return "C:\\" }
        if path.hasPrefix(driveC + "/") {
            let relative = path.dropFirst(driveC.count + 1)
            return "C:\\" + relative.replacingOccurrences(of: "/", with: "\\")
        }
        guard path.hasPrefix("/") else { return nil }
        return "Z:" + path.replacingOccurrences(of: "/", with: "\\")
    }

    private static func driveRoot(letter: String, prefix: URL) -> URL? {
        let dosdevices = prefix.appending(path: "dosdevices", directoryHint: .isDirectory)
        let link = dosdevices.appending(path: "\(letter):")
        if let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path) {
            return URL(fileURLWithPath: destination, relativeTo: dosdevices).absoluteURL
        }
        switch letter {
        case "c": return prefix.appending(path: "drive_c", directoryHint: .isDirectory)
        case "z": return URL(fileURLWithPath: "/")
        default: return nil
        }
    }
}

/// Startargumente als Text ↔ Liste. Anführungszeichen gruppieren, Backslashes bleiben stehen
/// (wichtig für Windows-Pfade).
public enum ArgumentList {
    public static func split(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        var quote: Character?
        var hasToken = false
        for character in text {
            if let open = quote {
                if character == open {
                    quote = nil
                } else {
                    current.append(character)
                }
            } else if character == "\"" || character == "'" {
                quote = character
                hasToken = true
            } else if character.isWhitespace {
                if hasToken || !current.isEmpty {
                    result.append(current)
                    current = ""
                    hasToken = false
                }
            } else {
                current.append(character)
                hasToken = true
            }
        }
        if hasToken || !current.isEmpty { result.append(current) }
        return result
    }

    public static func join(_ arguments: [String]) -> String {
        arguments
            .map { argument in
                argument.isEmpty || argument.contains(where: \.isWhitespace) ? "\"\(argument)\"" : argument
            }
            .joined(separator: " ")
    }
}
