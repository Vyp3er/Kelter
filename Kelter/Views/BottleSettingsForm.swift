import SwiftUI
import WineKit

/// Der „Erweitert“-Bereich einer Bottle: alles, was in `kelter-bottle.json` steht.
struct BottleSettingsForm: View {
    @Environment(AppModel.self) private var model
    let bottle: Bottle

    @State private var draft = BottleSettings(name: "")
    @State private var argumentsText = ""
    @State private var newException = ""
    @State private var saving = false

    private var normalizedDraft: BottleSettings {
        var settings = draft
        settings.name = settings.name.trimmingCharacters(in: .whitespaces)
        settings.launchArguments = ArgumentList.split(argumentsText)
        return settings
    }

    private var isDirty: Bool { normalizedDraft.userFacing != bottle.settings.userFacing }

    /// Möglich ist pro Programm nur der „Gegenspieler“ des Bottle-Backends.
    private var exceptionBackend: GraphicsBackend { draft.graphicsBackend == .dxvk ? .wined3d : .dxvk }

    private static let debugPresets: [(title: String, value: String)] = [
        ("Standard (Fehler zeigen)", "fixme-all"),
        ("Stumm", "-all"),
        ("DLL-Ladevorgänge", "fixme-all,+loaddll"),
        ("Grafik (D3D)", "fixme-all,+d3d,+dxgi"),
        ("Controller", "fixme-all,+dinput,+hid,+xinput")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Form {
                Section("Allgemein") {
                    TextField("Anzeigename", text: $draft.name)
                    Picker("Engine", selection: $draft.engineID) {
                        Text("Standard (\(model.defaultEngine?.name ?? "keine"))").tag(String?.none)
                        ForEach(model.installedEngines) { engine in
                            Text(engine.name).tag(Optional(engine.id))
                        }
                    }
                    Picker("Windows-Version", selection: $draft.windowsVersion) {
                        ForEach(WindowsVersion.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                }

                Section {
                    Picker("Grafik-Backend", selection: $draft.graphicsBackend) {
                        ForEach(GraphicsBackend.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    Picker("Synchronisierung", selection: $draft.syncMode) {
                        ForEach(SyncMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    if let plan = model.plannedLaunch(for: bottle) {
                        LabeledContent("Aktuell umgesetzt") {
                            Text(plan.summary).foregroundStyle(.secondary)
                        }
                        ForEach(plan.notes, id: \.self) { note in
                            Label(note, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        }
                    }
                } header: {
                    Text("Grafik & Leistung")
                } footer: {
                    Text(graphicsFooter).foregroundStyle(.secondary)
                }

                Section {
                    ForEach(draft.executableBackends.keys.sorted(), id: \.self) { exe in
                        HStack {
                            Text(exe).font(.body.monospaced())
                            Spacer()
                            Text("→ \(draft.executableBackends[exe]?.displayName ?? "")").foregroundStyle(.secondary)
                            if draft.executableBackends[exe] != exceptionBackend {
                                Image(systemName: "exclamationmark.triangle")
                                    .foregroundStyle(.orange)
                                    .help("In einer \(draft.graphicsBackend.displayName)-Bottle nicht möglich – wird übersprungen.")
                            }
                            Button {
                                draft.executableBackends[exe] = nil
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    HStack {
                        TextField("Programm, z. B. steamwebhelper.exe", text: $newException)
                            .font(.body.monospaced())
                            .onSubmit(addException)
                        Button("→ \(exceptionBackend.displayName)", action: addException)
                            .disabled(!newException.lowercased().hasSuffix(".exe"))
                    }
                } header: {
                    Text("Ausnahmen pro Programm")
                } footer: {
                    Text("Einzelne Programme mit einem anderen Grafik-Backend starten. Beispiel: Steams Oberfläche (steamwebhelper.exe) bleibt unter DXMT schwarz und läuft deshalb über DXVK. In einer \(draft.graphicsBackend.displayName)-Bottle ist als Ausnahme nur \(exceptionBackend.displayName) möglich.")
                        .foregroundStyle(.secondary)
                }

                Section {
                    Picker("Controller-Modus", selection: $draft.controllerMode) {
                        ForEach(ControllerMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    Text(draft.controllerMode.explanation).font(.caption).foregroundStyle(.secondary)
                    Toggle("Controller auch im Hintergrund", isOn: $draft.controllerBackgroundInput)
                    Button("Joystick-Einstellungen der Bottle öffnen") { model.launch(.joystick, in: bottle) }
                        .disabled(!bottle.isInitialized || model.engine(for: bottle)?.isComplete != true)
                } header: {
                    Text("Controller")
                } footer: {
                    Text("Ob macOS deinen Controller sieht, zeigt der Bereich „Controller“ in der Seitenleiste. Die Joystick-Einstellungen zeigen, was Windows-Spiele in dieser Bottle sehen.")
                        .foregroundStyle(.secondary)
                }

                Section {
                    TextField("Startargumente", text: $argumentsText, prompt: Text("werden jeder App dieser Bottle angehängt"))
                    HStack {
                        TextField("WINEDEBUG", text: $draft.wineDebug)
                            .font(.body.monospaced())
                        Menu("Vorlagen") {
                            ForEach(Self.debugPresets, id: \.value) { preset in
                                Button(preset.title) { draft.wineDebug = preset.value }
                            }
                        }
                        .fixedSize()
                    }
                } header: {
                    Text("Start")
                } footer: {
                    Text("WINEDEBUG steuert, was Wine ins Log schreibt. Mehr Kanäle = längere Logs und etwas langsamer.")
                        .foregroundStyle(.secondary)
                }

                Section("Umgebungsvariablen (für alle Apps dieser Bottle)") {
                    EnvironmentEditor(environment: $draft.environment)
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("Einstellungsdatei im Finder zeigen") { model.reveal(bottle.settingsFile) }
                Spacer()
                Button("Zurücksetzen") { load() }
                    .disabled(!isDirty || saving)
                Button {
                    let settings = normalizedDraft
                    saving = true
                    Task {
                        await model.update(bottle, settings: settings)
                        saving = false
                    }
                } label: {
                    if saving { ProgressView().controlSize(.small) } else { Text("Speichern") }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isDirty || saving || draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .onAppear(perform: load)
        .onChange(of: bottle.settings) { load() }
    }

    private var graphicsFooter: String {
        var text = "DXMT übersetzt Direct3D 10/11 direkt nach Metal (am schnellsten). DXVK geht über Vulkan und MoltenVK und kann auch Direct3D 9. WineD3D ist langsam, aber am verträglichsten."
        if model.engine(for: bottle)?.supportsMsync == true {
            text += " msync wird von dieser Engine unterstützt."
        }
        text += " Änderungen greifen beim nächsten Start – laufende Programme werden beim Wechsel des Backends beendet."
        return text
    }

    private func addException() {
        let exe = newException.trimmingCharacters(in: .whitespaces)
        guard exe.lowercased().hasSuffix(".exe") else { return }
        draft.executableBackends[exe] = exceptionBackend
        newException = ""
    }

    private func load() {
        draft = bottle.settings
        argumentsText = ArgumentList.join(bottle.settings.launchArguments)
    }
}
