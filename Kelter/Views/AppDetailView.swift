import SwiftUI
import WineKit

/// Eine App: starten/stoppen, Status, FPS-Overlay, Logs, „Erweitert“ für Argumente und Umgebung.
struct AppDetailView: View {
    @Environment(AppModel.self) private var model
    let bottle: Bottle
    let app: InstalledApp
    @Binding var selection: SidebarItem?

    @State private var showAdvanced = false
    @State private var showIssues = false
    @State private var confirmRemove = false
    @State private var confirmForceStop = false
    @State private var name = ""
    @State private var argumentsText = ""
    @State private var environment: [String: String] = [:]

    private var running: Bool { model.isRunning(app, in: bottle) }
    private var processes: [WineProcessInfo] { model.processes(of: app, in: bottle) }
    private var recipe: AppRecipe? { model.recipe(for: app) }
    private var isDirty: Bool {
        name != app.name || ArgumentList.split(argumentsText) != app.arguments || environment != app.environment
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                if let engine = model.engine(for: bottle), !engine.isComplete {
                    Label("Der Engine dieser Bottle fehlen Bibliotheken. Unter „Engines & Komponenten“ nachladen.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }

                performanceBox

                if running {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(processes) { process in
                                ProcessRow(process: process)
                            }
                            Button("Sofort beenden …", role: .destructive) { confirmForceStop = true }
                                .controlSize(.small)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                    } label: {
                        HStack {
                            Text("Läuft")
                            UsageText(usage: model.usage(of: processes))
                        }
                    }
                }

                if recipe?.id == "steam" {
                    SteamGamesSection(bottle: bottle, steam: app)
                }

                if app.steamAppID != nil {
                    Label("Steam-Spiel: startet über Steam in der Bottle „\(bottle.name)“. Läuft Steam noch nicht, startet es mit.", systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                }

                if let issues = recipe?.knownIssues, !issues.isEmpty {
                    DisclosureGroup("Bekannte Probleme & Lösungen", isExpanded: $showIssues) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(issues, id: \.self) { issue in
                                Label(issue, systemImage: "exclamationmark.circle")
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 6)
                    }
                }

                GroupBox("Log") {
                    LogPanel(
                        logs: model.logs(for: app),
                        preferred: model.lastLog[app.id.uuidString]
                    )
                    .padding(6)
                }

                DisclosureGroup("Erweitert", isExpanded: $showAdvanced) {
                    advanced.padding(.top, 8)
                }
            }
            .padding(24)
        }
        .navigationTitle(app.name)
        .toolbar {
            ToolbarItemGroup {
                Button {
                    selection = .bottle(bottle.id)
                } label: {
                    Label("Bottle", systemImage: "wineglass")
                }
                .help("Bottle „\(bottle.name)“ öffnen")

                if let url = WindowsPath.unixURL(for: app.iconExecutable ?? app.executable, prefix: bottle.url) {
                    Button {
                        model.reveal(url)
                    } label: {
                        Label("Im Finder zeigen", systemImage: "folder")
                    }
                    .help("Programmdatei im Finder zeigen")
                }
            }
        }
        .onAppear(perform: loadFields)
        .onChange(of: app) { loadFields() }
        .confirmationDialog("„\(app.name)“ sofort beenden?", isPresented: $confirmForceStop) {
            Button("Sofort beenden", role: .destructive) { Task { await model.forceStop(app, in: bottle) } }
        } message: {
            Text("Das Programm bekommt keine Gelegenheit zu speichern. Nur nutzen, wenn „Beenden“ nicht reagiert.")
        }
        .confirmationDialog("„\(app.name)“ aus „Meine Apps“ entfernen?", isPresented: $confirmRemove) {
            Button("Entfernen", role: .destructive) {
                selection = .myApps
                model.remove(app, from: bottle)
            }
        } message: {
            Text("Nur der Eintrag verschwindet. Das Programm bleibt in der Bottle „\(bottle.name)“ installiert. Zum vollständigen Deinstallieren die Bottle löschen.")
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            AppIconView(app: app, size: 72)
            VStack(alignment: .leading, spacing: 6) {
                Text(app.name).font(.largeTitle.bold())
                HStack(spacing: 8) {
                    StatusBadge(running: running)
                    Text("Bottle: \(bottle.name)").foregroundStyle(.secondary)
                    if let recipe {
                        Text("· aus dem Katalog (\(recipe.name))").foregroundStyle(.secondary)
                    }
                }
                Text(app.executable + (app.arguments.isEmpty ? "" : " " + ArgumentList.join(app.arguments)))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            AppStartStopButtons(bottle: bottle, app: app)
                .controlSize(.large)
        }
    }

    /// FPS-Overlay (Meilenstein 5).
    private var performanceBox: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                Picker("FPS-Overlay anzeigen", selection: Binding(
                    get: { app.performanceHUD },
                    set: { hud in
                        var updated = app
                        updated.performanceHUD = hud
                        model.update(updated, in: bottle)
                    }
                )) {
                    ForEach(PerformanceHUD.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 480)
                Text(hudExplanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        } label: {
            Label("Leistung", systemImage: "speedometer")
        }
    }

    private var hudExplanation: String {
        var text: String
        switch app.performanceHUD {
        case .off:
            text = "Kein Overlay."
        case .metal:
            text = "Apples Metal Performance HUD (MTL_HUD_ENABLED=1) zeigt FPS, Frame-Zeiten und GPU-Speicher – funktioniert mit DXMT und DXVK."
        case .dxvk:
            text = "DXVKs eigenes Overlay (DXVK_HUD) – nur sichtbar in Programmen, die über DXVK laufen."
        }
        text += " Wirkt beim nächsten Start."
        if recipe?.id == "steam" || app.steamAppID != nil {
            text += " Bei Steam gilt das Overlay für alles, was Steam startet – Steam dafür ganz beenden und neu starten."
        }
        return text
    }

    private var advanced: some View {
        VStack(alignment: .leading, spacing: 14) {
            Form {
                TextField("Name", text: $name)
                TextField("Argumente", text: $argumentsText, prompt: Text("z. B. -silent"))
                LabeledContent("Startargumente der Bottle") {
                    Text(bottle.settings.launchArguments.isEmpty ? "keine" : ArgumentList.join(bottle.settings.launchArguments))
                        .foregroundStyle(.secondary)
                }
                Section("Umgebungsvariablen dieser App") {
                    EnvironmentEditor(environment: $environment)
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("Aus „Meine Apps“ entfernen …", role: .destructive) { confirmRemove = true }
                Spacer()
                Button("Zurücksetzen") { loadFields() }
                    .disabled(!isDirty)
                Button("Speichern") { saveFields() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isDirty || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func loadFields() {
        name = app.name
        argumentsText = ArgumentList.join(app.arguments)
        environment = app.environment
    }

    private func saveFields() {
        var updated = app
        updated.name = name.trimmingCharacters(in: .whitespaces)
        updated.arguments = ArgumentList.split(argumentsText)
        updated.environment = environment
        model.update(updated, in: bottle)
    }
}

/// Ein laufender Prozess mit CPU, Speicher und „Beenden“.
struct ProcessRow: View {
    @Environment(AppModel.self) private var model
    let process: WineProcessInfo

    var body: some View {
        HStack {
            Image(systemName: "circle.fill")
                .font(.system(size: 7))
                .foregroundStyle(process.isSystemProcess ? Color.secondary : Color.green)
            Text(process.displayName)
            Text("PID \(process.pid) · CPU \(Int((model.cpuPercent[process.pid] ?? 0).rounded())) % · \(Int64(process.residentBytes).formatted(.byteCount(style: .memory)))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer()
            Button("Beenden") { model.terminate(process) }
                .controlSize(.small)
                .help("Diesen Prozess beenden (SIGTERM)")
        }
    }
}
