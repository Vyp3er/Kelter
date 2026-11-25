import Foundation
import Testing
@testable import WineKit

/// Ein leerer Kelter-Ordner im Temp-Verzeichnis.
private func temporaryPaths() throws -> KelterPaths {
    let root = FileManager.default.temporaryDirectory.appending(path: "KelterTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    let paths = KelterPaths(root: root)
    try paths.createDirectories()
    return paths
}

/// Legt eine Fake-Wine-Installation (nur leere Dateien) an.
private func makeFakeWine(at root: URL, launcher: String = "wine") throws {
    let bin = root.appending(path: "bin", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: bin.appending(path: launcher).path, contents: Data())
    FileManager.default.createFile(atPath: bin.appending(path: "wineserver").path, contents: Data())
}

private func engine(features: [String], root: URL = URL(fileURLWithPath: "/tmp/engine")) -> WineEngine {
    WineEngine(
        component: InstalledComponent(id: "test", kind: .wine, name: "Test", version: "1", features: features),
        root: root
    )
}

@Suite("Katalog")
struct CatalogTests {
    @Test func bundledCatalogHasRecommendedEngineWithChecksum() throws {
        let catalog = try ComponentCatalog.bundled()
        let engine = try #require(catalog.recommendedEngine)
        #expect(engine.kind == .wine)
        #expect(engine.id == "wine-sikarugir-10.0_8")
        #expect(engine.sha256?.count == 64)
        #expect(Set(catalog.components.map(\.id)).count == catalog.components.count, "IDs müssen eindeutig sein")
        // MoltenVK steckt in den Sikarugir-Bibliotheken und hat keine eigene Quelle mehr.
        for kind in ComponentKind.allCases where kind != .moltenvk {
            #expect(!catalog.components(of: kind).isEmpty, "Keine Quelle für \(kind)")
        }
    }

    @Test func brokenEngineIsFlaggedOnlyFromItsMacOSVersion() throws {
        let catalog = try ComponentCatalog.bundled()
        let broken = try #require(catalog.source(id: "wine-sikarugir-11.0_1"))
        #expect(broken.problem(macOSMajor: 27)?.contains("macOS 27") == true)
        #expect(broken.problem(macOSMajor: 26) == nil)
        #expect(!broken.isCompatible(macOSMajor: 28))
        #expect(!broken.isRecommended)

        // Eine empfohlene Engine, die hier nicht läuft, wird übersprungen.
        let url = URL(string: "https://example.com/w.tar.xz")!
        let old = ComponentSource(id: "alt", kind: .wine, name: "Alt", version: "1", summary: "", url: url,
                                  recommended: true, incompatibleFromMacOS: 1)
        let ok = ComponentSource(id: "gut", kind: .wine, name: "Gut", version: "2", summary: "", url: url)
        #expect(ComponentCatalog(components: [old, ok]).recommendedEngine?.id == "gut")
        #expect(old.problem() != nil)
    }

    @Test func userEntriesReplaceAndExtend() throws {
        var catalog = try ComponentCatalog.bundled()
        let count = catalog.components.count
        let replaced = ComponentSource(id: "dxmt-0.80", kind: .dxmt, name: "Eigenes DXMT", version: "x", summary: "", url: URL(string: "https://example.com/a.tar.gz")!)
        let added = ComponentSource(id: "mein-wine", kind: .wine, name: "Mein Wine", version: "1", summary: "", url: URL(string: "https://example.com/b.tar.xz")!)
        catalog.merge(ComponentCatalog(components: [replaced, added]))
        #expect(catalog.components.count == count + 1)
        #expect(catalog.source(id: "dxmt-0.80")?.name == "Eigenes DXMT")
    }

    @Test func loadWritesReferenceCopyAndReportsBrokenUserFile() throws {
        let paths = try temporaryPaths()
        try Data("kein json".utf8).write(to: paths.catalog.appending(path: "components.json"))
        let (catalog, warning) = try ComponentCatalog.load(paths: paths)
        #expect(!catalog.components.isEmpty)
        #expect(warning != nil)
        #expect(FileManager.default.fileExists(atPath: paths.catalog.appending(path: "components.default.json").path))
    }

    @Test func sikarugirEngineRequiresRuntimeWhichIsInstalledFirst() throws {
        let catalog = try ComponentCatalog.bundled()
        let engine = try #require(catalog.recommendedEngine)
        let order = catalog.installOrder(for: engine).map(\.id)
        #expect(order == ["sikarugir-runtime-1.0.27", "wine-sikarugir-10.0_8"])
        let runtime = try #require(catalog.source(id: "sikarugir-runtime-1.0.27"))
        #expect(runtime.kind == .runtime)
        #expect(runtime.extract?.contains { $0.localizedCaseInsensitiveContains("d3dmetal") || $0.localizedCaseInsensitiveContains("gptk") } == false,
                "D3DMetal/GPTK darf nicht entpackt werden")
    }

    @Test func installOrderSurvivesCycles() {
        let url = URL(string: "https://example.com/x.tar")!
        let a = ComponentSource(id: "a", kind: .wine, name: "A", version: "1", summary: "", url: url, requires: ["b"])
        let b = ComponentSource(id: "b", kind: .runtime, name: "B", version: "1", summary: "", url: url, requires: ["a"])
        let catalog = ComponentCatalog(components: [a, b])
        #expect(catalog.installOrder(for: a).map(\.id) == ["b", "a"])
    }

    @Test func checksumNormalization() {
        #expect(Checksum.normalize(" sha256:ABCDEF ") == "abcdef")
    }
}

@Suite("Engine-Layout")
struct LayoutTests {
    @Test func findsWineRootInsideWineHQAppBundle() throws {
        let paths = try temporaryPaths()
        let root = paths.downloads.appending(path: "x/Wine Devel.app/Contents/Resources/wine", directoryHint: .isDirectory)
        try makeFakeWine(at: root)
        #expect(WineLayout.findWineRoot(in: paths.downloads.appending(path: "x"))?.standardizedFileURL == root.standardizedFileURL)
    }

    @Test func findsSikarugirBundleAndOldWine64Launcher() throws {
        let paths = try temporaryPaths()
        let root = paths.downloads.appending(path: "y/wswine.bundle", directoryHint: .isDirectory)
        try makeFakeWine(at: root, launcher: "wine64")
        try Data("wine sikarugir 11.0 (revision 1)\n".utf8).write(to: root.appending(path: "version"))
        let found = try #require(WineLayout.findWineRoot(in: paths.downloads.appending(path: "y")))
        #expect(WineLayout.versionFile(in: found) == "wine sikarugir 11.0 (revision 1)")
        #expect(engine(features: [], root: found).wineBinary.lastPathComponent == "wine64")
    }

    @Test func findsRuntimeRootAndResolvesEngineRequirements() throws {
        let paths = try temporaryPaths()
        let contents = paths.downloads.appending(path: "t/Template-1.0.27.app/Contents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: contents.appending(path: "Frameworks"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: contents.appending(path: "Resources/vulkan/icd.d"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: contents.appending(path: "Resources/vulkan/icd.d/MoltenVK_icd.json").path, contents: Data("{}".utf8))
        let found = try #require(RuntimeLibraries.findRoot(in: paths.downloads.appending(path: "t")))
        #expect(found.standardizedFileURL == contents.standardizedFileURL)
        #expect(RuntimeLibraries(root: found).moltenVKDriver != nil)

        // Engine mit fehlender und danach vorhandener Laufzeit-Komponente.
        let store = ComponentStore(paths: paths)
        try makeFakeWine(at: store.filesDirectory(for: "wine-x"))
        try store.save(InstalledComponent(id: "wine-x", kind: .wine, name: "X", version: "1", requires: ["rt"]))
        #expect(store.engine(id: "wine-x")?.missingRequirements == ["rt"])

        try FileManager.default.createDirectory(at: store.filesDirectory(for: "rt").appending(path: "Frameworks"), withIntermediateDirectories: true)
        try store.save(InstalledComponent(id: "rt", kind: .runtime, name: "RT", version: "1"))
        let engine = try #require(store.engine(id: "wine-x"))
        #expect(engine.isComplete)
        #expect(engine.runtime?.frameworks.lastPathComponent == "Frameworks")
    }

    @Test func oldManifestWithoutRequiresStillDecodes() throws {
        let json = #"{"id":"a","kind":"wine","name":"A","version":"1","installedAt":"2026-11-25T10:00:00Z","features":[]}"#
        let component = try JSONDecoder.kelter.decode(InstalledComponent.self, from: Data(json.utf8))
        #expect(component.requires == nil)
    }

    @Test func returnsNilWithoutWineserver() throws {
        let paths = try temporaryPaths()
        let bin = paths.downloads.appending(path: "z/bin", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: bin.appending(path: "wine").path, contents: Data())
        #expect(WineLayout.findWineRoot(in: paths.downloads) == nil)
    }
}

@Suite("Umgebung")
struct EnvironmentTests {
    let prefix = URL(fileURLWithPath: "/Users/test/Library/Application Support/Kelter/Bottles/Test")

    @Test func setsPrefixDebugAndMsync() {
        let env = WineEnvironment.build(
            base: ["PATH": "/usr/bin", "WINEPREFIX": "/falsch", "WINEDLLOVERRIDES": "foo=n"],
            prefix: prefix,
            engine: engine(features: ["msync"]),
            settings: BottleSettings(name: "Test")
        )
        #expect(env["WINEPREFIX"] == prefix.path)
        #expect(env["WINEDEBUG"] == "fixme-all")
        #expect(env["WINEMSYNC"] == "1")
        #expect(env["PATH"] == "/usr/bin")
        #expect(env["WINEDLLOVERRIDES"] == "winemenubuilder.exe=d", "Overrides aus der Shell dürfen nicht durchsickern")
    }

    @Test func runtimeLibrariesSetDyldAndVulkanPaths() throws {
        let paths = try temporaryPaths()
        let root = paths.engines.appending(path: "rt/files", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root.appending(path: "Resources/vulkan/icd.d"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: root.appending(path: "Resources/vulkan/icd.d/MoltenVK_icd.json").path, contents: Data("{}".utf8))
        let withRuntime = WineEngine(
            component: InstalledComponent(id: "e", kind: .wine, name: "E", version: "1"),
            root: URL(fileURLWithPath: "/tmp/engine"),
            runtime: RuntimeLibraries(root: root)
        )
        let env = WineEnvironment.build(base: ["DYLD_FALLBACK_LIBRARY_PATH": "/falsch"], prefix: prefix, engine: withRuntime, settings: BottleSettings(name: "T"))
        #expect(env["DYLD_FALLBACK_LIBRARY_PATH"] == root.appending(path: "Frameworks").path + ":/usr/local/lib:/usr/lib")
        #expect(env["VK_DRIVER_FILES"]?.hasSuffix("MoltenVK_icd.json") == true)

        let without = WineEnvironment.build(base: ["DYLD_FALLBACK_LIBRARY_PATH": "/falsch"], prefix: prefix, engine: engine(features: []), settings: BottleSettings(name: "T"))
        #expect(without["DYLD_FALLBACK_LIBRARY_PATH"] == nil)
    }

    @Test func noMsyncForEnginesWithoutSupport() {
        let env = WineEnvironment.build(base: [:], prefix: prefix, engine: engine(features: []), settings: BottleSettings(name: "Test"))
        #expect(env["WINEMSYNC"] == nil)
    }

    @Test func bottleSettingsWinAndOverridesMerge() {
        var settings = BottleSettings(name: "Test")
        settings.environment = ["WINEDEBUG": "+loaddll", "WINEDLLOVERRIDES": "d3d11=b"]
        let env = WineEnvironment.build(
            base: [:],
            prefix: prefix,
            engine: engine(features: []),
            settings: settings,
            extra: ["WINEDLLOVERRIDES": "dxgi,d3d11=n,b", "STEAM_RUNTIME": "0"]
        )
        #expect(env["WINEDEBUG"] == "+loaddll")
        #expect(env["STEAM_RUNTIME"] == "0")
        #expect(env["WINEDLLOVERRIDES"] == "d3d11=b;dxgi=n,b;winemenubuilder.exe=d")
    }

    @Test func parsesOverridesWithCommaValues() {
        let parsed = WineEnvironment.parseDLLOverrides("dxgi,d3d11=n,b; winemenubuilder.exe=d;mshtml=")
        #expect(parsed == ["dxgi": "n,b", "d3d11": "n,b", "winemenubuilder.exe": "d", "mshtml": ""])
    }
}

@Suite("Bottles")
struct BottleTests {
    @Test func createListAndReject() throws {
        let paths = try temporaryPaths()
        let store = BottleStore(paths: paths)
        let bottle = try store.create(name: "  Steam  ", engineID: nil)
        #expect(bottle.name == "Steam")
        #expect(bottle.id == "Steam")
        #expect(!bottle.isInitialized)
        #expect(store.list().map(\.name) == ["Steam"])
        #expect(throws: KelterError.bottleExists("Steam")) { try store.create(name: "Steam", engineID: nil) }
        #expect(throws: KelterError.invalidBottleName) { try store.create(name: " .versteckt", engineID: nil) }
        #expect(try BottleStore.folderName(for: "A/B:C") == "A-B-C")
    }

    @Test func failedSetupIsNotInitializedAndCanBeReset() throws {
        let paths = try temporaryPaths()
        let bottle = try BottleStore(paths: paths).create(name: "Steam", engineID: nil)
        let fileManager = FileManager.default
        // So sah die Bottle nach „failed to start wineboot 1“ aus.
        try Data("WINE REGISTRY".utf8).write(to: bottle.url.appending(path: "system.reg"))
        try Data().write(to: bottle.url.appending(path: "user.reg"))
        try fileManager.createDirectory(at: bottle.driveC.appending(path: "windows"), withIntermediateDirectories: true)
        let outside = paths.root.appending(path: "draussen", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("bleibt".utf8).write(to: outside.appending(path: "wichtig.txt"))
        let dosdevices = bottle.url.appending(path: "dosdevices", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: dosdevices, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(at: dosdevices.appending(path: "z:"), withDestinationURL: outside)
        try fileManager.createSymbolicLink(at: dosdevices.appending(path: "c:"), withDestinationURL: URL(fileURLWithPath: "../drive_c"))

        #expect(!bottle.isInitialized)
        #expect(bottle.hasIncompleteSetup)
        try bottle.removeIncompleteSetup()
        #expect(!bottle.hasIncompleteSetup)
        #expect(!fileManager.fileExists(atPath: dosdevices.path))
        #expect(!fileManager.fileExists(atPath: bottle.url.appending(path: "system.reg").path))
        // Ziele der Laufwerks-Links, drive_c und Kelters Einstellungen bleiben.
        #expect(fileManager.fileExists(atPath: outside.appending(path: "wichtig.txt").path))
        #expect(fileManager.fileExists(atPath: bottle.driveC.appending(path: "windows").path))
        #expect(fileManager.fileExists(atPath: bottle.settingsFile.path))

        // Fertig eingerichtet: wird erkannt und nie zurückgesetzt.
        try Data("WINE REGISTRY".utf8).write(to: bottle.url.appending(path: "system.reg"))
        try Data().write(to: bottle.url.appending(path: ".update-timestamp"))
        #expect(bottle.isInitialized)
        #expect(!bottle.hasIncompleteSetup)
        try bottle.removeIncompleteSetup()
        #expect(fileManager.fileExists(atPath: bottle.url.appending(path: "system.reg").path))
    }

    @Test func oldSettingsFilesGetDefaults() throws {
        let json = #"{"name": "Alt"}"#
        let settings = try JSONDecoder.kelter.decode(BottleSettings.self, from: Data(json.utf8))
        #expect(settings.graphicsBackend == .dxmt)
        #expect(settings.windowsVersion == .win10)
        #expect(settings.wineDebug == "fixme-all")
    }
}

/// Läuft nur, wenn `KELTER_TEST_RUNTIME_ARCHIVE` auf eine lokal geladene `Template-1.0.27.tar.xz` zeigt.
/// Prüft den echten Installer (Prüfsumme, Teil-Entpacken, Ordneraufbau) ohne Netz und ohne etwas auszuführen.
@Suite("Installer (optional, mit echtem Archiv)")
struct InstallerIntegrationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["KELTER_TEST_RUNTIME_ARCHIVE"] != nil))
    func installsSikarugirRuntimeWithoutD3DMetal() async throws {
        let archive = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["KELTER_TEST_RUNTIME_ARCHIVE"]))
        var source = try #require(try ComponentCatalog.bundled().source(id: "sikarugir-runtime-1.0.27"))
        source.url = archive
        let paths = try temporaryPaths()
        let installed = try await ComponentInstaller(paths: paths).install(source) { _ in }
        #expect(installed.sha256 == Checksum.normalize(source.sha256!))

        let runtime = RuntimeLibraries(root: ComponentStore(paths: paths).filesDirectory(for: source.id))
        let fileManager = FileManager.default
        for lib in ["libfreetype.6.dylib", "libgnutls.30.dylib", "libSDL2-2.0.0.dylib", "libMVK.dylib"] {
            #expect(fileManager.fileExists(atPath: runtime.frameworks.appending(path: lib).path), "\(lib) fehlt")
        }
        #expect(runtime.moltenVKDriver != nil)
        #expect(runtime.gstreamerPlugins != nil)
        #expect(runtime.renderer("dxmt") != nil)
        #expect(!fileManager.fileExists(atPath: runtime.root.appending(path: "SharedSupport/renderer/d3dmetal").path), "D3DMetal wurde entpackt")
        #expect(try fileManager.contentsOfDirectory(atPath: paths.downloads.path).isEmpty, "Downloads/ wurde nicht aufgeräumt")
    }
}

@Suite("Logs")
struct LogTests {
    @Test func fileNamesAreSafeAndUnique() throws {
        let date = Date(timeIntervalSince1970: 0)
        #expect(LogFile.fileName(label: "Steam / Login", date: date).hasPrefix("Steam___Login-19"))
        #expect(LogFile.sanitize("...") == "log")
        let paths = try temporaryPaths()
        let first = try LogFile.create(in: paths.logs, label: "winecfg", date: date)
        let second = try LogFile.create(in: paths.logs, label: "winecfg", date: date)
        #expect(first.url != second.url)
    }
}
