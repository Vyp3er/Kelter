import Foundation
import Testing
@testable import WineKit

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "KelterTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func touch(_ url: URL, _ contents: String = "") throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(contents.utf8).write(to: url)
}

private func sikarugirEngine() -> WineEngine {
    WineEngine(
        component: InstalledComponent(id: "wine-sik", kind: .wine, name: "Sikarugir", version: "11", features: ["msync", "dxmt"]),
        root: URL(fileURLWithPath: "/E")
    )
}

private let sources = GraphicsSources(
    dxmt: URL(fileURLWithPath: "/R/renderer/dxmt/wine"),
    dxvk: URL(fileURLWithPath: "/C/dxvk")
)

@Suite("Rezepte")
struct RecipeTests {
    @Test func bundledRecipesAreValidAndReferenceKnownThings() throws {
        let recipes = RecipeCatalog.bundledRecipes()
        let prerequisites = RecipeCatalog.bundledPrerequisites()
        let components = try ComponentCatalog.bundled()
        #expect(Set(recipes.map(\.id)).isSuperset(of: ["steam", "epic-games", "gog-galaxy", "battle-net"]))
        for recipe in recipes {
            try RecipeCatalog.validate(recipe)
            for id in recipe.prerequisites ?? [] {
                #expect(prerequisites.contains { $0.id == id }, "\(recipe.id): unbekannte Komponente \(id)")
            }
            for id in recipe.requiredComponents ?? [] {
                #expect(components.source(id: id) != nil, "\(recipe.id): unbekannte Komponente \(id)")
            }
        }
        let steam = try #require(recipes.first { $0.id == "steam" })
        #expect(steam.installer.resolvedType == .exe)
        #expect(steam.executableBackends?["steamwebhelper.exe"] == .dxvk)
        #expect(recipes.first { $0.id == "epic-games" }?.installer.resolvedType == .msi)
    }

    @Test func userRecipesOverrideAndBadFilesWarn() throws {
        let paths = KelterPaths(root: try temporaryDirectory())
        try paths.createDirectories()
        let own = #"{"id":"steam","name":"Mein Steam","summary":"x","installer":{"url":"https://example.com/s.exe"},"executable":"C:\\s.exe"}"#
        try touch(paths.catalog.appending(path: "steam.json"), own)
        try touch(paths.catalog.appending(path: "kaputt.json"), "{")
        try touch(paths.catalog.appending(path: "unsicher.json"), #"{"id":"x","name":"X","summary":"x","installer":{"url":"http://example.com/x.exe"},"executable":"C:\\x.exe"}"#)
        let catalog = RecipeCatalog.load(paths: paths)
        #expect(catalog.recipe(id: "steam")?.name == "Mein Steam")
        #expect(catalog.recipe(id: "x") == nil)
        #expect(catalog.warnings.count == 2)
        #expect(FileManager.default.fileExists(atPath: paths.catalog.appending(path: "Mitgeliefert/steam.json").path))
    }

    @Test func copiesMacOSFontsOnce() throws {
        let source = try temporaryDirectory()
        try touch(source.appending(path: "Arial.ttf"), "font")
        let prefix = try temporaryDirectory()
        let bottle = Bottle(url: prefix, settings: BottleSettings(name: "T"))
        try PrerequisiteInstaller.copyMacOSFonts(["Arial.ttf", "Fehlt.ttf"], into: bottle, source: source)
        try PrerequisiteInstaller.copyMacOSFonts(["Arial.ttf"], into: bottle, source: source)
        #expect(FileManager.default.fileExists(atPath: prefix.appending(path: "drive_c/windows/Fonts/Arial.ttf").path))
        try PrerequisiteInstaller.markInstalled("macos-fonts", in: bottle)
        #expect(PrerequisiteInstaller.installed(in: bottle) == ["macos-fonts"])
    }
}

@Suite("Registry")
struct RegistryTests {
    @Test func rendersRegFile() {
        let text = RegistryFile.render([
            .deleteKey(RegistryKeys.appDefaultsOverrides(for: "alt.exe")),
            .setString(key: RegistryKeys.dllOverrides, name: "d3d11", value: "builtin"),
            .setString(key: RegistryKeys.dllOverrides, name: "dxgi", value: "native,builtin"),
            .setDWord(key: RegistryKeys.wineBus, name: "Enable SDL", value: 1)
        ])
        #expect(text.hasPrefix("Windows Registry Editor Version 5.00\r\n"))
        #expect(text.contains(#"[-HKEY_CURRENT_USER\Software\Wine\AppDefaults\alt.exe\DllOverrides]"#))
        #expect(text.contains("\"d3d11\"=\"builtin\"\r\n\"dxgi\"=\"native,builtin\""))
        #expect(text.contains("\"Enable SDL\"=dword:00000001"))
        let data = RegistryFile.data([.setString(key: "K", name: "a", value: "b")])
        #expect(data.prefix(2) == Data([0xFF, 0xFE]))
    }
}

@Suite("Grafik-Planung")
struct LaunchPlanTests {
    @Test func dxmtUsesDLLPathAndSteamHelperGetsDXVK() {
        var settings = BottleSettings(name: "Steam")
        settings.executableBackends = ["steamwebhelper.exe": .dxvk]
        let plan = LaunchPlanner.plan(settings: settings, engine: sikarugirEngine(), sources: sources, dllPathVariable: "WINEDLLPATH_DXMT")
        #expect(plan.backend == .dxmt)
        #expect(plan.method == .dxmtDLLPath)
        #expect(plan.environment["WINEDLLPATH_DXMT"] == "/R/renderer/dxmt/wine")
        #expect(plan.summary == "DXMT (Metal) über WINEDLLPATH_DXMT")
        #expect(plan.environment["DXVK_ASYNC"] == "1")
        #expect(plan.dxvkSource != nil)
        #expect(plan.managedExecutables == ["steamwebhelper.exe"])
        #expect(plan.registry.contains(.setString(key: RegistryKeys.dllOverrides, name: "d3d11", value: "builtin")))
        #expect(plan.registry.contains(.deleteKey(RegistryKeys.appDefaultsOverrides(for: "steamwebhelper.exe"))))
        #expect(plan.notes.isEmpty)
    }

    @Test func fallsBackToEngineCopyAndWineD3D() {
        let copy = LaunchPlanner.plan(settings: BottleSettings(name: "T"), engine: sikarugirEngine(), sources: sources, dllPathVariable: nil)
        #expect(copy.method == .dxmtEngineCopy)
        #expect(copy.environment["WINEDLLPATH_DXMT"] == nil)

        let winehq = WineEngine(component: InstalledComponent(id: "w", kind: .wine, name: "WineHQ", version: "11"), root: URL(fileURLWithPath: "/W"))
        let fallback = LaunchPlanner.plan(settings: BottleSettings(name: "T"), engine: winehq, sources: sources, dllPathVariable: "WINEDLLPATH_DXMT")
        #expect(fallback.backend == .wined3d)
        #expect(fallback.notes.count == 1)

        var dxvkSettings = BottleSettings(name: "T")
        dxvkSettings.graphicsBackend = .dxvk
        let noDXVK = LaunchPlanner.plan(settings: dxvkSettings, engine: sikarugirEngine(), sources: GraphicsSources(), dllPathVariable: "WINEDLLPATH_DXMT")
        #expect(noDXVK.backend == .wined3d)
    }

    @Test func removesOldExceptionsAndRejectsImpossibleOnes() {
        var settings = BottleSettings(name: "T")
        settings.managedExecutables = ["alt.exe"]
        settings.executableBackends = ["spiel.exe": .wined3d]   // in einer DXMT-Bottle nicht möglich
        let plan = LaunchPlanner.plan(settings: settings, engine: sikarugirEngine(), sources: sources, dllPathVariable: "WINEDLLPATH_DXMT")
        #expect(plan.registry.contains(.deleteKey(RegistryKeys.appDefaultsOverrides(for: "alt.exe"))))
        #expect(plan.managedExecutables.isEmpty)
        #expect(plan.notes.contains { $0.contains("spiel.exe") })
        #expect(plan.dxvkSource == nil)
    }

    @Test func controllerModesAndMarkerChanges() {
        var settings = BottleSettings(name: "T")
        let base = LaunchPlanner.plan(settings: settings, engine: sikarugirEngine(), sources: sources, dllPathVariable: "WINEDLLPATH_DXMT")
        settings.controllerMode = .macOSService
        settings.controllerBackgroundInput = true
        let service = LaunchPlanner.plan(settings: settings, engine: sikarugirEngine(), sources: sources, dllPathVariable: "WINEDLLPATH_DXMT")
        #expect(service.environment["SDL_JOYSTICK_HIDAPI"] == "0")
        #expect(service.environment["SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS"] == "1")
        #expect(service.marker != base.marker)
        settings.controllerMode = .directHID
        let hid = LaunchPlanner.plan(settings: settings, engine: sikarugirEngine(), sources: sources, dllPathVariable: "WINEDLLPATH_DXMT")
        #expect(hid.registry.contains(.setDWord(key: RegistryKeys.wineBus, name: "Enable SDL", value: 0)))
    }

    @Test func findsGraphicsFilesAndChecksPrependSupport() throws {
        let root = try temporaryDirectory()
        try touch(root.appending(path: "rt/renderer/dxmt/wine/x86_64-windows/d3d11.dll"))
        try touch(root.appending(path: "rt/renderer/dxmt/wine/x86_64-unix/winemetal.so"))
        try touch(root.appending(path: "rt/renderer/dxmt/version"), "v0.80-244\n")
        try touch(root.appending(path: "dxvk/dxvk-macOS-async/x64/d3d11.dll"))
        try touch(root.appending(path: "dxvk/dxvk-macOS-async/x64/DXGI.dll"))
        let dxmt = try #require(GraphicsLayout.findDXMT(in: root.appending(path: "rt")))
        #expect(dxmt.lastPathComponent == "wine")
        #expect(GraphicsLayout.version(near: dxmt) == "v0.80-244")
        let dxvk = try #require(GraphicsLayout.findDXVK(in: root.appending(path: "dxvk")))
        #expect(GraphicsLayout.dllNames(in: dxvk.appending(path: "x64")) == ["d3d11", "dxgi"])

        let engine = root.appending(path: "engine")
        try touch(engine.appending(path: "lib/wine/x86_64-unix/ntdll.so"), "ELF…WINEDLLPATH_PREPEND…")
        #expect(WineLayout.dllPathVariable(root: engine) == "WINEDLLPATH_PREPEND")
        #expect(WineLayout.dllPathVariable(root: root.appending(path: "fehlt")) == nil)
        #expect(WineLayout.ntdllContains("WINEMSYNC", root: root.appending(path: "fehlt")) == nil)

        // Sikarugir: WINEDLLPATH_DXMT hat Vorrang, msync wird in der Engine selbst erkannt.
        let sikarugir = root.appending(path: "sikarugir")
        try touch(sikarugir.appending(path: "lib/wine/x86_64-unix/ntdll.so"), "WINEDLLPATH_DXVK\0WINEDLLPATH_DXMT\0WINEMSYNC\0WINEDLLPATH_PREPEND")
        #expect(WineLayout.dllPathVariable(root: sikarugir) == "WINEDLLPATH_DXMT")
        let withoutFeature = WineEngine(component: InstalledComponent(id: "x", kind: .wine, name: "X", version: "1"), root: sikarugir)
        #expect(withoutFeature.supportsMsync)
        let plain = WineEngine(component: InstalledComponent(id: "y", kind: .wine, name: "Y", version: "1", features: ["msync"]), root: engine)
        #expect(!plain.supportsMsync, "Die Engine selbst zählt, nicht der Katalog")
    }

    @Test func copiesDLLsReplacingExistingFiles() throws {
        let root = try temporaryDirectory()
        try touch(root.appending(path: "src/d3d11.dll"), "neu")
        try touch(root.appending(path: "src/readme.txt"), "x")
        try touch(root.appending(path: "dst/d3d11.dll"), "alt")
        try Wine.copyDLLs(from: root.appending(path: "src"), to: root.appending(path: "dst"))
        #expect(try String(contentsOf: root.appending(path: "dst/d3d11.dll"), encoding: .utf8) == "neu")
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "dst/readme.txt").path))
    }
}

@Suite("Steam-Bibliothek")
struct SteamLibraryTests {
    @Test func readsLibrariesAndManifests() throws {
        let prefix = try temporaryDirectory()
        let steamapps = prefix.appending(path: "drive_c/Program Files (x86)/Steam/steamapps")
        try touch(steamapps.appending(path: "libraryfolders.vdf"), """
        "libraryfolders"
        {
            "0"
            {
                "path"		"C:\\\\Program Files (x86)\\\\Steam"
                "apps" { "291550" "123" }
            }
            "1"
            {
                "path"		"D:\\\\SteamLibrary"
            }
        }
        """)
        try touch(steamapps.appending(path: "appmanifest_291550.acf"), """
        "AppState"
        {
            "appid"		"291550"
            "name"		"Brawlhalla"
            "StateFlags"		"4"
            "installdir"		"Brawlhalla"
            "SizeOnDisk"		"512000000"
        }
        """)
        try touch(steamapps.appending(path: "appmanifest_228980.acf"), #""AppState" { "appid" "228980" "name" "Steamworks Common Redistributables" "installdir" "Steamworks Shared" }"#)
        try touch(steamapps.appending(path: "common/Brawlhalla/Brawlhalla.exe"), String(repeating: "x", count: 100))
        try touch(steamapps.appending(path: "common/Brawlhalla/unins000.exe"))

        let games = SteamLibrary.games(steamExecutable: #"C:\Program Files (x86)\Steam\steam.exe"#, prefix: prefix)
        #expect(games.map(\.name) == ["Brawlhalla"])
        let game = try #require(games.first)
        #expect(game.isFullyInstalled)
        #expect(game.folder == #"C:\Program Files (x86)\Steam\steamapps\common\Brawlhalla"#)
        #expect(SteamLibrary.executables(of: game, prefix: prefix) == ["Brawlhalla.exe"])

        let process = WineProcessInfo(pid: 9, executablePath: "/E/bin/wine",
                                      arguments: ["/E/bin/wine", #"C:\Program Files (x86)\Steam\steamapps\common\Brawlhalla\Brawlhalla.exe"#],
                                      prefixPath: nil, residentBytes: 0)
        #expect(process.isInside(windowsFolder: game.folder))
        let app = InstalledApp(name: "Brawlhalla", executable: #"C:\Program Files (x86)\Steam\steam.exe"#, steamAppID: "291550", processFolder: game.folder)
        #expect(app.owns(process))
    }
}
