import Foundation

/// Ergebnis der Start-Vorbereitung.
public struct PreparedLaunch: Sendable {
    /// Wine mit der passenden Engine (ggf. DXMT-Engine-Kopie).
    public let wine: Wine
    public let plan: LaunchPlan
    /// Gesetzt, wenn Kelter Registry/DLLs neu angewendet hat – der Aufrufer speichert das.
    public let updatedSettings: BottleSettings?
}

extension Wine {
    /// Plant Grafik/Controller, wendet Änderungen an der Bottle an und liefert die Engine für den Start.
    public func prepare(_ bottle: Bottle, sources: GraphicsSources) async throws -> PreparedLaunch {
        let dllPathVariable = WineLayout.dllPathVariable(root: engine.root)
        let plan = LaunchPlanner.plan(settings: bottle.settings, engine: engine, sources: sources, dllPathVariable: dllPathVariable)
        var target = self
        if plan.method == .dxmtEngineCopy, let source = plan.dxmtSource {
            target = try await engineVariant(withDXMT: source)
        }
        var updated: BottleSettings?
        if bottle.isInitialized, bottle.settings.appliedStateMarker != plan.marker {
            try await target.apply(plan, to: bottle)
            var settings = bottle.settings
            settings.managedExecutables = plan.managedExecutables
            // Die Kennung hängt auch von managedExecutables ab – nach dem Aktualisieren neu berechnen.
            settings.appliedStateMarker = LaunchPlanner.plan(
                settings: settings, engine: engine, sources: sources, dllPathVariable: dllPathVariable
            ).marker
            updated = settings
        }
        return PreparedLaunch(wine: target, plan: plan, updatedSettings: updated)
    }

    /// Kopiert DLLs in die Bottle und importiert die Registry-Einträge.
    public func apply(_ plan: LaunchPlan, to bottle: Bottle) async throws {
        let windows = bottle.driveC.appending(path: "windows", directoryHint: .isDirectory)
        let system32 = windows.appending(path: "system32", directoryHint: .isDirectory)
        let syswow64 = windows.appending(path: "syswow64", directoryHint: .isDirectory)

        if let dxvk = plan.dxvkSource {
            try Self.copyDLLs(from: dxvk.appending(path: "x64"), to: system32)
            try Self.copyDLLs(from: dxvk.appending(path: "x32"), to: syswow64)
        }
        if let dxmt = plan.dxmtSource {
            // DXMT verlangt winemetal.dll zusätzlich im system32 der Bottle.
            try Self.copyDLLs(from: dxmt.appending(path: "x86_64-windows"), to: system32, only: ["winemetal.dll"])
            try Self.copyDLLs(from: dxmt.appending(path: "i386-windows"), to: syswow64, only: ["winemetal.dll"])
        }
        try await applyRegistry(plan.registry, in: bottle)
    }

    /// APFS-Klon der Engine mit eingebautem DXMT. Kostet dank Copy-on-Write kaum Speicher.
    public func engineVariant(withDXMT source: URL) async throws -> Wine {
        let fileManager = FileManager.default
        let tag = String(source.path.hashValueStable, radix: 16)
        let variant = engine.root.deletingLastPathComponent()
            .appending(path: "Varianten/dxmt-\(tag)", directoryHint: .isDirectory)
        let ready = variant.appending(path: ".kelter-fertig")

        if !fileManager.fileExists(atPath: ready.path) {
            try? fileManager.removeItem(at: variant)
            try fileManager.createDirectory(at: variant.deletingLastPathComponent(), withIntermediateDirectories: true)
            let copy = try await Command.run(URL(fileURLWithPath: "/bin/cp"), ["-cR", engine.root.path, variant.path])
            guard copy.succeeded else {
                throw KelterError.commandFailed(command: "cp -cR (Engine-Kopie)", status: copy.status, log: nil)
            }
            for folder in ["x86_64-unix", "x86_64-windows", "i386-windows"] {
                try Self.copyDLLs(
                    from: source.appending(path: folder),
                    to: variant.appending(path: "lib/wine/\(folder)"),
                    extensions: ["dll", "so"]
                )
            }
            fileManager.createFile(atPath: ready.path, contents: Data(source.path.utf8))
        }
        let variantEngine = WineEngine(
            component: engine.component,
            root: variant,
            runtime: engine.runtime,
            missingRequirements: engine.missingRequirements
        )
        return Wine(engine: variantEngine, paths: paths)
    }

    static func copyDLLs(from source: URL, to destination: URL, only names: Set<String>? = nil, extensions: Set<String> = ["dll"]) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: source.path) else { return }
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        for name in try fileManager.contentsOfDirectory(atPath: source.path) {
            guard extensions.contains((name as NSString).pathExtension.lowercased()) else { continue }
            if let names, !names.contains(name.lowercased()) { continue }
            let target = destination.appending(path: name)
            if fileManager.fileExists(atPath: target.path) || (try? fileManager.destinationOfSymbolicLink(atPath: target.path)) != nil {
                try fileManager.removeItem(at: target)
            }
            try fileManager.copyItem(at: source.appending(path: name), to: target)
        }
    }
}

extension String {
    /// Stabiler Hash (FNV-1a) – `hashValue` ändert sich bei jedem Programmstart.
    var hashValueStable: UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }
}
