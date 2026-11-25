import Foundation

/// Ein Windows-Programm in „Meine Apps“. Gehört immer zu genau einer Bottle und wird in
/// `Bottles/<Name>/kelter-apps.json` gespeichert.
public struct InstalledApp: Codable, Sendable, Identifiable, Hashable {
    public var schemaVersion: Int = 1
    public var id: UUID
    public var name: String
    /// Windows-Pfad der Start-EXE, z. B. `C:\Program Files (x86)\Steam\steam.exe`.
    public var executable: String
    /// Argumente dieser App (die Startargumente der Bottle kommen dahinter).
    public var arguments: [String]
    /// Zusätzliche Umgebungsvariablen (z. B. aus einem Katalog-Rezept).
    public var environment: [String: String]
    /// Katalog-Rezept, aus dem die App installiert wurde.
    public var recipeID: String?
    /// FPS-Anzeige beim Start.
    public var performanceHUD: PerformanceHUD = .off
    /// Steam-Spiel: wird über `steam.exe -applaunch <id>` gestartet.
    public var steamAppID: String?
    /// Windows-Ordner, dessen Prozesse als „diese App läuft“ zählen (bei Steam-Spielen der Spielordner).
    public var processFolder: String?
    /// EXE, aus der das Icon gelesen wird (sonst `executable`).
    public var iconExecutable: String?
    public var addedAt: Date

    public init(
        id: UUID = UUID(), name: String, executable: String, arguments: [String] = [],
        environment: [String: String] = [:], recipeID: String? = nil, performanceHUD: PerformanceHUD = .off,
        steamAppID: String? = nil, processFolder: String? = nil, iconExecutable: String? = nil, addedAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.recipeID = recipeID
        self.performanceHUD = performanceHUD
        self.steamAppID = steamAppID
        self.processFolder = processFolder
        self.iconExecutable = iconExecutable
        // Auf ganze Sekunden runden: JSON speichert ISO-8601 ohne Sekundenbruchteile.
        self.addedAt = Date(timeIntervalSince1970: addedAt.timeIntervalSince1970.rounded(.down))
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, name, executable, arguments, environment, recipeID, performanceHUD
        case steamAppID, processFolder, iconExecutable, addedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        executable = try container.decode(String.self, forKey: .executable)
        arguments = try container.decodeIfPresent([String].self, forKey: .arguments) ?? []
        environment = try container.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
        recipeID = try container.decodeIfPresent(String.self, forKey: .recipeID)
        performanceHUD = try container.decodeIfPresent(PerformanceHUD.self, forKey: .performanceHUD) ?? .off
        steamAppID = try container.decodeIfPresent(String.self, forKey: .steamAppID)
        processFolder = try container.decodeIfPresent(String.self, forKey: .processFolder)
        iconExecutable = try container.decodeIfPresent(String.self, forKey: .iconExecutable)
        addedAt = try container.decodeIfPresent(Date.self, forKey: .addedAt) ?? .now
    }

    /// `steam.exe`
    public var executableName: String { WindowsPath.fileName(executable) }

    /// Gehört ein laufender Prozess zu dieser App?
    public func owns(_ process: WineProcessInfo) -> Bool {
        if let folder = processFolder {
            return process.isInside(windowsFolder: folder)
        }
        return process.matches(executable: executable)
    }
}

/// FPS-Anzeige im Spiel.
public enum PerformanceHUD: String, Codable, Sendable, CaseIterable {
    case off
    /// Apples Metal Performance HUD – funktioniert mit DXMT und DXVK (beide zeichnen über Metal).
    case metal
    /// DXVKs eigenes Overlay – nur in Programmen, die über DXVK laufen.
    case dxvk

    public var displayName: String {
        switch self {
        case .off: "Aus"
        case .metal: "Metal Performance HUD"
        case .dxvk: "DXVK-HUD"
        }
    }

    public var environment: [String: String] {
        switch self {
        case .off: [:]
        case .metal: ["MTL_HUD_ENABLED": "1"]
        case .dxvk: ["DXVK_HUD": "fps,frametimes,gpuload,api"]
        }
    }
}

/// Liest und schreibt die Apps einer Bottle und deren Icons.
public enum AppStore {
    public static let fileName = "kelter-apps.json"
    public static let iconFolder = "kelter-icons"

    private struct FileContents: Codable {
        var schemaVersion: Int? = 1
        var apps: [InstalledApp]
    }

    public static func load(for bottle: Bottle) -> [InstalledApp] {
        let file = bottle.url.appending(path: fileName)
        guard let data = try? Data(contentsOf: file),
              let contents = try? JSONDecoder.kelter.decode(FileContents.self, from: data)
        else { return [] }
        return contents.apps
    }

    public static func save(_ apps: [InstalledApp], for bottle: Bottle) throws {
        let data = try JSONEncoder.kelter.encode(FileContents(apps: apps))
        try data.write(to: bottle.url.appending(path: fileName), options: .atomic)
    }

    public static func iconURL(for app: InstalledApp, in bottle: Bottle) -> URL {
        bottle.url.appending(path: iconFolder).appending(path: "\(app.id.uuidString).ico")
    }

    /// Liefert das zwischengespeicherte Icon oder liest es einmalig aus der EXE.
    public static func cachedIcon(for app: InstalledApp, in bottle: Bottle) -> URL? {
        let target = iconURL(for: app, in: bottle)
        if FileManager.default.fileExists(atPath: target.path) { return target }
        guard let exe = WindowsPath.unixURL(for: app.iconExecutable ?? app.executable, prefix: bottle.url),
              let data = PEIcon.icoData(fromExecutableAt: exe)
        else { return nil }
        do {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: target, options: .atomic)
            return target
        } catch {
            return nil
        }
    }

    public static func removeIcon(for app: InstalledApp, in bottle: Bottle) {
        try? FileManager.default.removeItem(at: iconURL(for: app, in: bottle))
    }
}
