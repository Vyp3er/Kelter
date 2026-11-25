import Foundation

/// Verlauf der Logdateien in `Logs/`.
public enum LogStore {
    /// Logs eines Programms, neueste zuerst. `label` wie beim Start (z. B. App-Name).
    public static func logs(in directory: URL, label: String) -> [URL] {
        let prefix = LogFile.sanitize(label) + "-"
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        )) ?? []
        return entries
            .filter { url in
                let name = url.lastPathComponent
                // Nach dem Präfix muss das Datum kommen, sonst passt „Steam“ auch auf „Steam-Beta-…“.
                guard url.pathExtension == "log", name.hasPrefix(prefix) else { return false }
                return name.dropFirst(prefix.count).first?.isNumber == true
            }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// Behält pro Programm nur die neuesten `keep` Logs.
    public static func prune(in directory: URL, label: String, keep: Int = 20) {
        for url in logs(in: directory, label: label).dropFirst(keep) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

/// Ein Hinweis aus einem Log, den die Oberfläche hervorhebt.
public struct LogFinding: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        case antiCheat
        case missingLibrary
        case crash
        case setup
    }

    public let kind: Kind
    public let title: String
    public let detail: String
    public var id: String { title }
}

/// Sucht in Wine-Logs nach typischen Problemen und erklärt sie verständlich.
public enum LogAnalyzer {
    /// Bekannte Anti-Cheat-Systeme und woran man sie im Log erkennt.
    static let antiCheatSignatures: [(name: String, needles: [String])] = [
        ("Easy Anti-Cheat", ["easyanticheat", "eac_launcher", "eac.exe"]),
        ("BattlEye", ["battleye", "beservice", "beclient"]),
        // Nur eindeutige Treiber-/Dateinamen, damit Spielnamen in Steam-Logs keinen Fehlalarm auslösen.
        ("Riot Vanguard", ["vgk.sys", "vgc.exe", "riot vanguard"]),
        ("EA Javelin Anti-Cheat", ["eaanticheat", "javelin anticheat"]),
        ("PunkBuster", ["punkbuster", "pnkbstr"]),
        ("nProtect GameGuard", ["gameguard.des", "npggnt"]),
        ("XIGNCODE", ["xigncode"]),
        ("FACEIT", ["faceit.sys", "faceitclient"]),
        ("Ricochet", ["randgrid.sys", "ricochet anti-cheat"]),
        ("mhyprot", ["mhyprot"])
    ]

    public static func analyze(_ text: String) -> [LogFinding] {
        var findings: [LogFinding] = []
        let lower = text.lowercased()

        for signature in antiCheatSignatures where signature.needles.contains(where: lower.contains) {
            findings.append(LogFinding(
                kind: .antiCheat,
                title: "Anti-Cheat erkannt: \(signature.name)",
                detail: "Dieses Programm nutzt \(signature.name). Das läuft unter Wine auf dem Mac meist nicht – Online-Modi bleiben gesperrt oder das Spiel beendet sich. Kelter umgeht keinen Anti-Cheat."
            ))
        }

        for line in text.split(whereSeparator: \.isNewline) where line.contains("import_dll") && line.contains("not found") {
            // err:module:import_dll Library MSVCP140.dll (which is needed by L"C:\\…\\game.exe") not found
            let parts = line.split(separator: " ")
            if let index = parts.firstIndex(of: "Library"), index + 1 < parts.count {
                let library = String(parts[index + 1])
                findings.append(LogFinding(
                    kind: .missingLibrary,
                    title: "Fehlende DLL: \(library)",
                    detail: "Dem Programm fehlt eine Windows-Bibliothek. Oft ist das eine Laufzeitkomponente wie die Visual-C++-Runtime – ab Meilenstein 3 installiert der Katalog solche Komponenten mit."
                ))
            }
        }

        if lower.contains("failed to start wineboot") {
            findings.append(LogFinding(kind: .setup, title: "Wine kann keine Windows-Programme starten",
                detail: "Jeder neue Windows-Prozess bricht sofort ab, deshalb lässt sich nicht einmal die Bottle einrichten. Das liegt fast immer an der Engine: Sie passt nicht zu dieser macOS-Version. Wähle unter „Engines“ eine andere Engine (empfohlen: Wine 10.0 Sikarugir) und richte die Bottle danach neu ein."))
        }
        if lower.contains("cannot find the freetype font library") {
            findings.append(LogFinding(kind: .setup, title: "Schriftbibliothek fehlt",
                detail: "Wine findet FreeType nicht – Texte werden nicht angezeigt. Prüfe unter „Engines & Komponenten“, ob die Bibliotheken der Engine installiert sind."))
        }
        if lower.contains("libgnutls") && (lower.contains("failed to load") || lower.contains("not found")) {
            findings.append(LogFinding(kind: .setup, title: "GnuTLS fehlt",
                detail: "Ohne GnuTLS gibt es keine verschlüsselten Verbindungen (Logins, Downloads). Prüfe die Bibliotheken der Engine."))
        }
        if lower.contains("unhandled page fault") || lower.contains("unhandled exception") {
            let line = text.split(whereSeparator: \.isNewline).first { $0.lowercased().contains("unhandled") }.map(String.init) ?? ""
            findings.append(LogFinding(kind: .crash, title: "Programm abgestürzt",
                detail: "Wine meldet einen Absturz: \(line.trimmingCharacters(in: .whitespaces))"))
        }

        var seen: Set<String> = []
        return findings.filter { seen.insert($0.title).inserted }.prefix(10).map { $0 }
    }
}
