import Foundation

/// Baut die Umgebungsvariablen für einen Wine-Prozess.
///
/// Reihenfolge (spätere gewinnen): geerbte Umgebung → Kelters Vorgaben → Vorgaben des
/// Programms (z. B. Steam-Rezept) → Einstellungen der Bottle.
/// `WINEDLLOVERRIDES` wird dabei nicht ersetzt, sondern Eintrag für Eintrag zusammengeführt.
public enum WineEnvironment {
    /// Variablen, die aus der Shell des Nutzers nicht durchsickern dürfen.
    static let controlledKeys = [
        "WINEPREFIX", "WINEDEBUG", "WINEDLLOVERRIDES", "WINEMSYNC", "WINEESYNC",
        "WINEARCH", "WINELOADER", "WINESERVER", "WINEDLLPATH", "WINEDLLPATH_PREPEND",
        "WINEDLLPATH_DXMT", "WINEDLLPATH_DXVK", "WINEDLLPATH_D9VK", "WINEDLLPATH_CNCD", "WINEDLLPATH_D3DMETAL",
        "DYLD_FALLBACK_LIBRARY_PATH", "DYLD_LIBRARY_PATH", "VK_DRIVER_FILES", "VK_ICD_FILENAMES", "GST_PLUGIN_PATH"
    ]

    /// `winemenubuilder` würde Linux-Menüeinträge und Dateizuordnungen unter ~/.local anlegen.
    public static let defaultDLLOverrides: [String: String] = ["winemenubuilder.exe": "d"]

    public static func build(
        base: [String: String],
        prefix: URL,
        engine: WineEngine,
        settings: BottleSettings,
        extra: [String: String] = [:]
    ) -> [String: String] {
        var environment = base
        for key in controlledKeys { environment.removeValue(forKey: key) }

        environment["WINEPREFIX"] = prefix.path
        environment["WINEDEBUG"] = settings.wineDebug.isEmpty ? "-all" : settings.wineDebug

        switch settings.syncMode {
        case .automatic where engine.supportsMsync, .msync:
            environment["WINEMSYNC"] = "1"
        case .automatic, .off:
            break
        }

        // Engines ohne eigene Bibliotheken (Sikarugir) finden FreeType, GnuTLS, SDL usw. über
        // DYLD_FALLBACK_LIBRARY_PATH – so macht es auch der Sikarugir-Starter.
        if let runtime = engine.runtime {
            environment["DYLD_FALLBACK_LIBRARY_PATH"] = [runtime.frameworks.path, "/usr/local/lib", "/usr/lib"].joined(separator: ":")
            if let driver = runtime.moltenVKDriver { environment["VK_DRIVER_FILES"] = driver.path }
            if let plugins = runtime.gstreamerPlugins { environment["GST_PLUGIN_PATH"] = plugins.path }
            environment["MVK_CONFIG_RESUME_LOST_DEVICE"] = "1"
        }

        // Grafik-Backend: Bis Meilenstein 4 läuft alles über Wines eingebautes WineD3D,
        // deshalb setzen wir hier noch keine Overrides für DXMT/DXVK.
        var overrides = defaultDLLOverrides

        var extra = extra
        if let value = extra.removeValue(forKey: "WINEDLLOVERRIDES") {
            overrides.merge(parseDLLOverrides(value)) { $1 }
        }
        var user = settings.environment
        if let value = user.removeValue(forKey: "WINEDLLOVERRIDES") {
            overrides.merge(parseDLLOverrides(value)) { $1 }
        }

        environment.merge(extra) { $1 }
        environment.merge(user) { $1 }
        environment["WINEDLLOVERRIDES"] = formatDLLOverrides(overrides)
        return environment
    }

    /// Liest `dxgi,d3d11=n,b;winemenubuilder.exe=d` als `[dxgi: "n,b", d3d11: "n,b", winemenubuilder.exe: "d"]`.
    public static func parseDLLOverrides(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for entry in text.split(separator: ";") {
            let parts = entry.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let names = parts[0].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            let value = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
            for name in names where !name.isEmpty {
                result[name] = value
            }
        }
        return result
    }

    /// Schreibt die Overrides sortiert zurück, z. B. `d3d11=n,b;dxgi=n,b;winemenubuilder.exe=d`.
    public static func formatDLLOverrides(_ overrides: [String: String]) -> String {
        overrides
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ";")
    }

    /// Variablen, die ins Log geschrieben werden (keine vollständige Umgebung mit evtl. privaten Werten).
    public static func loggableKeys(of environment: [String: String]) -> [(String, String)] {
        let prefixes = ["WINE", "DXVK", "DXMT", "MTL_", "MVK_", "STEAM_", "CEF_", "SDL_", "DYLD_", "VK_", "GST_"]
        return environment
            .filter { key, _ in prefixes.contains { key.hasPrefix($0) } || key == "LANG" || key == "LC_ALL" }
            .sorted { $0.key < $1.key }
    }
}
