import Foundation
import Testing
@testable import WineKit

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "KelterTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Eine Bottle mit `dosdevices/c:` → `../drive_c` und `z:` → `/`, wie Wine sie anlegt.
private func makeFakePrefix() throws -> URL {
    let prefix = try temporaryDirectory().appending(path: "Bottles/Test", directoryHint: .isDirectory)
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: prefix.appending(path: "drive_c/windows/system32"), withIntermediateDirectories: true)
    try fileManager.createDirectory(at: prefix.appending(path: "dosdevices"), withIntermediateDirectories: true)
    try fileManager.createSymbolicLink(atPath: prefix.appending(path: "dosdevices/c:").path, withDestinationPath: "../drive_c")
    try fileManager.createSymbolicLink(atPath: prefix.appending(path: "dosdevices/z:").path, withDestinationPath: "/")
    return prefix
}

extension Data {
    fileprivate mutating func put16(_ offset: Int, _ value: UInt16) {
        self[offset] = UInt8(value & 0xFF)
        self[offset + 1] = UInt8(value >> 8)
    }

    fileprivate mutating func put32(_ offset: Int, _ value: UInt32) {
        for byte in 0..<4 { self[offset + byte] = UInt8((value >> (8 * UInt32(byte))) & 0xFF) }
    }
}

/// Baut eine minimale 64-Bit-EXE mit einem Icon (eine Größe, Bilddaten = `payload`).
private func makeExecutable(iconPayload payload: Data) -> Data {
    // Ressourcen-Baum (Offsets relativ zum Abschnitt .rsrc, der bei RVA 0x1000 liegt)
    let rva: UInt32 = 0x1000
    var resources = Data(count: 160)
    func directory(_ offset: Int, ids: Int) { resources.put16(offset + 14, UInt16(ids)) }
    directory(0, ids: 2)
    resources.put32(16, 3); resources.put32(20, 0x8000_0000 | 32)    // RT_ICON → 32
    resources.put32(24, 14); resources.put32(28, 0x8000_0000 | 56)   // RT_GROUP_ICON → 56
    directory(32, ids: 1); resources.put32(48, 1); resources.put32(52, 0x8000_0000 | 80)
    directory(56, ids: 1); resources.put32(72, 1); resources.put32(76, 0x8000_0000 | 104)
    directory(80, ids: 1); resources.put32(96, 0x409); resources.put32(100, 128)   // Sprache → Daten
    directory(104, ids: 1); resources.put32(120, 0x409); resources.put32(124, 144)
    let imageOffset = 160
    let groupOffset = imageOffset + payload.count
    resources.put32(128, rva + UInt32(imageOffset)); resources.put32(132, UInt32(payload.count))
    resources.put32(144, rva + UInt32(groupOffset)); resources.put32(148, 20)
    resources.append(payload)
    var group = Data(count: 20)
    group.put16(2, 1); group.put16(4, 1)
    group[6] = 32; group[7] = 32; group.put16(10, 1); group.put16(12, 32)
    group.put32(14, UInt32(payload.count)); group.put16(18, 1)
    resources.append(group)

    var file = Data(count: 0x200)
    file.put16(0, 0x5A4D); file.put32(0x3C, 64)
    file.put32(64, 0x4550); file.put16(68, 0x8664); file.put16(70, 1); file.put16(84, 240)
    let optional = 88
    file.put16(optional, 0x20B)
    file.put32(optional + 112 + 16, rva); file.put32(optional + 112 + 20, UInt32(resources.count))
    let section = optional + 240
    for (index, byte) in ".rsrc".utf8.enumerated() { file[section + index] = byte }
    file.put32(section + 8, UInt32(resources.count)); file.put32(section + 12, rva)
    file.put32(section + 16, UInt32(resources.count)); file.put32(section + 20, 0x200)
    file.append(resources)
    return file
}

@Suite("Windows-Pfade & Argumente")
struct PathTests {
    @Test func convertsBetweenWindowsAndMacPaths() throws {
        let prefix = try makeFakePrefix()
        let url = try #require(WindowsPath.unixURL(for: "C:\\Program Files (x86)\\Steam\\steam.exe", prefix: prefix))
        #expect(url.path.hasSuffix("/Bottles/Test/drive_c/Program Files (x86)/Steam/steam.exe"))
        #expect(WindowsPath.windowsPath(for: url, prefix: prefix) == "C:\\Program Files (x86)\\Steam\\steam.exe")
        #expect(WindowsPath.unixURL(for: "z:\\Users", prefix: prefix)?.path == "/Users")
        #expect(WindowsPath.windowsPath(for: URL(fileURLWithPath: "/Applications/X.app"), prefix: prefix) == "Z:\\Applications\\X.app")
        #expect(WindowsPath.unixURL(for: "steam.exe", prefix: prefix) == nil)
        #expect(WindowsPath.baseName("C:\\a\\Steam.EXE") == "steam")
    }

    @Test func splitsAndJoinsArguments() {
        #expect(ArgumentList.split(#"-silent "C:\Program Files\x" -a=b ''"#) == ["-silent", #"C:\Program Files\x"#, "-a=b", ""])
        #expect(ArgumentList.split("   ") == [])
        #expect(ArgumentList.join(["-a", "b c"]) == #"-a "b c""#)
    }
}

@Suite("Apps & Icons")
struct AppTests {
    @Test func extractsIconFromExecutable() throws {
        let payload = Data("FAKE-PNG-DATA-1234".utf8)
        let exe = try temporaryDirectory().appending(path: "game.exe")
        try makeExecutable(iconPayload: payload).write(to: exe)
        let ico = try #require(PEIcon.icoData(fromExecutableAt: exe))
        #expect(ico.u16(2) == 1)                      // Typ: Icon
        #expect(ico.u16(4) == 1)                      // ein Bild
        #expect(ico[6] == 32)                         // Breite
        #expect(ico.u32(6 + 8) == UInt32(payload.count))
        #expect(ico.u32(6 + 12) == 22)                // Bild beginnt nach Kopf + 1 Eintrag
        #expect(ico.suffix(payload.count) == payload)
    }

    @Test func ignoresGarbageAndTruncatedFiles() throws {
        let directory = try temporaryDirectory()
        let garbage = directory.appending(path: "garbage.exe")
        try Data((0..<5000).map { UInt8(truncatingIfNeeded: $0 &* 31) }).write(to: garbage)
        #expect(PEIcon.icoData(fromExecutableAt: garbage) == nil)
        let truncated = directory.appending(path: "truncated.exe")
        try makeExecutable(iconPayload: Data(repeating: 7, count: 64)).prefix(0x230).write(to: truncated)
        #expect(PEIcon.icoData(fromExecutableAt: truncated) == nil)
        #expect(PEIcon.icoData(fromExecutableAt: directory.appending(path: "fehlt.exe")) == nil)
    }

    /// Optional: echte EXE prüfen, z. B. `KELTER_TEST_PE_FILE=…/drive_c/windows/notepad.exe swift test`
    @Test(.enabled(if: ProcessInfo.processInfo.environment["KELTER_TEST_PE_FILE"] != nil))
    func extractsIconFromRealExecutable() throws {
        let path = try #require(ProcessInfo.processInfo.environment["KELTER_TEST_PE_FILE"])
        let ico = try #require(PEIcon.icoData(fromExecutableAt: URL(fileURLWithPath: path)))
        #expect(ico.u16(4) > 0)
    }

    @Test func appsRoundTripAndOldFilesDecode() throws {
        let prefix = try makeFakePrefix()
        let bottle = Bottle(url: prefix, settings: BottleSettings(name: "Test"))
        let app = InstalledApp(name: "Minesweeper", executable: "C:\\windows\\system32\\winemine.exe", arguments: ["-x"])
        try AppStore.save([app], for: bottle)
        #expect(AppStore.load(for: bottle) == [app])

        let old = #"{"apps":[{"name":"Alt","executable":"C:\\a.exe"}]}"#
        try Data(old.utf8).write(to: prefix.appending(path: AppStore.fileName))
        let loaded = AppStore.load(for: bottle)
        #expect(loaded.first?.name == "Alt")
        #expect(loaded.first?.arguments == [])
    }
}

@Suite("Prozesse")
struct ProcessTests {
    @Test func parsesProcArgsBuffer() throws {
        var bytes: [UInt8] = []
        withUnsafeBytes(of: Int32(2).littleEndian) { bytes.append(contentsOf: $0) }
        for string in ["/E/bin/wine", "", "", "/E/bin/wine", #"C:\Steam\steam.exe"#, "WINEPREFIX=/Users/x/Bottles/Steam/", "FOO=a=b", ""] {
            bytes.append(contentsOf: Array(string.utf8) + [0])
        }
        let parsed = try #require(WineProcessScanner.parseProcessArguments(bytes))
        #expect(parsed.executable == "/E/bin/wine")
        #expect(parsed.arguments == ["/E/bin/wine", #"C:\Steam\steam.exe"#])
        #expect(parsed.environment["FOO"] == "a=b")
        #expect(WineProcessScanner.prefixPath(from: parsed.environment) == "/Users/x/Bottles/Steam")

        let info = WineProcessInfo(pid: 1, executablePath: "/E/bin/wine", arguments: parsed.arguments, prefixPath: nil, residentBytes: 0)
        #expect(info.displayName == "steam.exe")
        #expect(info.matches(executable: #"C:\Program Files (x86)\Steam\Steam.exe"#))
        #expect(!info.isSystemProcess)
    }

    @Test func fallsBackToWineConfigDir() {
        let env = ["WINECONFIGDIR": #"\??\Z:\Users\x\Library\Application Support\Kelter\Bottles\Test"#]
        #expect(WineProcessScanner.prefixPath(from: env) == "/Users/x/Library/Application Support/Kelter/Bottles/Test")
    }

    @Test func classifiesWineServices() {
        let services = WineProcessInfo(pid: 2, executablePath: "/E/bin/wine", arguments: ["/E/bin/wine", #"C:\windows\system32\services.exe"#], prefixPath: nil, residentBytes: 0)
        let server = WineProcessInfo(pid: 3, executablePath: "/E/bin/wineserver", arguments: ["/E/bin/wineserver"], prefixPath: nil, residentBytes: 0)
        #expect(services.isSystemProcess)
        #expect(server.isWineserver && server.isSystemProcess)
    }

    /// Liest die echten eigenen Prozesse – prüft, dass sysctl und das Zerlegen nicht abstürzen.
    @Test func scansOwnProcessesWithoutCrashing() {
        let all = WineProcessScanner.scanNow(enginesDirectory: URL(fileURLWithPath: "/"))
        #expect(all.contains { $0.pid == getpid() })
        let none = WineProcessScanner.scanNow(enginesDirectory: URL(fileURLWithPath: "/gibt/es/nicht"))
        #expect(none.isEmpty)
    }
}

@Suite("Log-Verlauf & Analyse")
struct LogHistoryTests {
    @Test func listsAndPrunesLogsPerLabel() throws {
        let directory = try temporaryDirectory()
        for day in 1...5 {
            FileManager.default.createFile(atPath: directory.appending(path: "Steam-2026-11-0\(day)_10-00-00.log").path, contents: Data())
        }
        FileManager.default.createFile(atPath: directory.appending(path: "Steam-Beta-2026-11-01_10-00-00.log").path, contents: Data())
        let logs = LogStore.logs(in: directory, label: "Steam")
        #expect(logs.count == 5)
        #expect(logs.first?.lastPathComponent == "Steam-2026-11-05_10-00-00.log")
        LogStore.prune(in: directory, label: "Steam", keep: 2)
        #expect(LogStore.logs(in: directory, label: "Steam").count == 2)
        #expect(LogStore.logs(in: directory, label: "Steam-Beta").count == 1)
    }

    @Test func findsAntiCheatMissingDllAndCrash() {
        let log = """
        0124:err:module:import_dll Library MSVCP140.dll (which is needed by L"C:\\\\Game\\\\game.exe") not found
        Loading C:\\Game\\EasyAntiCheat\\EasyAntiCheat_EOS_Setup.exe
        wine: Unhandled page fault on read access to 0000000000000000 at address 0000000140001000
        """
        let titles = LogAnalyzer.analyze(log).map(\.title)
        #expect(titles.contains("Anti-Cheat erkannt: Easy Anti-Cheat"))
        #expect(titles.contains("Fehlende DLL: MSVCP140.dll"))
        #expect(titles.contains("Programm abgestürzt"))
        #expect(LogAnalyzer.analyze("alles gut\nSteam-Bibliothek: Call of Duty Vanguard").isEmpty)
    }

    @Test func explainsEngineThatCannotStartProcesses() {
        let log = """
        msync: up and running.
        0024:err:environ:run_wineboot failed to start wineboot 1
        """
        let finding = LogAnalyzer.analyze(log).first
        #expect(finding?.kind == .setup)
        #expect(finding?.title == "Wine kann keine Windows-Programme starten")
        #expect(finding?.detail.contains("Engine") == true)
    }

    @Test func logHeaderUsesLocalTime() throws {
        let directory = try temporaryDirectory()
        let log = try LogFile.create(in: directory, label: "Test")
        let bottle = Bottle(url: directory, settings: BottleSettings(name: "T"))
        let engine = WineEngine(component: InstalledComponent(id: "e", kind: .wine, name: "E", version: "1"), root: directory)
        log.writeHeader(title: "Test", bottle: bottle, engine: engine, command: ["x"], environment: [:], graphics: nil, notes: [])
        log.close()
        let text = try String(contentsOf: log.url, encoding: .utf8)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "xxx"
        #expect(text.contains(formatter.string(from: .now)), "Zeitzone der Ortszeit steht im Kopf")
    }
}
