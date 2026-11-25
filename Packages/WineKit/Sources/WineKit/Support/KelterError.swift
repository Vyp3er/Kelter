import Foundation

/// Fehler mit verständlichen deutschen Meldungen für die Oberfläche.
public enum KelterError: LocalizedError, Sendable, Equatable {
    case httpStatus(Int, URL?)
    case downloadFailed
    case notEnoughDiskSpace(needed: Int64, available: Int64)
    case checksumMismatch(expected: String, actual: String)
    case extractionFailed(String)
    case wineNotFoundInArchive
    case catalogMissing
    case noEngineInstalled
    case engineMissing(String)
    case engineIncomplete(name: String, missing: [String])
    case engineIncompatible(name: String, problem: String)
    case invalidBottleName
    case bottleExists(String)
    case executableMissing(String)
    case executableOutsideBottle
    case appExists(String)
    case commandFailed(command: String, status: Int32, log: String?)
    case rosettaInstallFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .httpStatus(code, url):
            let host = url?.host() ?? "dem Server"
            return "Download fehlgeschlagen: \(host) antwortet mit HTTP \(code)."
        case .downloadFailed:
            return "Download fehlgeschlagen. Prüfe deine Internetverbindung und versuche es erneut."
        case let .notEnoughDiskSpace(needed, available):
            let format = ByteCountFormatter.string(fromByteCount:countStyle:)
            return "Nicht genug Speicherplatz: benötigt etwa \(format(needed, .file)), frei sind \(format(available, .file))."
        case let .checksumMismatch(expected, actual):
            return "Die heruntergeladene Datei ist beschädigt oder wurde verändert (Prüfsumme stimmt nicht).\nErwartet: \(expected)\nErhalten: \(actual)"
        case let .extractionFailed(output):
            return "Das Archiv ließ sich nicht entpacken.\n\(output)"
        case .wineNotFoundInArchive:
            return "Im Archiv wurde keine Wine-Installation gefunden (bin/wineserver fehlt)."
        case .catalogMissing:
            return "Die mitgelieferte Liste der Download-Quellen fehlt. Bitte Kelter neu bauen."
        case .noEngineInstalled:
            return "Es ist noch keine Wine-Engine installiert. Installiere zuerst eine Engine unter „Einrichtung“."
        case let .engineMissing(id):
            return "Die Engine „\(id)“ ist nicht mehr installiert. Wähle eine andere Engine oder installiere sie neu."
        case let .engineIncomplete(name, missing):
            return "Der Engine „\(name)“ fehlen benötigte Komponenten: \(missing.joined(separator: ", ")). Lade sie unter „Engines & Komponenten“ nach."
        case let .engineIncompatible(name, problem):
            return "Die Engine „\(name)“ funktioniert auf diesem Mac nicht.\n\n\(problem)\n\nUnter „Einrichtung“ kannst du eine passende Engine laden – sie wird dann automatisch Standard."
        case .invalidBottleName:
            return "Bitte gib einen Namen ein. Er darf nicht mit einem Punkt beginnen."
        case let .bottleExists(name):
            return "Es gibt bereits eine Bottle mit dem Namen „\(name)“."
        case let .executableMissing(path):
            return "Die Programmdatei fehlt: \(path)\nWurde das Programm deinstalliert oder verschoben?"
        case .executableOutsideBottle:
            return "Die .exe muss in dieser Bottle liegen (Laufwerk C:). Eigene .exe-Dateien von anderswo kommen in einem späteren Meilenstein."
        case let .appExists(name):
            return "„\(name)“ ist in dieser Bottle schon unter „Meine Apps“ eingetragen."
        case let .commandFailed(command, status, log):
            var message = "„\(command)“ ist mit Code \(status) fehlgeschlagen."
            if let log { message += "\nDetails im Log: \(log)" }
            return message
        case let .rosettaInstallFailed(output):
            return "Rosetta 2 konnte nicht installiert werden.\n\(output)"
        }
    }
}
