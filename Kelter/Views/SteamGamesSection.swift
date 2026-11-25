import SwiftUI
import WineKit

/// Die in Steam installierten Spiele: starten, als eigene App eintragen, Grafik-Ausnahme setzen.
struct SteamGamesSection: View {
    @Environment(AppModel.self) private var model
    let bottle: Bottle
    let steam: InstalledApp
    @State private var games: [SteamGame] = []

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                if games.isEmpty {
                    Text("Noch keine Spiele. Installiere Spiele wie gewohnt in Steam – sie erscheinen hier automatisch.")
                        .foregroundStyle(.secondary)
                }
                ForEach(games) { game in
                    SteamGameRow(bottle: bottle, steam: steam, game: game)
                    if game.id != games.last?.id { Divider() }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        } label: {
            Label("Spiele in Steam", systemImage: "gamecontroller")
        }
        .task(id: bottle.id) {
            while !Task.isCancelled {
                let current = model.steamGames(for: steam, in: bottle)
                if current != games { games = current }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }
}

private struct SteamGameRow: View {
    @Environment(AppModel.self) private var model
    let bottle: Bottle
    let steam: InstalledApp
    let game: SteamGame
    @State private var executables: [String] = []

    private var running: Bool { model.isRunning(game, in: bottle) }
    private var isInMyApps: Bool { model.apps(in: bottle).contains { $0.steamAppID == game.appID } }
    /// Grafik-Ausnahme, die für eine der EXEs des Spiels gesetzt ist.
    private var exception: (exe: String, backend: GraphicsBackend)? {
        for exe in executables {
            if let backend = bottle.settings.executableBackends.first(where: { $0.key.caseInsensitiveCompare(exe) == .orderedSame })?.value {
                return (exe, backend)
            }
        }
        return nil
    }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(game.name).font(.headline)
                HStack(spacing: 6) {
                    StatusBadge(running: running)
                    if !game.isFullyInstalled { Badge(text: "lädt/aktualisiert", color: .blue) }
                    Text(game.sizeOnDisk > 0 ? Int64(game.sizeOnDisk).formatted(.byteCount(style: .file)) : "")
                        .font(.caption).foregroundStyle(.secondary)
                    if let exception {
                        Text("Grafik: \(exception.backend.displayName) für \(exception.exe)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if running {
                        UsageText(usage: model.usage(of: model.processes(in: bottle).filter { $0.isInside(windowsFolder: game.folder) }))
                    }
                }
            }
            Spacer()
            Menu {
                Button(isInMyApps ? "Schon unter „Meine Apps“" : "Zu „Meine Apps“ hinzufügen") {
                    model.addToMyApps(game, steam: steam, in: bottle)
                }
                .disabled(isInMyApps)
                Divider()
                graphicsMenu
                Divider()
                if let folder = WindowsPath.unixURL(for: game.folder, prefix: bottle.url) {
                    Button("Spielordner im Finder zeigen") { model.reveal(folder) }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Button {
                Task { await model.launch(game, via: steam, in: bottle) }
            } label: {
                Label("Starten", systemImage: "play.fill")
            }
            .disabled(running || !game.isFullyInstalled)
        }
        .task(id: game.id) {
            executables = SteamLibrary.executables(of: game, prefix: bottle.url)
        }
    }

    @ViewBuilder
    private var graphicsMenu: some View {
        let bottleBackend = bottle.settings.graphicsBackend
        // Möglich ist nur der „Gegenspieler“ des Bottle-Backends (siehe LaunchPlanner).
        let alternative: GraphicsBackend = bottleBackend == .dxvk ? .wined3d : .dxvk
        if let exe = exception?.exe ?? executables.first {
            Menu("Grafik für \(exe)") {
                Button("Bottle-Standard (\(bottleBackend.displayName))") {
                    Task { await model.setException(nil, for: exe, in: bottle) }
                }
                Button(alternative.displayName) {
                    Task { await model.setException(alternative, for: exe, in: bottle) }
                }
                if executables.count > 1 {
                    Divider()
                    Text("Weitere EXEs: " + executables.dropFirst().prefix(4).joined(separator: ", "))
                }
            }
            .help("Läuft ein Spiel unter \(bottleBackend.displayName) schlecht, hier auf \(alternative.displayName) umschalten. Spiel danach neu starten.")
        } else {
            Text("Keine EXE im Spielordner gefunden")
        }
    }
}
