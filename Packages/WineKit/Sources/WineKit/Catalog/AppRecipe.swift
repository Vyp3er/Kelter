import Foundation

/// Ein Katalog-Rezept: wie eine App (z. B. Steam) in eine eigene Bottle installiert wird.
///
/// Mitgelieferte Rezepte stecken in WineKit. Eigene Rezepte legst du als `Catalog/<id>.json`
/// ab; gleiche `id` ersetzt ein mitgeliefertes Rezept. Zum Nachschlagen schreibt Kelter die
/// mitgelieferten Rezepte nach `Catalog/Mitgeliefert/`.
public struct AppRecipe: Codable, Sendable, Identifiable, Hashable {
    public var schemaVersion: Int?
    public var id: String
    public var name: String
    public var publisher: String?
    public var category: String?
    public var summary: String
    public var description: String?
    /// SF-Symbol für die Kachel, solange die App noch nicht installiert ist.
    public var symbol: String?
    /// Kachelfarbe als Hex, z. B. `#1B2838`.
    public var tint: String?
    public var homepage: URL?
    public var installer: Installer
    /// IDs aus `prerequisites.json` (z. B. VC++-Runtime, Schriftarten).
    public var prerequisites: [String]?
    /// IDs aus dem Komponenten-Katalog, die vorher installiert sein müssen (z. B. DXVK).
    public var requiredComponents: [String]?
    public var graphicsBackend: GraphicsBackend?
    /// Grafik-Ausnahmen pro Programm, z. B. `"steamwebhelper.exe": "dxvk"`.
    public var executableBackends: [String: GraphicsBackend]?
    public var windowsVersion: WindowsVersion?
    /// Windows-Pfad der Start-EXE nach der Installation.
    public var executable: String
    /// Weitere mögliche Orte der Start-EXE (z. B. 32- vs. 64-Bit-Ordner).
    public var alternativeExecutables: [String]?
    public var arguments: [String]?
    public var environment: [String: String]?
    public var knownIssues: [String]?
    /// Läuft erfahrungsgemäß nur eingeschränkt.
    public var experimental: Bool?

    public struct Installer: Codable, Sendable, Hashable {
        /// Offizielle Download-Adresse des Anbieters (https).
        public var url: URL
        public var fileName: String?
        public var type: InstallerType?
        /// Argumente für eine stille Installation (z. B. `/S`).
        public var arguments: [String]?
        /// Der Installer zeigt Fenster, durch die du dich selbst klickst.
        public var interactive: Bool?
        public var sha256: String?
        public var approximateSize: Int64?

        public var resolvedFileName: String {
            if let fileName, !fileName.isEmpty { return fileName }
            let last = url.lastPathComponent
            return last.contains(".") ? last : "installer.exe"
        }

        public var resolvedType: InstallerType {
            type ?? (resolvedFileName.lowercased().hasSuffix(".msi") ? .msi : .exe)
        }
    }

    public enum InstallerType: String, Codable, Sendable {
        case exe
        case msi
    }

    public var allExecutables: [String] { [executable] + (alternativeExecutables ?? []) }
    public var isExperimental: Bool { experimental ?? false }
    public var isInteractive: Bool { installer.interactive ?? false }
}

/// Eine Laufzeitkomponente, die ein Rezept vor dem eigentlichen Installer braucht.
public struct Prerequisite: Codable, Sendable, Identifiable, Hashable {
    public enum Kind: String, Codable, Sendable {
        /// Offizieller Installer (z. B. Microsofts VC++-Runtime), still ausgeführt.
        case installer
        /// Windows-kompatible Schriften, die macOS mitbringt, nach `C:\windows\Fonts` kopieren.
        case macosFonts
    }

    public var id: String
    public var name: String
    public var summary: String
    public var kind: Kind
    public var url: URL?
    public var fileName: String?
    public var arguments: [String]?
    /// Exit-Codes, die als Erfolg zählen (VC++: 3010 = Neustart nötig, 1638 = schon neuer installiert).
    public var successCodes: [Int32]?
    /// DLL-Overrides nach der Installation, z. B. `msvcp140` → `native,builtin`.
    public var dllOverrides: [String: String]?
    /// Für `macosFonts`: Dateinamen in `/System/Library/Fonts/Supplemental`.
    public var fonts: [String]?
    public var approximateSize: Int64?
}

/// Alle Rezepte und Laufzeitkomponenten.
public struct RecipeCatalog: Sendable {
    public var recipes: [AppRecipe]
    public var prerequisites: [Prerequisite]
    /// Hinweise zu eigenen Rezeptdateien, die nicht gelesen werden konnten.
    public var warnings: [String]

    public init(recipes: [AppRecipe] = [], prerequisites: [Prerequisite] = [], warnings: [String] = []) {
        self.recipes = recipes
        self.prerequisites = prerequisites
        self.warnings = warnings
    }

    public func recipe(id: String) -> AppRecipe? { recipes.first { $0.id == id } }
    public func prerequisite(id: String) -> Prerequisite? { prerequisites.first { $0.id == id } }

    /// Mitgelieferte Rezepte + eigene Dateien aus `Catalog/*.json` (außer `components*.json`).
    public static func load(paths: KelterPaths) -> RecipeCatalog {
        var warnings: [String] = []
        var recipes = bundledRecipes()
        let prerequisites = bundledPrerequisites()

        // Mitgelieferte Rezepte zum Nachschlagen/Kopieren ablegen.
        let reference = paths.catalog.appending(path: "Mitgeliefert", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: reference, withIntermediateDirectories: true)
        for recipe in recipes {
            if let data = try? JSONEncoder.kelter.encode(recipe) {
                try? data.write(to: reference.appending(path: "\(recipe.id).json"), options: .atomic)
            }
        }

        let files = (try? FileManager.default.contentsOfDirectory(at: paths.catalog, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where file.pathExtension == "json" && !file.lastPathComponent.hasPrefix("components") {
            do {
                let recipe = try JSONDecoder.kelter.decode(AppRecipe.self, from: Data(contentsOf: file))
                try validate(recipe)
                if let index = recipes.firstIndex(where: { $0.id == recipe.id }) {
                    recipes[index] = recipe
                } else {
                    recipes.append(recipe)
                }
            } catch {
                warnings.append("\(file.lastPathComponent): \(error.localizedDescription)")
            }
        }
        recipes.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return RecipeCatalog(recipes: recipes, prerequisites: prerequisites, warnings: warnings)
    }

    /// Nur offizielle Downloads über https und ein Windows-Pfad als Start-EXE.
    static func validate(_ recipe: AppRecipe) throws {
        guard recipe.installer.url.scheme == "https" else {
            throw RecipeError.invalid("Installer-URL muss mit https:// beginnen.")
        }
        guard WindowsPath.unixURL(for: recipe.executable, prefix: URL(fileURLWithPath: "/tmp")) != nil else {
            throw RecipeError.invalid("„executable“ muss ein Windows-Pfad wie C:\\… sein.")
        }
    }

    static func bundledRecipes() -> [AppRecipe] {
        guard let folder = Bundle.module.url(forResource: "Recipes", withExtension: nil),
              let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        else { return [] }
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder.kelter.decode(AppRecipe.self, from: Data(contentsOf: $0)) }
    }

    static func bundledPrerequisites() -> [Prerequisite] {
        guard let url = Bundle.module.url(forResource: "prerequisites", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder.kelter.decode([Prerequisite].self, from: data)
        else { return [] }
        return list
    }
}

public enum RecipeError: LocalizedError, Sendable, Equatable {
    case invalid(String)
    case executableNotFound([String])
    case installerFailed(Int32, String?)

    public var errorDescription: String? {
        switch self {
        case let .invalid(reason):
            "Rezept ungültig: \(reason)"
        case let .executableNotFound(paths):
            "Nach der Installation wurde das Programm nicht gefunden. Gesucht wurde:\n" + paths.joined(separator: "\n")
                + "\n\nWurde der Installer abgebrochen? Details stehen im Installations-Log der Bottle."
        case let .installerFailed(status, log):
            "Der Installer ist mit Code \(status) fehlgeschlagen." + (log.map { "\nDetails im Log: \($0)" } ?? "")
        }
    }
}
