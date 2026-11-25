import Foundation

/// Wo die Grafik-Übersetzer liegen.
public struct GraphicsSources: Sendable, Equatable {
    /// Ordner mit `x86_64-windows/` und `x86_64-unix/winemetal.so` (DXMT, als Wine-Builtin gebaut).
    public var dxmt: URL?
    public var dxmtVersion: String?
    /// Ordner mit `x64/` und `x32/` (DXVK als normale Windows-DLLs).
    public var dxvk: URL?
    public var dxvkVersion: String?

    public init(dxmt: URL? = nil, dxmtVersion: String? = nil, dxvk: URL? = nil, dxvkVersion: String? = nil) {
        self.dxmt = dxmt
        self.dxmtVersion = dxmtVersion
        self.dxvk = dxvk
        self.dxvkVersion = dxvkVersion
    }
}

/// Alles, was vor einem Start in einer Bottle gesetzt sein muss: Grafik-Backend, Ausnahmen
/// pro Programm und Controller-Einstellungen.
public struct LaunchPlan: Sendable, Equatable {
    public enum Method: String, Sendable {
        /// Wines eingebautes WineD3D.
        case wined3d
        /// DXMT über einen zusätzlichen DLL-Suchpfad (`WINEDLLPATH_DXMT` bei Sikarugir).
        case dxmtDLLPath
        /// DXMT in eine APFS-Klonkopie der Engine eingebaut (Engines ohne zusätzlichen Suchpfad).
        case dxmtEngineCopy
        /// DXVK als native DLLs in `system32`.
        case dxvkNative
    }

    public var backend: GraphicsBackend
    public var method: Method
    public var dxmtSource: URL?
    /// DXVK-DLLs, die in die Bottle kopiert werden müssen.
    public var dxvkSource: URL?
    public var registry: [RegistryEdit]
    public var environment: [String: String]
    public var notes: [String]
    public var managedExecutables: [String]
    /// Ändert sich die Kennung, wendet Kelter Registry und DLLs neu an.
    public var marker: String

    public var summary: String {
        switch method {
        case .wined3d: "WineD3D (OpenGL)"
        case .dxmtDLLPath: "DXMT (Metal) über \(environment.keys.sorted().first { $0.hasPrefix("WINEDLLPATH") } ?? "DLL-Suchpfad")"
        case .dxmtEngineCopy: "DXMT (Metal) in Engine-Kopie"
        case .dxvkNative: "DXVK (Vulkan → MoltenVK → Metal)"
        }
    }
}

public enum LaunchPlanner {
    /// Die DLLs, um die sich die Grafik-Backends streiten.
    public static let direct3DLibraries = ["d3d9", "d3d10", "d3d10_1", "d3d10core", "d3d11", "dxgi"]

    public static func plan(
        settings: BottleSettings,
        engine: WineEngine,
        sources: GraphicsSources,
        dllPathVariable: String?
    ) -> LaunchPlan {
        var notes: [String] = []
        var backend = settings.graphicsBackend

        if backend == .dxmt {
            if !engine.supportsDXMT {
                notes.append("Die Engine „\(engine.name)“ unterstützt kein DXMT – es läuft WineD3D.")
                backend = .wined3d
            } else if sources.dxmt == nil {
                notes.append("DXMT-Dateien nicht gefunden (Laufzeit-Bibliotheken der Engine installiert?) – es läuft WineD3D.")
                backend = .wined3d
            }
        }
        if backend == .dxvk, sources.dxvk == nil {
            notes.append("DXVK ist nicht installiert (Engines & Komponenten) – es läuft WineD3D.")
            backend = .wined3d
        }

        let dxvkLibraries = sources.dxvk.map { GraphicsLayout.dllNames(in: $0.appending(path: "x64")) } ?? []
        var registry: [RegistryEdit] = []

        // Bottle-weite Reihenfolge: DXVK nativ, sonst Wines Builtins (WineD3D bzw. DXMT).
        for library in direct3DLibraries {
            let value = backend == .dxvk && dxvkLibraries.contains(library) ? "native,builtin" : "builtin"
            registry.append(.setString(key: RegistryKeys.dllOverrides, name: library, value: value))
        }

        // Ausnahmen pro Programm. In einer DXMT/WineD3D-Bottle geht nur „DXVK“ (nativ),
        // in einer DXVK-Bottle nur „WineD3D“ (Builtin) – mehr lässt Wines Ladereihenfolge nicht zu.
        var managed: [String] = []
        var usesDXVK = backend == .dxvk
        for (executable, wanted) in settings.executableBackends.sorted(by: { $0.key.lowercased() < $1.key.lowercased() }) {
            let key = RegistryKeys.appDefaultsOverrides(for: executable)
            let value: String?
            switch (backend, wanted) {
            case (.dxvk, .wined3d):
                value = "builtin"
            case (.dxmt, .dxvk), (.wined3d, .dxvk):
                value = sources.dxvk == nil ? nil : "native"
                if sources.dxvk == nil { notes.append("Ausnahme „\(executable)“ → DXVK übersprungen: DXVK ist nicht installiert.") }
            case _ where wanted == backend:
                value = nil
            default:
                value = nil
                notes.append("Ausnahme „\(executable)“ → \(wanted.displayName) ist in einer \(backend.displayName)-Bottle nicht möglich.")
            }
            guard let value else { continue }
            registry.append(.deleteKey(key))
            let libraries = value == "native" ? dxvkLibraries : direct3DLibraries
            for library in libraries {
                registry.append(.setString(key: key, name: library, value: value))
            }
            if value == "native" { usesDXVK = true }
            managed.append(executable)
        }
        // Frühere Ausnahmen, die es nicht mehr gibt, wieder entfernen.
        let current = Set(managed.map { $0.lowercased() })
        for old in settings.managedExecutables where !current.contains(old.lowercased()) {
            registry.append(.deleteKey(RegistryKeys.appDefaultsOverrides(for: old)))
        }

        // Controller (WineBus)
        registry.append(.setDWord(key: RegistryKeys.wineBus, name: "Enable SDL", value: settings.controllerMode == .directHID ? 0 : 1))
        registry.append(.setDWord(key: RegistryKeys.wineBus, name: "Map Controllers", value: settings.controllerMode == .rawButtons ? 0 : 1))

        var environment: [String: String] = [:]
        if settings.controllerMode == .macOSService {
            environment["SDL_JOYSTICK_HIDAPI"] = "0"
            environment["SDL_JOYSTICK_MFI"] = "1"
        }
        if settings.controllerBackgroundInput {
            environment["SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS"] = "1"
        }

        let method: LaunchPlan.Method
        var dxmtSource: URL?
        switch backend {
        case .dxmt:
            dxmtSource = sources.dxmt
            if let variable = dllPathVariable, let dxmt = sources.dxmt {
                method = .dxmtDLLPath
                environment[variable] = dxmt.path
            } else {
                method = .dxmtEngineCopy
            }
        case .dxvk:
            method = .dxvkNative
        case .wined3d:
            method = .wined3d
        }
        if usesDXVK {
            // Die macOS-Builds von DXVK sind „async“: Shader werden im Hintergrund übersetzt.
            environment["DXVK_ASYNC"] = "1"
        }

        let marker = [
            "v1", backend.rawValue, method.rawValue,
            dxmtSource?.path ?? "-", usesDXVK ? (sources.dxvk?.path ?? "-") : "-",
            settings.executableBackends.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.rawValue)" }.joined(separator: ","),
            settings.managedExecutables.sorted().joined(separator: ","),
            settings.controllerMode.rawValue
        ].joined(separator: "|")

        return LaunchPlan(
            backend: backend,
            method: method,
            dxmtSource: dxmtSource,
            dxvkSource: usesDXVK ? sources.dxvk : nil,
            registry: registry,
            environment: environment,
            notes: notes,
            managedExecutables: managed,
            marker: marker
        )
    }
}

/// Sucht Grafik-Dateien in entpackten Komponenten.
public enum GraphicsLayout {
    /// Ordner mit `x86_64-windows/d3d11.dll` und `x86_64-unix/winemetal.so`.
    public static func findDXMT(in directory: URL) -> URL? {
        breadthFirst(from: directory, maxDepth: 4) { candidate in
            exists(candidate, "x86_64-windows/d3d11.dll") && exists(candidate, "x86_64-unix/winemetal.so")
        }
    }

    /// Ordner mit `x64/d3d11.dll` (DXVK als normale Windows-DLLs).
    public static func findDXVK(in directory: URL) -> URL? {
        breadthFirst(from: directory, maxDepth: 4) { exists($0, "x64/d3d11.dll") }
    }

    /// `d3d11.dll` → `d3d11`, klein geschrieben und sortiert.
    public static func dllNames(in directory: URL) -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return files
            .filter { $0.lowercased().hasSuffix(".dll") }
            .map { String($0.dropLast(4)).lowercased() }
            .sorted()
    }

    /// Versionsangabe aus einer Datei `version` im Ordner oder eine Ebene darüber.
    public static func version(near directory: URL) -> String? {
        for folder in [directory, directory.deletingLastPathComponent()] {
            if let text = try? String(contentsOf: folder.appending(path: "version"), encoding: .utf8) {
                let line = text.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces)
                if let line, !line.isEmpty { return line }
            }
        }
        return nil
    }

    private static func exists(_ base: URL, _ relative: String) -> Bool {
        FileManager.default.fileExists(atPath: base.appending(path: relative).path)
    }

    private static func breadthFirst(from directory: URL, maxDepth: Int, where matches: (URL) -> Bool) -> URL? {
        var queue: [(URL, Int)] = [(directory, 0)]
        while !queue.isEmpty {
            let (current, depth) = queue.removeFirst()
            if matches(current) { return current }
            guard depth < maxDepth else { continue }
            let children = (try? FileManager.default.contentsOfDirectory(at: current, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)) ?? []
            for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            where (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                queue.append((child, depth + 1))
            }
        }
        return nil
    }
}

extension ComponentStore {
    /// DXMT bevorzugt aus den Laufzeit-Bibliotheken der Engine (passend gebaut), sonst aus einer
    /// eigenen DXMT-Komponente. DXVK aus der DXVK-Komponente (native DLLs).
    public func graphicsSources(for engine: WineEngine) -> GraphicsSources {
        var sources = GraphicsSources()
        let all = installed()
        if let renderer = engine.runtime?.renderer("dxmt"), let dxmt = GraphicsLayout.findDXMT(in: renderer) {
            sources.dxmt = dxmt
            sources.dxmtVersion = GraphicsLayout.version(near: renderer)
        } else {
            for component in all where component.kind == .dxmt {
                if let dxmt = GraphicsLayout.findDXMT(in: filesDirectory(for: component.id)) {
                    sources.dxmt = dxmt
                    sources.dxmtVersion = component.version
                    break
                }
            }
        }
        for component in all where component.kind == .dxvk {
            if let dxvk = GraphicsLayout.findDXVK(in: filesDirectory(for: component.id)) {
                sources.dxvk = dxvk
                sources.dxvkVersion = component.version
                break
            }
        }
        return sources
    }
}
