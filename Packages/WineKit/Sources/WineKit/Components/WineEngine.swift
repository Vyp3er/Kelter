import Foundation

/// Eine installierte, startbereite Wine-Engine.
public struct WineEngine: Sendable, Hashable, Identifiable {
    public let component: InstalledComponent
    /// Ordner mit `bin/`, `lib/`, `share/`.
    public let root: URL
    /// Hilfsbibliotheken, falls die Engine sie nicht selbst mitbringt (Sikarugir).
    public let runtime: RuntimeLibraries?
    /// IDs benötigter Komponenten, die (noch) nicht installiert sind.
    public let missingRequirements: [String]

    public init(component: InstalledComponent, root: URL, runtime: RuntimeLibraries? = nil, missingRequirements: [String] = []) {
        self.component = component
        self.root = root
        self.runtime = runtime
        self.missingRequirements = missingRequirements
    }

    public var id: String { component.id }
    public var name: String { component.name }
    public var isComplete: Bool { missingRequirements.isEmpty }

    /// Seit Wine 9/10 (neuer WoW64-Modus) heißt der Starter `wine`, ältere Builds haben `wine64`.
    public var wineBinary: URL {
        let wine = root.appending(path: "bin/wine")
        if FileManager.default.fileExists(atPath: wine.path) { return wine }
        return root.appending(path: "bin/wine64")
    }

    public var wineserverBinary: URL { root.appending(path: "bin/wineserver") }

    /// msync ist eine schnelle Synchronisierung über Mach-Ports. Geprüft wird die Engine selbst
    /// (steht `WINEMSYNC` in ihrer `ntdll.so`?), der Katalog-Eintrag ist nur die Rückfallebene.
    public var supportsMsync: Bool {
        WineLayout.ntdllContains("WINEMSYNC", root: root) ?? component.features.contains("msync")
    }
    public var supportsDXMT: Bool { component.features.contains("dxmt") }
}

extension WineLayout {
    private static let ntdllCache = StringFlagCache()

    /// Steht `needle` als Text in der `ntdll.so` der Engine? Statische Prüfung, Wine wird dafür
    /// nicht gestartet. nil, wenn die Datei fehlt.
    public static func ntdllContains(_ needle: String, root: URL) -> Bool? {
        let ntdll = root.appending(path: "lib/wine/x86_64-unix/ntdll.so")
        let key = ntdll.path + "\u{0}" + needle
        if let cached = ntdllCache.value(for: key) { return cached }
        guard let data = try? Data(contentsOf: ntdll, options: .mappedIfSafe) else { return nil }
        let found = data.range(of: Data(needle.utf8)) != nil
        ntdllCache.set(found, for: key)
        return found
    }

    /// Über welche Variable lädt die Engine Builtin-DLLs aus einem zusätzlichen Ordner vor ihren
    /// eigenen? Sikarugir nimmt `WINEDLLPATH_DXMT`, andere Builds `WINEDLLPATH_PREPEND`.
    /// nil: keine – dann baut Kelter DXMT in eine Kopie der Engine ein.
    public static func dllPathVariable(root: URL) -> String? {
        ["WINEDLLPATH_DXMT", "WINEDLLPATH_PREPEND"].first { ntdllContains($0, root: root) == true }
    }
}

private final class StringFlagCache: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Bool] = [:]

    func value(for key: String) -> Bool? { lock.withLock { values[key] } }
    func set(_ value: Bool, for key: String) { lock.withLock { values[key] = value } }
}

/// Wo in einem entpackten Archiv die Wine-Installation liegt und welche Version sie hat.
public enum WineLayout {
    public static func isWineRoot(_ url: URL) -> Bool {
        let fileManager = FileManager.default
        let bin = url.appending(path: "bin")
        return fileManager.fileExists(atPath: bin.appending(path: "wineserver").path)
            && (fileManager.fileExists(atPath: bin.appending(path: "wine").path)
                || fileManager.fileExists(atPath: bin.appending(path: "wine64").path))
    }

    /// Sucht per Breitensuche den Ordner mit `bin/wineserver`.
    ///
    /// Die Archive sind unterschiedlich aufgebaut:
    /// - WineHQ (Gcenx): `Wine Devel.app/Contents/Resources/wine/`
    /// - Sikarugir: `wswine.bundle/`
    public static func findWineRoot(in directory: URL, maxDepth: Int = 6) -> URL? {
        var queue: [(URL, Int)] = [(directory, 0)]
        let fileManager = FileManager.default
        while !queue.isEmpty {
            let (current, depth) = queue.removeFirst()
            if isWineRoot(current) { return current }
            guard depth < maxDepth else { continue }
            let children = (try? fileManager.contentsOfDirectory(
                at: current,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: .skipsHiddenFiles
            )) ?? []
            for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values?.isDirectory == true, values?.isSymbolicLink != true {
                    queue.append((child, depth + 1))
                }
            }
        }
        return nil
    }

    /// Sikarugir-Engines haben eine Datei `version`, z. B. „wine sikarugir 11.0 (revision 1)“.
    public static func versionFile(in root: URL) -> String? {
        guard let text = try? String(contentsOf: root.appending(path: "version"), encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Fragt die Engine mit `wine --version` nach ihrer Version.
    @concurrent
    public static func detectVersion(root: URL) async -> String? {
        let engine = WineEngine(
            component: InstalledComponent(id: "probe", kind: .wine, name: "probe", version: ""),
            root: root
        )
        var environment = ProcessInfo.processInfo.environment
        environment["WINEDEBUG"] = "-all"
        if let result = try? await Command.run(engine.wineBinary, ["--version"], environment: environment, timeout: .seconds(90)),
           result.succeeded,
           let line = result.output
               .split(whereSeparator: \.isNewline)
               .map({ $0.trimmingCharacters(in: .whitespaces) })
               .last(where: { $0.lowercased().hasPrefix("wine") }) {
            return line
        }
        return versionFile(in: root)
    }
}

/// Hilfsbibliotheken einer Engine im Aufbau der Sikarugir-Vorlage:
/// `Frameworks/` (dylibs), `Resources/vulkan/icd.d/` (Vulkan-Treiber), `SharedSupport/renderer/` (DXMT/DXVK).
public struct RuntimeLibraries: Sendable, Hashable {
    /// Entspricht `Template.app/Contents`.
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public var frameworks: URL { root.appending(path: "Frameworks", directoryHint: .isDirectory) }

    /// MoltenVK als Vulkan-Treiber. Die JSON verweist relativ auf `../../../Frameworks/libMVK.dylib`,
    /// deshalb muss der Ordneraufbau erhalten bleiben.
    public var moltenVKDriver: URL? {
        existing(root.appending(path: "Resources/vulkan/icd.d/MoltenVK_icd.json"))
    }

    public var gstreamerPlugins: URL? {
        existing(frameworks.appending(path: "GStreamer.framework/Versions/1.0/lib/gstreamer-1.0", directoryHint: .isDirectory))
    }

    /// Ordner mit Grafik-Builds, z. B. `renderer/dxmt/wine` (für Meilenstein 4).
    public func renderer(_ name: String) -> URL? {
        existing(root.appending(path: "SharedSupport/renderer/\(name)/wine", directoryHint: .isDirectory))
    }

    private func existing(_ url: URL) -> URL? {
        FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Sucht im entpackten Archiv den Ordner, der `Frameworks/` enthält.
    public static func findRoot(in directory: URL, maxDepth: Int = 4) -> URL? {
        var queue: [(URL, Int)] = [(directory, 0)]
        let fileManager = FileManager.default
        while !queue.isEmpty {
            let (current, depth) = queue.removeFirst()
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: current.appending(path: "Frameworks").path, isDirectory: &isDirectory), isDirectory.boolValue {
                return current
            }
            guard depth < maxDepth else { continue }
            let children = (try? fileManager.contentsOfDirectory(at: current, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)) ?? []
            for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            where (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                queue.append((child, depth + 1))
            }
        }
        return nil
    }
}

/// Hilfen für Komponenten, die keine Wine-Engines sind (DXMT, DXVK, MoltenVK).
public enum ComponentLayout {
    /// Wenn ein Archiv genau einen Ordner enthält (z. B. `dxmt/`), ist der Inhalt dieser Ordner.
    public static func singleTopLevelDirectory(in directory: URL) -> URL? {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles
        )) ?? []
        guard entries.count == 1,
              (try? entries[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        else { return nil }
        return entries[0]
    }
}
