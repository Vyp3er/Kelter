import SwiftUI
import WineKit

/// Alle Apps aus allen Bottles mit Start/Stop und Status.
struct MyAppsView: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: SidebarItem?

    var body: some View {
        Group {
            if model.allApps.isEmpty {
                ContentUnavailableView {
                    Label("Noch keine Apps", systemImage: "square.grid.2x2")
                } description: {
                    Text("Installiere Steam & Co. mit einem Klick aus dem Katalog. Oder trag in einer Bottle eine vorhandene .exe als App ein.")
                } actions: {
                    Button("Zum Katalog") { selection = .catalog }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                List {
                    ForEach(model.allApps) { ref in
                        AppRow(bottle: ref.bottle, app: ref.app, showsBottle: true)
                            .contentShape(Rectangle())
                            .onTapGesture { selection = .app(ref.app.id) }
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Meine Apps")
    }
}

/// Eine Zeile: Icon, Name, Status, Start/Stop.
struct AppRow: View {
    @Environment(AppModel.self) private var model
    let bottle: Bottle
    let app: InstalledApp
    var showsBottle = false

    private var running: Bool { model.isRunning(app, in: bottle) }

    var body: some View {
        HStack(spacing: 12) {
            AppIconView(app: app, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).font(.headline)
                HStack(spacing: 6) {
                    StatusBadge(running: running)
                    if running {
                        UsageText(usage: model.usage(of: model.processes(of: app, in: bottle)))
                    }
                    if showsBottle {
                        Text("Bottle: \(bottle.name)").font(.caption).foregroundStyle(.secondary)
                    }
                    if app.performanceHUD != .off {
                        Image(systemName: "speedometer").font(.caption).foregroundStyle(.secondary).help("FPS-Overlay an")
                    }
                }
            }
            Spacer()
            AppStartStopButtons(bottle: bottle, app: app)
        }
        .padding(.vertical, 4)
    }
}

struct AppStartStopButtons: View {
    @Environment(AppModel.self) private var model
    let bottle: Bottle
    let app: InstalledApp
    @State private var stopping = false
    @State private var starting = false

    var body: some View {
        if model.isRunning(app, in: bottle) {
            Button {
                stopping = true
                Task {
                    await model.stop(app, in: bottle)
                    stopping = false
                }
            } label: {
                if stopping {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Beenden", systemImage: "stop.fill")
                }
            }
            .disabled(stopping)
        } else {
            Button {
                starting = true
                Task {
                    await model.launch(app, in: bottle)
                    // Kurz warten, bis die Prozess-Erkennung den Start sieht.
                    try? await Task.sleep(for: .seconds(2))
                    starting = false
                }
            } label: {
                if starting {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Starten", systemImage: "play.fill")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(starting || model.engine(for: bottle)?.isComplete != true || model.bottleActivity[bottle.id] != nil)
        }
    }
}

/// „CPU 23 % · RAM 1,2 GB“
struct UsageText: View {
    let usage: AppModel.Usage

    var body: some View {
        Text("CPU \(Int(usage.cpuPercent.rounded())) % · RAM \(Int64(usage.residentBytes).formatted(.byteCount(style: .memory)))")
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .help("100 % entspricht einem voll ausgelasteten CPU-Kern")
    }
}

struct StatusBadge: View {
    let running: Bool

    var body: some View {
        Badge(text: running ? "läuft" : "beendet", color: running ? .green : .secondary)
    }
}

struct AppIconView: View {
    @Environment(AppModel.self) private var model
    let app: InstalledApp
    var size: CGFloat = 40

    var body: some View {
        Group {
            if let image = model.icons[app.id] {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "app.dashed")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(.secondary)
                    .padding(size * 0.12)
            }
        }
        .frame(width: size, height: size)
    }
}
