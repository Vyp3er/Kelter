import Darwin
import Foundation

/// Ein laufender Prozess einer Kelter-Engine, so wie macOS ihn sieht.
public struct WineProcessInfo: Sendable, Hashable, Identifiable {
    public let pid: Int32
    /// Mac-Pfad des Programms (z. B. `…/Engines/<id>/files/bin/wine`).
    public let executablePath: String
    public let arguments: [String]
    /// WINEPREFIX des Prozesses, also der Bottle-Ordner.
    public let prefixPath: String?
    /// Speicher im RAM (Resident Set Size).
    public let residentBytes: UInt64
    /// Bisher verbrauchte CPU-Zeit (Nutzer + System) in Nanosekunden.
    public let cpuNanoseconds: UInt64

    public init(pid: Int32, executablePath: String, arguments: [String], prefixPath: String?, residentBytes: UInt64, cpuNanoseconds: UInt64 = 0) {
        self.pid = pid
        self.executablePath = executablePath
        self.arguments = arguments
        self.prefixPath = prefixPath
        self.residentBytes = residentBytes
        self.cpuNanoseconds = cpuNanoseconds
    }

    public var id: Int32 { pid }

    public var isWineserver: Bool {
        (executablePath as NSString).lastPathComponent == "wineserver"
    }

    /// Das Windows-Programm, z. B. `C:\Program Files (x86)\Steam\steam.exe` oder `winecfg`.
    public var windowsProgram: String? {
        guard !isWineserver else { return nil }
        let loaders: Set<String> = ["wine", "wine64", "wine-preloader", "wine64-preloader"]
        return arguments.first { argument in
            !loaders.contains((argument as NSString).lastPathComponent) && argument != executablePath
        }
    }

    public var displayName: String {
        if isWineserver { return "wineserver" }
        return windowsProgram.map(WindowsPath.fileName) ?? (executablePath as NSString).lastPathComponent
    }

    /// Wines eigene Hintergrunddienste – laufen in jeder aktiven Bottle mit.
    public var isSystemProcess: Bool {
        if isWineserver { return true }
        guard let program = windowsProgram else { return true }
        return Self.systemPrograms.contains(WindowsPath.baseName(program))
    }

    static let systemPrograms: Set<String> = [
        "services", "winedevice", "plugplay", "svchost", "rpcss", "explorer", "conhost", "start",
        "winemenubuilder", "tabtip", "wineboot", "rundll32", "mscorsvw", "taskkill", "cmd"
    ]

    /// Gehört der Prozess zu diesem Windows-Programm? Vergleicht nur den Dateinamen.
    public func matches(executable windowsPath: String) -> Bool {
        guard let program = windowsProgram else { return false }
        return WindowsPath.baseName(program) == WindowsPath.baseName(windowsPath)
    }
}

/// Findet alle Prozesse, die mit einer Kelter-Engine laufen – auch solche, die Kelter nicht
/// selbst gestartet hat (z. B. Steam, das sich nach einem Update neu startet).
///
/// Weg: alle eigenen Prozesse auflisten, nur die behalten, deren Programm unter `Engines/` liegt,
/// und aus ihrer Umgebung `WINEPREFIX` lesen (über `sysctl KERN_PROCARGS2`).
public enum WineProcessScanner {
    @concurrent
    public static func scan(enginesDirectory: URL) async -> [WineProcessInfo] {
        scanNow(enginesDirectory: enginesDirectory)
    }

    public static func scanNow(enginesDirectory: URL) -> [WineProcessInfo] {
        var enginesPrefix = enginesDirectory.standardizedFileURL.path
        if !enginesPrefix.hasSuffix("/") { enginesPrefix += "/" }

        var argumentMax: Int32 = 0
        var size = MemoryLayout<Int32>.size
        var argMaxMIB: [Int32] = [CTL_KERN, KERN_ARGMAX]
        guard sysctl(&argMaxMIB, 2, &argumentMax, &size, nil, 0) == 0, argumentMax > 0 else { return [] }

        var buffer = [UInt8](repeating: 0, count: Int(argumentMax))
        var pathBuffer = [CChar](repeating: 0, count: 4096) // PROC_PIDPATHINFO_MAXSIZE
        var result: [WineProcessInfo] = []

        for pid in allProcessIDs() where pid > 0 {
            let length = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
            guard length > 0 else { continue }
            let path = pathBuffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            guard enginesPrefix == "/" || path.hasPrefix(enginesPrefix) else { continue }

            var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
            var bufferSize = buffer.count
            let status = buffer.withUnsafeMutableBytes { raw in
                sysctl(&mib, 3, raw.baseAddress, &bufferSize, nil, 0)
            }
            guard status == 0, let parsed = parseProcessArguments(Array(buffer.prefix(bufferSize))) else { continue }

            let usage = taskUsage(of: pid)
            result.append(WineProcessInfo(
                pid: pid,
                executablePath: path,
                arguments: parsed.arguments,
                prefixPath: prefixPath(from: parsed.environment),
                residentBytes: usage.resident,
                cpuNanoseconds: usage.cpu
            ))
        }
        return result
    }

    static func allProcessIDs() -> [pid_t] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let count = pids.withUnsafeMutableBytes { raw in
            proc_listallpids(raw.baseAddress, Int32(raw.count))
        }
        guard count > 0 else { return [] }
        return Array(pids.prefix(Int(count)))
    }

    /// RAM und CPU-Zeit. Die CPU-Zeiten liefert macOS in Mach-Ticks; auf Apple Silicon
    /// sind das keine Nanosekunden, deshalb mit `mach_timebase_info` umrechnen.
    static func taskUsage(of pid: pid_t) -> (resident: UInt64, cpu: UInt64) {
        var info = proc_taskinfo()
        let expected = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, expected) == expected else { return (0, 0) }
        let ticks = info.pti_total_user &+ info.pti_total_system
        return (info.pti_resident_size, ticks &* UInt64(timebase.numer) / UInt64(max(timebase.denom, 1)))
    }

    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    /// Zerlegt den Puffer von `KERN_PROCARGS2`:
    /// `argc` (Int32) · Programmpfad · Füll-Nullbytes · argv[0…argc-1] · Umgebung · leerer Eintrag.
    static func parseProcessArguments(_ bytes: [UInt8]) -> (executable: String, arguments: [String], environment: [String: String])? {
        guard bytes.count > 4 else { return nil }
        let argc = Int(Int32(littleEndian: bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }))
        var index = 4

        func nextString() -> String? {
            guard index < bytes.count else { return nil }
            let start = index
            while index < bytes.count, bytes[index] != 0 { index += 1 }
            let string = String(decoding: bytes[start..<index], as: UTF8.self)
            index += 1
            return string
        }

        guard let executable = nextString() else { return nil }
        while index < bytes.count, bytes[index] == 0 { index += 1 }

        var arguments: [String] = []
        for _ in 0..<max(0, min(argc, 4096)) {
            guard let argument = nextString() else { break }
            arguments.append(argument)
        }

        var environment: [String: String] = [:]
        while let entry = nextString(), !entry.isEmpty {
            guard let separator = entry.firstIndex(of: "=") else { continue }
            environment[String(entry[..<separator])] = String(entry[entry.index(after: separator)...])
        }
        return (executable, arguments, environment)
    }

    /// `WINEPREFIX` oder – falls ein Windows-Programm ihn nicht weitergereicht hat –
    /// Wines `WINECONFIGDIR` (`\??\Z:\Users\…\Bottles\Test`).
    static func prefixPath(from environment: [String: String]) -> String? {
        if let prefix = environment["WINEPREFIX"], !prefix.isEmpty {
            return normalized(prefix)
        }
        if var config = environment["WINECONFIGDIR"] {
            if config.hasPrefix("\\??\\") { config.removeFirst(4) }
            guard config.count > 2, config.lowercased().hasPrefix("z:") else { return nil }
            return normalized(String(config.dropFirst(2)).replacingOccurrences(of: "\\", with: "/"))
        }
        return nil
    }

    private static func normalized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}
