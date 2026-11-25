import Foundation

/// Eine installierte Komponente. Liegt als `Engines/<id>/kelter-engine.json` neben dem Ordner `files/`.
public struct InstalledComponent: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var kind: ComponentKind
    public var name: String
    /// Version laut Download-Quelle.
    public var version: String
    /// Version, die das Programm selbst meldet (bei Wine: `wine --version`).
    public var detectedVersion: String?
    public var sourceURL: URL?
    /// Geprüfte Prüfsumme des Archivs (nil = Quelle hatte keine).
    public var sha256: String?
    public var installedAt: Date
    public var features: [String]
    /// Benötigte Komponenten (z. B. Laufzeit-Bibliotheken).
    public var requires: [String]?

    public init(
        id: String, kind: ComponentKind, name: String, version: String, detectedVersion: String? = nil,
        sourceURL: URL? = nil, sha256: String? = nil, installedAt: Date = .now, features: [String] = [],
        requires: [String]? = nil
    ) {
        self.requires = requires
        self.id = id
        self.kind = kind
        self.name = name
        self.version = version
        self.detectedVersion = detectedVersion
        self.sourceURL = sourceURL
        self.sha256 = sha256
        self.installedAt = installedAt
        self.features = features
    }
}

/// Liest und verwaltet `Engines/`.
public struct ComponentStore: Sendable {
    public static let manifestName = "kelter-engine.json"
    public let paths: KelterPaths

    public init(paths: KelterPaths) {
        self.paths = paths
    }

    public func directory(for id: String) -> URL {
        paths.engines.appending(path: id, directoryHint: .isDirectory)
    }

    /// Der eigentliche Inhalt. Bei Wine ist das der Ordner mit `bin/`, `lib/`, `share/`.
    public func filesDirectory(for id: String) -> URL {
        directory(for: id).appending(path: "files", directoryHint: .isDirectory)
    }

    public func installed() -> [InstalledComponent] {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(at: paths.engines, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) else {
            return []
        }
        let decoder = JSONDecoder.kelter
        return entries
            .compactMap { folder -> InstalledComponent? in
                let manifest = folder.appending(path: Self.manifestName)
                guard let data = try? Data(contentsOf: manifest) else { return nil }
                return try? decoder.decode(InstalledComponent.self, from: data)
            }
            .sorted { ($0.kind, $0.name) < ($1.kind, $1.name) }
    }

    public func save(_ component: InstalledComponent) throws {
        let data = try JSONEncoder.kelter.encode(component)
        try data.write(to: directory(for: component.id).appending(path: Self.manifestName), options: .atomic)
    }

    /// Löscht die Komponente endgültig (sie lässt sich jederzeit neu laden).
    public func remove(id: String) throws {
        let folder = directory(for: id)
        if FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.removeItem(at: folder)
        }
    }

    public func engine(id: String) -> WineEngine? {
        let all = installed()
        guard let component = all.first(where: { $0.id == id && $0.kind == .wine }) else { return nil }
        let root = filesDirectory(for: id)
        guard WineLayout.isWineRoot(root) else { return nil }

        var runtime: RuntimeLibraries?
        var missing: [String] = []
        for requirement in component.requires ?? [] {
            guard let dependency = all.first(where: { $0.id == requirement }) else {
                missing.append(requirement)
                continue
            }
            if dependency.kind == .runtime {
                runtime = RuntimeLibraries(root: filesDirectory(for: requirement))
            }
        }
        return WineEngine(component: component, root: root, runtime: runtime, missingRequirements: missing)
    }
}

extension JSONEncoder {
    /// Lesbares JSON, damit man die Dateien auch von Hand bearbeiten kann.
    static var kelter: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var kelter: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
