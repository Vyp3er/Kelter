import Foundation

/// Eine Bottle ist ein eigenständiges „Windows“ (WINEPREFIX) mit eigenem Laufwerk C:
/// und eigener Registry. Der Ordner `Bottles/<Name>/` ist selbst der WINEPREFIX.
public struct Bottle: Sendable, Identifiable, Hashable {
    public let url: URL
    public var settings: BottleSettings

    public init(url: URL, settings: BottleSettings) {
        self.url = url
        self.settings = settings
    }

    /// Ordnername, eindeutig innerhalb von `Bottles/`.
    public var id: String { url.lastPathComponent }
    public var name: String { settings.name }
    public var driveC: URL { url.appending(path: "drive_c", directoryHint: .isDirectory) }
    public var settingsFile: URL { url.appending(path: BottleStore.settingsFileName) }

    /// Fertig eingerichtet? `system.reg` allein reicht nicht: Wine legt die Datei sofort an,
    /// auch wenn `wineboot` danach scheitert. Erst ein erfolgreiches `wineboot` schreibt
    /// `.update-timestamp` und die Windows-DLLs nach `system32`.
    public var isInitialized: Bool {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.appending(path: "system.reg").path) else { return false }
        return fileManager.fileExists(atPath: url.appending(path: ".update-timestamp").path)
            || fileManager.fileExists(atPath: driveC.appending(path: "windows/system32/kernel32.dll").path)
    }

    /// Reste eines abgebrochenen Einrichtens (Registry, Laufwerks-Links), aber nicht fertig.
    public var hasIncompleteSetup: Bool {
        guard !isInitialized else { return false }
        return Self.incompleteSetupItems.contains {
            FileManager.default.fileExists(atPath: url.appending(path: $0).path)
        }
    }

    /// Was Wine beim ersten Start anlegt. Ohne `dosdevices` richtet Wine die Bottle beim
    /// nächsten Start komplett neu ein. `drive_c` bleibt stehen (kann Nutzerdateien enthalten).
    static let incompleteSetupItems = ["system.reg", "user.reg", "userdef.reg", ".update-timestamp", "dosdevices"]

    /// Entfernt die Reste eines gescheiterten Einrichtens, damit `wineboot` neu beginnt.
    /// Tut nichts bei fertig eingerichteten Bottles.
    public func removeIncompleteSetup() throws {
        guard hasIncompleteSetup else { return }
        for item in Self.incompleteSetupItems {
            let target = url.appending(path: item)
            // attributesOfItem folgt keinen Symlinks; removeItem löscht Links in dosdevices nur
            // als Links (z: zeigt auf „/“ – das Ziel bleibt unberührt).
            if (try? FileManager.default.attributesOfItem(atPath: target.path)) != nil {
                try FileManager.default.removeItem(at: target)
            }
        }
    }
}

/// Liest und verwaltet `Bottles/`.
public struct BottleStore: Sendable {
    public static let settingsFileName = "kelter-bottle.json"
    public let paths: KelterPaths

    public init(paths: KelterPaths) {
        self.paths = paths
    }

    public func list() -> [Bottle] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: paths.bottles,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        )) ?? []
        return entries
            .compactMap(load)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func load(_ folder: URL) -> Bottle? {
        let file = folder.appending(path: Self.settingsFileName)
        guard let data = try? Data(contentsOf: file),
              let settings = try? JSONDecoder.kelter.decode(BottleSettings.self, from: data)
        else { return nil }
        return Bottle(url: folder, settings: settings)
    }

    /// Legt den Ordner und die Einstellungsdatei an. Wine selbst richtet die Bottle erst mit
    /// ``Wine/initialize(_:)`` ein.
    public func create(name: String, engineID: String?) throws -> Bottle {
        let folderName = try Self.folderName(for: name)
        let folder = paths.bottles.appending(path: folderName, directoryHint: .isDirectory)
        guard !FileManager.default.fileExists(atPath: folder.path) else {
            throw KelterError.bottleExists(name.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let bottle = Bottle(url: folder, settings: BottleSettings(name: name.trimmingCharacters(in: .whitespacesAndNewlines), engineID: engineID))
        try save(bottle)
        return bottle
    }

    public func save(_ bottle: Bottle) throws {
        try JSONEncoder.kelter.encode(bottle.settings).write(to: bottle.settingsFile, options: .atomic)
    }

    /// Verschiebt die Bottle in den Papierkorb (Spielstände usw. lassen sich so noch retten).
    public func moveToTrash(_ bottle: Bottle) throws {
        try FileManager.default.trashItem(at: bottle.url, resultingItemURL: nil)
    }

    /// Macht aus einem Anzeigenamen einen sicheren Ordnernamen.
    public static func folderName(for name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = trimmed
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        guard !cleaned.isEmpty, !cleaned.hasPrefix(".") else { throw KelterError.invalidBottleName }
        return cleaned
    }
}
