import SwiftUI
import UniformTypeIdentifiers
import WineKit

/// Eine Bottle: Apps darin, laufende Programme, Log. Technisches steckt unter „Erweitert“.
struct BottleDetailView: View {
    @Environment(AppModel.self) private var model
    let bottle: Bottle
    @Binding var selection: SidebarItem?

    @State private var confirmTrash = false
    @State private var pickExecutable = false
    @State private var showAdvanced = false
    @State private var showSystemProcesses = false

    private var engine: WineEngine? { model.engine(for: bottle) }
    private var activity: String? { model.bottleActivity[bottle.id] }
    private var apps: [InstalledApp] { model.apps(in: bottle) }
    private var canRun: Bool { engine?.isComplete == true && bottle.isInitialized && activity == nil }
    private var processes: [WineProcessInfo] {
        model.processes(in: bottle).filter { showSystemProcesses || !$0.isSystemProcess }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                warnings

                GroupBox("Apps in dieser Bottle") {
                    VStack(alignment: .leading, spacing: 8) {
                        if apps.isEmpty {
                            Text("Noch keine App. Trage eine .exe ein, die schon in dieser Bottle liegt – zum Test z. B. C:\\windows\\system32\\winemine.exe (Minesweeper).")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(apps) { app in
                            AppRow(bottle: bottle, app: app)
                                .contentShape(Rectangle())
                                .onTapGesture { selection = .app(app.id) }
                            if app.id != apps.last?.id { Divider() }
                        }
                        Button {
                            pickExecutable = true
                        } label: {
                            Label("App hinzufügen …", systemImage: "plus")
                        }
                        .disabled(!bottle.isInitialized)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        if processes.isEmpty {
                            Text(model.runState(of: bottle) == .background
                                 ? "Keine Programme – nur Wines Hintergrunddienste laufen noch (beenden sich nach ein paar Sekunden von selbst)."
                                 : "Keine – alles beendet.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(processes) { process in
                            ProcessRow(process: process)
                        }
                        Toggle("Wine-Hintergrunddienste zeigen", isOn: $showSystemProcesses)
                            .toggleStyle(.checkbox)
                            .controlSize(.small)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                } label: {
                    Text("Laufende Programme")
                }

                GroupBox("Log") {
                    LogViewer(url: model.lastLog[bottle.id])
                        .padding(6)
                }

                DisclosureGroup("Erweitert", isExpanded: $showAdvanced) {
                    VStack(alignment: .leading, spacing: 16) {
                        BottleSettingsForm(bottle: bottle)
                        GroupBox("Wine-Werkzeuge") {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 10)], alignment: .leading, spacing: 10) {
                                ForEach(AppModel.BuiltinProgram.allCases) { program in
                                    Button {
                                        model.launch(program, in: bottle)
                                    } label: {
                                        Label(program.title, systemImage: program.systemImage)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                            }
                            .disabled(!canRun)
                            .padding(6)
                        }
                    }
                    .padding(.top, 8)
                }
            }
            .padding(24)
        }
        .navigationTitle(bottle.name)
        .toolbar {
            ToolbarItemGroup {
                Menu {
                    ForEach(AppModel.BuiltinProgram.allCases) { program in
                        Button(program.title) { model.launch(program, in: bottle) }
                    }
                } label: {
                    Label("Wine-Werkzeuge", systemImage: "wrench.and.screwdriver")
                }
                .help("Wine-Werkzeuge in dieser Bottle starten")
                .disabled(!canRun)

                Button {
                    Task { await model.killAll(in: bottle) }
                } label: {
                    Label("Alles beenden", systemImage: "stop.circle")
                }
                .help("Alle Windows-Programme dieser Bottle beenden (wineserver -k)")
                .disabled(engine == nil)

                Button {
                    model.open(bottle.url)
                } label: {
                    Label("Im Finder öffnen", systemImage: "folder")
                }
                .help("Bottle-Ordner im Finder öffnen")

                Button(role: .destructive) {
                    confirmTrash = true
                } label: {
                    Label("Löschen", systemImage: "trash")
                }
                .help("Bottle in den Papierkorb legen")
            }
        }
        .fileImporter(isPresented: $pickExecutable, allowedContentTypes: [UTType(filenameExtension: "exe") ?? .data]) { result in
            if case let .success(url) = result, let id = model.addApp(executable: url, to: bottle) {
                selection = .app(id)
            }
        }
        .fileDialogDefaultDirectory(bottle.driveC)
        .confirmationDialog("„\(bottle.name)“ löschen?", isPresented: $confirmTrash) {
            Button("In den Papierkorb legen", role: .destructive) {
                selection = .myApps
                Task { await model.moveToTrash(bottle) }
            }
        } message: {
            Text("Die Bottle mit allen installierten Programmen, Spielständen und ihren Einträgen in „Meine Apps“ wird in den Papierkorb gelegt. Laufende Programme werden vorher beendet. Bis du den Papierkorb leerst, kannst du sie zurücklegen.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(bottle.name).font(.largeTitle.bold())
                switch model.runState(of: bottle) {
                case .running:
                    Badge(text: "läuft", color: .green)
                    UsageText(usage: model.usage(of: model.processes(in: bottle)))
                case .background: Badge(text: "Hintergrund", color: .secondary)
                case .stopped: if bottle.isInitialized { Badge(text: "beendet", color: .secondary) }
                }
            }
            if let engine {
                Text("Engine: \(engine.name)\(bottle.settings.engineID == nil ? " (Standard)" : "") · \(bottle.settings.windowsVersion.displayName)")
                    .foregroundStyle(.secondary)
            } else {
                Label("Keine passende Engine installiert", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            Text(bottle.url.path)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private var warnings: some View {
        if let engine, let problem = model.engineProblem(engine.id) {
            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Die Engine „\(engine.name)“ läuft auf diesem Mac nicht.", systemImage: "exclamationmark.octagon.fill")
                        .foregroundStyle(.red)
                    Text(problem).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("Zur Einrichtung") { selection = .setup }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }
        }
        if let engine, !engine.isComplete {
            GroupBox {
                HStack {
                    Label("Der Engine fehlen benötigte Bibliotheken.", systemImage: "exclamationmark.triangle")
                    Spacer()
                    Button("Fehlendes laden") { model.installMissingRequirements(of: engine) }
                        .disabled(engine.missingRequirements.contains { model.installs[$0] != nil })
                }
                .padding(4)
            }
        }

        if let activity {
            HStack { ProgressView().controlSize(.small); Text(activity) }
        } else if !bottle.isInitialized {
            GroupBox {
                HStack {
                    Label(bottle.hasIncompleteSetup
                          ? "Das Einrichten ist beim letzten Mal gescheitert. Ein neuer Versuch beginnt von vorn."
                          : "Die Bottle ist noch nicht eingerichtet.",
                          systemImage: "exclamationmark.triangle")
                    Spacer()
                    Button(bottle.hasIncompleteSetup ? "Neu einrichten" : "Jetzt einrichten") { Task { await model.initialize(bottle) } }
                        .disabled(engine?.isComplete != true || engine.flatMap { model.engineProblem($0.id) } != nil)
                }
                .padding(4)
            }
        }
    }
}
