import Foundation

/// Übersetzt Direct3D-Aufrufe von Windows-Spielen in etwas, das der Mac versteht.
public enum GraphicsBackend: String, Codable, Sendable, CaseIterable {
    /// Direct3D 10/11 → Metal. Am schnellsten für die meisten D3D11-Spiele.
    case dxmt
    /// Direct3D 9/10/11 → Vulkan → (MoltenVK) → Metal.
    case dxvk
    /// Wines eingebaute Übersetzung nach OpenGL. Langsam, aber am verträglichsten.
    case wined3d

    public var displayName: String {
        switch self {
        case .dxmt: "DXMT (Metal)"
        case .dxvk: "DXVK (Vulkan/MoltenVK)"
        case .wined3d: "WineD3D (OpenGL)"
        }
    }
}

/// Windows-Version, die Wine den Programmen meldet.
public enum WindowsVersion: String, Codable, Sendable, CaseIterable {
    case win11
    case win10
    case win81
    case win7

    public var displayName: String {
        switch self {
        case .win11: "Windows 11"
        case .win10: "Windows 10"
        case .win81: "Windows 8.1"
        case .win7: "Windows 7"
        }
    }
}

/// Wie Wine Threads synchronisiert.
public enum SyncMode: String, Codable, Sendable, CaseIterable {
    /// msync, wenn die Engine es kann, sonst Wines Standard.
    case automatic
    case msync
    /// Wines Standard (langsamer, aber manchmal stabiler).
    case off

    public var displayName: String {
        switch self {
        case .automatic: "Automatisch"
        case .msync: "msync erzwingen"
        case .off: "Aus (Wine-Standard)"
        }
    }
}

/// Wie Wine Controller an Windows-Spiele weiterreicht.
///
/// Wine nutzt auf dem Mac standardmäßig SDL. SDL kann Controller über HIDAPI (direkt) oder über
/// Apples GameController-Dienst (MFi) ansprechen. Ohne SDL greift Wine selbst per IOHID zu.
public enum ControllerMode: String, Codable, Sendable, CaseIterable {
    /// Wines Standard: SDL mit Xbox-Zuordnung.
    case automatic
    /// SDL nutzt nur Apples GameController-Dienst – genau das, was der Controller-Tab in Kelter zeigt.
    case macOSService
    /// SDL aus, Wine liest die Controller selbst (IOHID).
    case directHID
    /// SDL ohne Umbau auf Xbox-Layout (für Spiele, die PlayStation-Controller selbst erkennen).
    case rawButtons

    public var displayName: String {
        switch self {
        case .automatic: "Automatisch (SDL)"
        case .macOSService: "Über den macOS-Controllerdienst"
        case .directHID: "Direkt (IOHID, ohne SDL)"
        case .rawButtons: "Ohne Xbox-Zuordnung"
        }
    }

    public var explanation: String {
        switch self {
        case .automatic: "Wines Standard. Funktioniert mit den meisten Xbox- und PlayStation-Controllern."
        case .macOSService: "Empfohlen, wenn ein Controller in Kelters Controller-Tab erscheint, im Spiel aber nicht oder doppelt. Setzt SDL_JOYSTICK_HIDAPI=0 und SDL_JOYSTICK_MFI=1."
        case .directHID: "Für ältere oder ungewöhnliche Controller, die SDL nicht kennt. Setzt „Enable SDL“ = 0 im WineBus."
        case .rawButtons: "Für Spiele mit eigener PlayStation-Unterstützung. Setzt „Map Controllers“ = 0 im WineBus."
        }
    }
}

/// Einstellungen einer Bottle, gespeichert als `Bottles/<Name>/kelter-bottle.json`.
///
/// Fehlende Felder bekommen beim Lesen ihren Standardwert. So bleiben alte Dateien lesbar,
/// wenn spätere Versionen neue Einstellungen hinzufügen.
public struct BottleSettings: Codable, Sendable, Hashable {
    public var schemaVersion: Int = 1
    public var name: String
    /// nil = die Standard-Engine aus den App-Einstellungen.
    public var engineID: String?
    public var graphicsBackend: GraphicsBackend = .dxmt
    /// Ausnahmen pro Programm, z. B. `steamwebhelper.exe` → DXVK (Chromium-Fenster bleiben unter DXMT schwarz).
    public var executableBackends: [String: GraphicsBackend] = [:]
    public var windowsVersion: WindowsVersion = .win10
    public var syncMode: SyncMode = .automatic
    public var controllerMode: ControllerMode = .automatic
    /// Controller-Eingaben auch annehmen, wenn das Spielfenster nicht vorne ist.
    public var controllerBackgroundInput: Bool = false
    /// WINEDEBUG-Kanäle. `fixme-all` blendet die vielen „noch nicht implementiert“-Hinweise aus, Fehler bleiben sichtbar.
    public var wineDebug: String = "fixme-all"
    /// Zusätzliche Umgebungsvariablen (gewinnen gegen Kelters Vorgaben). `WINEDLLOVERRIDES` wird zusammengeführt.
    public var environment: [String: String] = [:]
    /// Wird jedem Programmstart in dieser Bottle angehängt.
    public var launchArguments: [String] = []
    /// Katalog-Rezept, aus dem die Bottle angelegt wurde.
    public var recipeID: String?
    public var createdAt: Date = .now
    /// Programme, für die Kelter Einträge unter `AppDefaults` geschrieben hat (zum Aufräumen).
    public var managedExecutables: [String] = []
    /// Kennung der zuletzt angewendeten Grafik-/Controller-Einstellungen. Ändert sie sich,
    /// schreibt Kelter Registry und DLLs vor dem nächsten Start neu.
    public var appliedStateMarker: String?

    public init(name: String, engineID: String? = nil) {
        self.name = name
        self.engineID = engineID
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, name, engineID, graphicsBackend, executableBackends, windowsVersion, syncMode
        case controllerMode, controllerBackgroundInput, wineDebug, environment, launchArguments, recipeID
        case createdAt, managedExecutables, appliedStateMarker
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = BottleSettings(name: "")
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? defaults.schemaVersion
        name = try container.decode(String.self, forKey: .name)
        engineID = try container.decodeIfPresent(String.self, forKey: .engineID)
        graphicsBackend = try container.decodeIfPresent(GraphicsBackend.self, forKey: .graphicsBackend) ?? defaults.graphicsBackend
        executableBackends = try container.decodeIfPresent([String: GraphicsBackend].self, forKey: .executableBackends) ?? [:]
        windowsVersion = try container.decodeIfPresent(WindowsVersion.self, forKey: .windowsVersion) ?? defaults.windowsVersion
        syncMode = try container.decodeIfPresent(SyncMode.self, forKey: .syncMode) ?? defaults.syncMode
        controllerMode = try container.decodeIfPresent(ControllerMode.self, forKey: .controllerMode) ?? defaults.controllerMode
        controllerBackgroundInput = try container.decodeIfPresent(Bool.self, forKey: .controllerBackgroundInput) ?? false
        wineDebug = try container.decodeIfPresent(String.self, forKey: .wineDebug) ?? defaults.wineDebug
        environment = try container.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
        launchArguments = try container.decodeIfPresent([String].self, forKey: .launchArguments) ?? []
        recipeID = try container.decodeIfPresent(String.self, forKey: .recipeID)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? defaults.createdAt
        managedExecutables = try container.decodeIfPresent([String].self, forKey: .managedExecutables) ?? []
        appliedStateMarker = try container.decodeIfPresent(String.self, forKey: .appliedStateMarker)
    }

    /// Nur die Felder, die der Nutzer einstellt (ohne Kelters interne Buchführung) – für „geändert?“-Vergleiche.
    public var userFacing: BottleSettings {
        var copy = self
        copy.managedExecutables = []
        copy.appliedStateMarker = nil
        return copy
    }
}
