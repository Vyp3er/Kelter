import Foundation

/// Die Ordner, die Kelter unter `~/Library/Application Support/Kelter/` verwaltet.
///
/// ```
/// Kelter/
///   kelter-settings.json   App-Einstellungen (z. B. Standard-Engine)
///   Engines/<id>/          Wine-Engines und Grafik-Komponenten (DXMT, DXVK, MoltenVK)
///   Bottles/<Name>/        je eine Bottle = ein WINEPREFIX
///   Catalog/               Download-Quellen und (ab Meilenstein 3) App-Rezepte
///   Logs/                  stdout/stderr aller gestarteten Programme
///   Downloads/             Zwischenablage für laufende Downloads
/// ```
public struct KelterPaths: Sendable, Hashable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// `~/Library/Application Support/Kelter`
    public static let standard: KelterPaths = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return KelterPaths(root: base.appending(path: "Kelter", directoryHint: .isDirectory))
    }()

    public var engines: URL { root.appending(path: "Engines", directoryHint: .isDirectory) }
    public var bottles: URL { root.appending(path: "Bottles", directoryHint: .isDirectory) }
    public var catalog: URL { root.appending(path: "Catalog", directoryHint: .isDirectory) }
    public var logs: URL { root.appending(path: "Logs", directoryHint: .isDirectory) }
    public var downloads: URL { root.appending(path: "Downloads", directoryHint: .isDirectory) }
    public var settingsFile: URL { root.appending(path: "kelter-settings.json") }

    public func createDirectories() throws {
        for directory in [root, engines, bottles, catalog, logs, downloads] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    /// Freier Speicherplatz auf dem Volume, auf dem Kelter seine Daten ablegt.
    public func availableDiskSpace() -> Int64? {
        let probe = FileManager.default.fileExists(atPath: root.path) ? root : FileManager.default.homeDirectoryForCurrentUser
        let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}
