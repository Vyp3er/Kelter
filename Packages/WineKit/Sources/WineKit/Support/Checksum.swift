import CryptoKit
import Foundation

public enum Checksum {
    /// SHA-256 einer Datei als Hex-String, in 4-MB-Blöcken gelesen.
    public static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Entfernt ein optionales `sha256:`-Präfix (so liefert GitHub die Werte) und normalisiert auf Kleinbuchstaben.
    public static func normalize(_ value: String) -> String {
        var value = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasPrefix("sha256:") { value.removeFirst("sha256:".count) }
        return value
    }
}
