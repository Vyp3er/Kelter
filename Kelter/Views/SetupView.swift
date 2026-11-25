import SwiftUI
import WineKit

/// Erste Schritte: Rosetta → Engine → Test-Bottle.
struct SetupView: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: SidebarItem?
    @Binding var showNewBottle: Bool
    @State private var confirmRosetta = false
    @State private var creatingTestBottle = false

    private static let lowDiskThreshold: Int64 = 30_000_000_000

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Einrichtung")
                        .font(.largeTitle.bold())
                    Text("Kelter startet Windows-Programme über Wine – ohne virtuelle Maschine. Dafür braucht es Rosetta 2 und eine Wine-Engine.")
                        .foregroundStyle(.secondary)
                }

                if let free = model.freeDiskSpace, free < Self.lowDiskThreshold {
                    Label {
                        Text("Nur noch \(free.formatted(.byteCount(style: .file))) frei. Steam und Spiele brauchen schnell 10–50 GB.")
                    } icon: {
                        Image(systemName: "externaldrive.badge.exclamationmark")
                    }
                    .foregroundStyle(.orange)
                }

                if let warning = model.catalogWarning {
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }

                rosettaStep
                engineStep
                bottleStep
            }
            .padding(28)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Einrichtung")
        .confirmationDialog("Rosetta 2 installieren?", isPresented: $confirmRosetta) {
            Button("Installieren") { Task { await model.installRosetta(asAdministrator: false) } }
            Button("Mit Administratorrechten installieren") { Task { await model.installRosetta(asAdministrator: true) } }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Kelter führt dafür „softwareupdate --install-rosetta --agree-to-license“ aus. Damit stimmst du Apples Lizenzbedingungen für Rosetta 2 zu. Falls macOS Administratorrechte verlangt, wähle die zweite Option – dann fragt macOS nach deinem Passwort.")
        }
    }

    // MARK: Schritt 1

    private var rosettaStep: some View {
        StepCard(number: 1, title: "Rosetta 2", done: model.rosettaReady) {
            switch model.rosetta {
            case .checking:
                HStack { ProgressView().controlSize(.small); Text("Wird geprüft …") }
            case .notNeeded:
                Text("Dieser Mac hat einen Intel-Prozessor, Rosetta wird nicht gebraucht.")
            case .installed:
                Text("Installiert. Wine (ein x86_64-Programm) kann laufen.")
            case .missing:
                Text("Wine ist ein Intel-Programm und braucht Rosetta 2, um auf Apple Silicon zu laufen.")
                Button("Rosetta 2 installieren …") { confirmRosetta = true }
                    .buttonStyle(.borderedProminent)
            case .installing:
                HStack { ProgressView().controlSize(.small); Text("Rosetta wird installiert …") }
            case let .failed(message):
                Text(message).foregroundStyle(.red).textSelection(.enabled)
                HStack {
                    Button("Erneut versuchen …") { confirmRosetta = true }
                    Button("Neu prüfen") { Task { await model.checkRosetta() } }
                }
            }
        }
    }

    // MARK: Schritt 2

    private var engineStep: some View {
        StepCard(number: 2, title: "Wine-Engine", done: model.defaultEngine.map { $0.isComplete && model.engineProblem($0.id) == nil } ?? false) {
            if let engine = model.defaultEngine {
                Text("Standard-Engine: **\(engine.name)**")
                if let version = engine.component.detectedVersion {
                    Text(version).font(.callout.monospaced()).foregroundStyle(.secondary)
                }
                if let problem = model.engineProblem(engine.id) {
                    Label(problem, systemImage: "exclamationmark.octagon.fill")
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    replacementEngine(for: engine)
                } else if !engine.isComplete {
                    let pending = engine.missingRequirements.compactMap { model.installs[$0] }.first
                    if let pending, let id = engine.missingRequirements.first {
                        InstallProgressView(phase: pending) { model.cancelInstall(id) }
                    } else {
                        Label("Es fehlen benötigte Bibliotheken – ohne sie fehlen Schriften und HTTPS.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Button("Fehlende Bibliotheken laden") { model.installMissingRequirements(of: engine) }
                            .buttonStyle(.borderedProminent)
                    }
                }
                Button("Engines verwalten …") { selection = .components }
            } else if let source = model.catalog.recommendedEngine {
                Text("Empfohlen: **\(source.name)**")
                Text(source.summary).foregroundStyle(.secondary)
                let plan = model.installPlan(for: source)
                if let active = plan.first(where: { model.installs[$0.id] != nil }), let phase = model.installs[active.id] {
                    Text(active.name).font(.callout)
                    InstallProgressView(phase: phase) { model.cancelInstall(active.id) }
                } else {
                    if plan.count > 1 {
                        Text("Dazu wird automatisch geladen: \(plan.dropLast().map(\.name).joined(separator: ", ")).")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Button("Laden und installieren (\(model.downloadSize(for: source).formatted(.byteCount(style: .file))))") {
                            model.install(source)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.rosettaReady)
                        Button("Andere Engine wählen …") { selection = .components }
                    }
                }
            } else {
                Text("Keine Download-Quelle für Wine gefunden.")
            }
        }
    }

    /// Ersatz für eine Engine, die auf diesem Mac nicht läuft: die empfohlene laden (wird automatisch Standard).
    @ViewBuilder
    private func replacementEngine(for engine: WineEngine) -> some View {
        if let replacement = model.catalog.recommendedEngine, replacement.id != engine.id, replacement.isCompatible() {
            let plan = model.installPlan(for: replacement)
            if let active = plan.first(where: { model.installs[$0.id] != nil }), let phase = model.installs[active.id] {
                Text(active.name).font(.callout)
                InstallProgressView(phase: phase) { model.cancelInstall(active.id) }
            } else if model.installedComponent(id: replacement.id) == nil {
                Text("Empfohlen: **\(replacement.name)**. \(replacement.summary)")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("\(replacement.name) laden (\(model.downloadSize(for: replacement).formatted(.byteCount(style: .file))))") {
                    model.install(replacement)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.rosettaReady)
            }
        }
    }

    // MARK: Schritt 3

    private var testBottle: Bottle? {
        model.bottles.first { $0.id == "Test" }
    }

    private var bottleStep: some View {
        StepCard(number: 3, title: "Test-Bottle", done: testBottle?.isInitialized == true) {
            Text("Eine Bottle ist ein eigenes kleines Windows mit Laufwerk C: und Registry. Zum Ausprobieren legst du eine Bottle „Test“ an und startest darin winecfg und Notepad. Danach geht's in den Katalog, z. B. für Steam.")
                .foregroundStyle(.secondary)
            if let bottle = testBottle {
                HStack {
                    Button("Test-Bottle öffnen") { selection = .bottle(bottle.id) }
                    Button("Zum Katalog") { selection = .catalog }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                HStack {
                    Button {
                        creatingTestBottle = true
                        Task {
                            if let id = await model.createBottle(name: "Test", engineID: nil) {
                                selection = .bottle(id)
                            }
                            creatingTestBottle = false
                        }
                    } label: {
                        if creatingTestBottle {
                            HStack { ProgressView().controlSize(.small); Text("Wird angelegt …") }
                        } else {
                            Text("Test-Bottle anlegen")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.isReady || creatingTestBottle)
                    Button("Eigene Bottle …") { showNewBottle = true }
                        .disabled(!model.isReady)
                }
            }
        }
    }
}

/// Karte für einen Einrichtungsschritt.
struct StepCard<Content: View>: View {
    let number: Int
    let title: String
    let done: Bool
    @ViewBuilder var content: Content

    var body: some View {
        GroupBox {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    Circle()
                        .fill(done ? Color.green : Color.accentColor.opacity(0.15))
                        .frame(width: 30, height: 30)
                    if done {
                        Image(systemName: "checkmark").font(.headline).foregroundStyle(.white)
                    } else {
                        Text("\(number)").font(.headline).foregroundStyle(Color.accentColor)
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(title).font(.title3.bold())
                    content
                }
                Spacer(minLength: 0)
            }
            .padding(8)
        }
    }
}
