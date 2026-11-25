import Foundation

/// Ein in Steam installiertes Spiel (aus `steamapps/appmanifest_<id>.acf`).
public struct SteamGame: Sendable, Identifiable, Hashable {
    public let appID: String
    public let name: String
    public let installDir: String
    /// Windows-Pfad der Steam-Bibliothek, z. B. `C:\Program Files (x86)\Steam`.
    public let library: String
    public let sizeOnDisk: Int64
    /// Steam meldet „vollständig installiert“ mit Bit 4 in `StateFlags`.
    public let isFullyInstalled: Bool

    public var id: String { appID }

    /// `C:\…\steamapps\common\<installdir>`
    public var folder: String { library + "\\steamapps\\common\\" + installDir }
}

/// Liest Steams Bibliotheksdateien (VDF/ACF) aus einer Bottle.
public enum SteamLibrary {
    /// „Steamworks Common Redistributables“ und Proton-Werkzeuge sind keine Spiele.
    static let ignoredAppIDs: Set<String> = ["228980", "1070560", "1391110", "1628350"]

    public static func games(steamExecutable: String, prefix: URL) -> [SteamGame] {
        let steamRoot = steamExecutable.split(separator: "\\").dropLast().joined(separator: "\\")
        var libraries = [steamRoot]
        if let url = WindowsPath.unixURL(for: steamRoot + "\\steamapps\\libraryfolders.vdf", prefix: prefix),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            for (key, value) in keyValues(in: text) where key == "path" {
                let path = value.replacingOccurrences(of: "\\\\", with: "\\")
                if !libraries.contains(where: { $0.caseInsensitiveCompare(path) == .orderedSame }) {
                    libraries.append(path)
                }
            }
        }

        var games: [SteamGame] = []
        for library in libraries {
            guard let steamapps = WindowsPath.unixURL(for: library + "\\steamapps", prefix: prefix),
                  let files = try? FileManager.default.contentsOfDirectory(atPath: steamapps.path)
            else { continue }
            for file in files where file.hasPrefix("appmanifest_") && file.hasSuffix(".acf") {
                guard let text = try? String(contentsOf: steamapps.appending(path: file), encoding: .utf8),
                      let game = parseManifest(text, library: library),
                      !ignoredAppIDs.contains(game.appID)
                else { continue }
                games.append(game)
            }
        }
        return games.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func parseManifest(_ text: String, library: String) -> SteamGame? {
        var values: [String: String] = [:]
        for (key, value) in keyValues(in: text) where values[key] == nil {
            values[key] = value
        }
        guard let appID = values["appid"], let name = values["name"], let installDir = values["installdir"] else { return nil }
        let flags = Int(values["StateFlags"] ?? "") ?? 0
        return SteamGame(
            appID: appID,
            name: name,
            installDir: installDir,
            library: library,
            sizeOnDisk: Int64(values["SizeOnDisk"] ?? "") ?? 0,
            isFullyInstalled: flags & 4 != 0
        )
    }

    /// Alle `"schlüssel"  "wert"`-Paare einer VDF-Datei, in Dateireihenfolge (Verschachtelung egal).
    static func keyValues(in text: String) -> [(String, String)] {
        var result: [(String, String)] = []
        var strings: [String] = []
        var current = ""
        var inString = false
        var escaped = false
        var lastWasKey = false
        for character in text {
            if inString {
                if escaped {
                    current.append(character)
                    escaped = false
                } else if character == "\\" {
                    current.append(character)
                    escaped = true
                } else if character == "\"" {
                    inString = false
                    strings.append(current)
                    current = ""
                    if lastWasKey, strings.count >= 2 {
                        result.append((strings[strings.count - 2], strings[strings.count - 1]))
                        lastWasKey = false
                    } else {
                        lastWasKey = true
                    }
                } else {
                    current.append(character)
                }
            } else if character == "\"" {
                inString = true
            } else if character == "{" || character == "}" {
                // Ein Schlüssel vor „{“ hat keinen Wert – das nächste Wort ist wieder ein Schlüssel.
                lastWasKey = false
            }
        }
        return result
    }

    /// Kandidaten für die Start-EXE eines Spiels (für Grafik-Ausnahmen), größte zuerst.
    public static func executables(of game: SteamGame, prefix: URL) -> [String] {
        guard let folder = WindowsPath.unixURL(for: game.folder, prefix: prefix),
              let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])
        else { return [] }
        let skip = ["unins", "crash", "setup", "redist", "vc_redist", "dxsetup", "launcherhelper", "eac", "easyanticheat", "battleye"]
        var found: [(name: String, size: Int)] = []
        for case let url as URL in enumerator {
            if enumerator.level > 2 { enumerator.skipDescendants(); continue }
            let name = url.lastPathComponent
            guard name.lowercased().hasSuffix(".exe"), !skip.contains(where: name.lowercased().contains) else { continue }
            found.append((name, (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0))
        }
        var seen: Set<String> = []
        return found.sorted { $0.size > $1.size }.map(\.name).filter { seen.insert($0.lowercased()).inserted }
    }
}

extension WineProcessInfo {
    /// Liegt das Windows-Programm dieses Prozesses in `windowsFolder` (oder darunter)?
    public func isInside(windowsFolder: String) -> Bool {
        guard let program = windowsProgram?.replacingOccurrences(of: "/", with: "\\").lowercased() else { return false }
        let folder = windowsFolder.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "\\"))
        return program.hasPrefix(folder + "\\")
    }
}
