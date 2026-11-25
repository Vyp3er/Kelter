import Foundation

/// App-weite Einstellungen in `kelter-settings.json`.
public struct KelterSettings: Codable, Sendable, Equatable {
    public var schemaVersion: Int = 1
    /// Engine für neue Bottles und für Bottles ohne eigene Engine-Wahl.
    public var defaultEngineID: String?

    public init(defaultEngineID: String? = nil) {
        self.defaultEngineID = defaultEngineID
    }

    public static func load(paths: KelterPaths) -> KelterSettings {
        guard let data = try? Data(contentsOf: paths.settingsFile),
              let settings = try? JSONDecoder.kelter.decode(KelterSettings.self, from: data)
        else { return KelterSettings() }
        return settings
    }

    public func save(paths: KelterPaths) throws {
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        try JSONEncoder.kelter.encode(self).write(to: paths.settingsFile, options: .atomic)
    }
}
