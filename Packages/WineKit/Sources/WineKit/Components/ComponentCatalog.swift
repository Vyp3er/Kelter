import Foundation

/// Was für eine Komponente heruntergeladen wird.
public enum ComponentKind: String, Codable, Sendable, CaseIterable, Comparable {
    case wine
    /// Hilfsbibliotheken (FreeType, GnuTLS, SDL …), die manche Engines nicht selbst mitbringen.
    case runtime
    case dxmt
    case dxvk
    case moltenvk

    public var displayName: String {
        switch self {
        case .wine: "Wine-Engines"
        case .runtime: "Laufzeit-Bibliotheken"
        case .dxmt: "DXMT (Direct3D 10/11 → Metal)"
        case .dxvk: "DXVK (Direct3D → Vulkan)"
        case .moltenvk: "MoltenVK (Vulkan → Metal)"
        }
    }

    public static func < (lhs: ComponentKind, rhs: ComponentKind) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

/// Eine Download-Quelle aus `components.json`.
public struct ComponentSource: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var kind: ComponentKind
    public var name: String
    public var version: String
    public var summary: String
    public var url: URL
    /// SHA-256 des Archivs. Fehlt er, wird ohne Prüfung installiert (die Oberfläche weist darauf hin).
    public var sha256: String?
    public var sizeBytes: Int64?
    public var recommended: Bool?
    /// Fähigkeiten einer Wine-Engine, z. B. `msync` oder `dxmt`.
    public var features: [String]?
    /// IDs von Komponenten, die mit installiert werden müssen (z. B. Laufzeit-Bibliotheken einer Engine).
    public var requires: [String]?
    /// Nur diese Pfade aus dem Archiv entpacken (Ordner samt Inhalt). nil = alles.
    public var extract: [String]?
    /// Ab dieser macOS-Hauptversion funktioniert die Komponente nicht (mehr), z. B. `27`.
    public var incompatibleFromMacOS: Int?
    /// Verständliche Beschreibung des bekannten Problems.
    public var knownProblem: String?
    public var homepage: URL?
    public var license: String?

    public init(
        id: String, kind: ComponentKind, name: String, version: String, summary: String, url: URL,
        sha256: String? = nil, sizeBytes: Int64? = nil, recommended: Bool? = nil,
        features: [String]? = nil, requires: [String]? = nil, extract: [String]? = nil,
        incompatibleFromMacOS: Int? = nil, knownProblem: String? = nil,
        homepage: URL? = nil, license: String? = nil
    ) {
        self.incompatibleFromMacOS = incompatibleFromMacOS
        self.knownProblem = knownProblem
        self.requires = requires
        self.extract = extract
        self.id = id
        self.kind = kind
        self.name = name
        self.version = version
        self.summary = summary
        self.url = url
        self.sha256 = sha256
        self.sizeBytes = sizeBytes
        self.recommended = recommended
        self.features = features
        self.homepage = homepage
        self.license = license
    }

    /// Empfohlen – und auf diesem Mac lauffähig.
    public var isRecommended: Bool { (recommended ?? false) && isCompatible() }

    public static var currentMacOSMajor: Int { ProcessInfo.processInfo.operatingSystemVersion.majorVersion }

    /// Funktioniert die Komponente unter dieser macOS-Version?
    public func isCompatible(macOSMajor: Int = ComponentSource.currentMacOSMajor) -> Bool {
        guard let limit = incompatibleFromMacOS else { return true }
        return macOSMajor < limit
    }

    /// Das bekannte Problem, falls es diesen Mac betrifft.
    public func problem(macOSMajor: Int = ComponentSource.currentMacOSMajor) -> String? {
        guard !isCompatible(macOSMajor: macOSMajor) else { return nil }
        return knownProblem ?? "Funktioniert ab macOS \(incompatibleFromMacOS ?? macOSMajor) nicht."
    }
}

/// Liste aller bekannten Download-Quellen.
///
/// Die mitgelieferte Liste steckt in WineKit. Eigene Einträge kommen in
/// `Catalog/components.json` und ergänzen oder ersetzen (gleiche `id`) die mitgelieferten.
/// Zum Nachschlagen legt Kelter die mitgelieferte Liste als `Catalog/components.default.json` ab.
public struct ComponentCatalog: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var components: [ComponentSource]

    public init(schemaVersion: Int = 1, components: [ComponentSource] = []) {
        self.schemaVersion = schemaVersion
        self.components = components
    }

    public static func decode(_ data: Data) throws -> ComponentCatalog {
        try JSONDecoder().decode(ComponentCatalog.self, from: data)
    }

    static func bundledData() throws -> Data {
        guard let url = Bundle.module.url(forResource: "components", withExtension: "json") else {
            throw KelterError.catalogMissing
        }
        return try Data(contentsOf: url)
    }

    public static func bundled() throws -> ComponentCatalog {
        try decode(bundledData())
    }

    /// Lädt die mitgelieferte Liste und legt die des Nutzers darüber.
    /// - Returns: Den Katalog und ggf. eine Warnung, falls die Nutzerdatei fehlerhaft ist.
    public static func load(paths: KelterPaths) throws -> (catalog: ComponentCatalog, warning: String?) {
        let data = try bundledData()
        var catalog = try decode(data)
        try? FileManager.default.createDirectory(at: paths.catalog, withIntermediateDirectories: true)
        try? data.write(to: paths.catalog.appending(path: "components.default.json"), options: .atomic)

        let userFile = paths.catalog.appending(path: "components.json")
        guard FileManager.default.fileExists(atPath: userFile.path) else { return (catalog, nil) }
        do {
            catalog.merge(try decode(Data(contentsOf: userFile)))
            return (catalog, nil)
        } catch {
            return (catalog, "Catalog/components.json konnte nicht gelesen werden und wird ignoriert: \(error.localizedDescription)")
        }
    }

    /// Ergänzt Einträge; bei gleicher `id` gewinnt `other`.
    public mutating func merge(_ other: ComponentCatalog) {
        for component in other.components {
            if let index = components.firstIndex(where: { $0.id == component.id }) {
                components[index] = component
            } else {
                components.append(component)
            }
        }
    }

    public func components(of kind: ComponentKind) -> [ComponentSource] {
        components.filter { $0.kind == kind }
    }

    public func source(id: String) -> ComponentSource? {
        components.first { $0.id == id }
    }

    /// Alle Quellen, die für `source` installiert sein müssen, in Installationsreihenfolge
    /// (Abhängigkeiten zuerst, `source` selbst zuletzt). Unbekannte IDs werden übersprungen.
    public func installOrder(for source: ComponentSource) -> [ComponentSource] {
        var order: [ComponentSource] = []
        var visiting: Set<String> = []
        func visit(_ current: ComponentSource) {
            guard !order.contains(where: { $0.id == current.id }), visiting.insert(current.id).inserted else { return }
            for id in current.requires ?? [] {
                if let dependency = self.source(id: id) { visit(dependency) }
            }
            order.append(current)
        }
        visit(source)
        return order
    }

    /// Die empfohlene Wine-Engine: erster Eintrag mit `recommended: true`, der auf diesem Mac läuft.
    public var recommendedEngine: ComponentSource? {
        components.first { $0.kind == .wine && $0.isRecommended }
            ?? components.first { $0.kind == .wine && $0.isCompatible() }
            ?? components.first { $0.kind == .wine }
    }
}
