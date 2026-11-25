import Darwin
import Foundation

/// Rosetta 2 übersetzt x86_64-Programme für Apple Silicon. Wine für macOS ist (noch)
/// ein x86_64-Programm und läuft deshalb nur mit Rosetta.
public enum Rosetta {
    /// Die Datei legt macOS bei der Rosetta-Installation an.
    static let runtimePath = "/Library/Apple/usr/libexec/oah/libRosettaRuntime"

    /// `true` auf Apple-Silicon-Macs (auch wenn Kelter selbst unter Rosetta liefe).
    public static var isAppleSilicon: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
    }

    /// Prüft, ob Rosetta installiert ist und x86_64-Programme tatsächlich starten.
    @concurrent
    public static func isInstalled() async -> Bool {
        guard FileManager.default.fileExists(atPath: runtimePath) else { return false }
        // Gegenprobe: ein x86_64-Programm starten. /usr/bin/true ist ein Universal-Binary.
        let result = try? await Command.run(URL(fileURLWithPath: "/usr/bin/arch"), ["-x86_64", "/usr/bin/true"], timeout: .seconds(20))
        return result?.succeeded ?? false
    }

    /// Installiert Rosetta mit `softwareupdate --install-rosetta --agree-to-license`.
    ///
    /// Der Aufruf stimmt Apples Rosetta-Lizenz zu. Die Oberfläche muss vorher nachfragen.
    @concurrent
    public static func install() async throws {
        let result = try await Command.run(
            URL(fileURLWithPath: "/usr/sbin/softwareupdate"),
            ["--install-rosetta", "--agree-to-license"]
        )
        guard result.succeeded else { throw KelterError.rosettaInstallFailed(result.output) }
    }

    /// Wie ``install()``, aber über den macOS-Passwortdialog mit Administratorrechten
    /// (falls `softwareupdate` ohne Adminrechte abbricht).
    @concurrent
    public static func installWithAdministratorPrivileges() async throws {
        let script = "do shell script \"/usr/sbin/softwareupdate --install-rosetta --agree-to-license\" with administrator privileges"
        let result = try await Command.run(URL(fileURLWithPath: "/usr/bin/osascript"), ["-e", script])
        guard result.succeeded else { throw KelterError.rosettaInstallFailed(result.output) }
    }
}
