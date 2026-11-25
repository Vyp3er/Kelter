import SwiftUI
import WineKit

/// Engine-Manager: Wine-Engines und Grafik-Komponenten laden, löschen, Standard wählen.
struct ComponentsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            ForEach(ComponentKind.allCases.filter { kind in
                !model.catalog.components(of: kind).isEmpty || model.installed.contains { $0.kind == kind }
            }, id: \.self) { kind in
                Section {
                    ForEach(model.catalog.components(of: kind)) { source in
                        ComponentRow(source: source)
                    }
                    // Installierte Komponenten, deren Quelle nicht (mehr) im Katalog steht.
                    ForEach(model.installed.filter { $0.kind == kind && model.catalog.source(id: $0.id) == nil }) { component in
                        OrphanComponentRow(component: component)
                    }
                } header: {
                    Text(kind.displayName)
                } footer: {
                    switch kind {
                    case .runtime:
                        Text("Wird automatisch mit der Engine geladen, die sie braucht. Aus der Sikarugir-Vorlage entpackt Kelter nur Bibliotheken und DXMT/DXVK – Apples D3DMetal nicht.")
                    case .dxmt, .dxvk, .moltenvk:
                        Text("Welches Backend eine Bottle nutzt, stellst du in der Bottle unter „Erweitert“ ein. Katalog-Rezepte laden benötigte Komponenten automatisch.")
                    case .wine:
                        EmptyView()
                    }
                }
            }
            Section {
                Text("Eigene Quellen: Lege `Catalog/components.json` im Kelter-Ordner an (Aufbau wie `components.default.json`). Einträge mit gleicher `id` ersetzen die mitgelieferten.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Catalog-Ordner im Finder zeigen") { model.open(model.paths.catalog) }
            }
        }
        .navigationTitle("Engines & Komponenten")
    }
}

private struct ComponentRow: View {
    @Environment(AppModel.self) private var model
    let source: ComponentSource
    @State private var confirmDelete = false

    private var installed: InstalledComponent? { model.installedComponent(id: source.id) }
    private var isDefault: Bool { model.settings.defaultEngineID == source.id }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(source.name).font(.headline)
                    if source.isRecommended { Badge(text: "Empfohlen", color: .blue) }
                    if source.problem() != nil { Badge(text: "läuft hier nicht", color: .red) }
                    if isDefault { Badge(text: "Standard", color: .green) }
                    ForEach(source.features ?? [], id: \.self) { Badge(text: $0, color: .secondary) }
                }
                Text(source.summary).font(.callout).foregroundStyle(.secondary)
                if let problem = source.problem() {
                    Label(problem, systemImage: "exclamationmark.octagon.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let requires = source.requires, !requires.isEmpty {
                    let names = requires.map { model.catalog.source(id: $0)?.name ?? $0 }
                    let missing = requires.filter { model.installedComponent(id: $0) == nil }
                    Label(
                        "Benötigt: \(names.joined(separator: ", "))\(installed != nil && !missing.isEmpty ? " – fehlt noch!" : "")",
                        systemImage: missing.isEmpty || installed == nil ? "link" : "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(installed != nil && !missing.isEmpty ? .orange : .secondary)
                }
                if source.kind == .runtime, installed != nil {
                    Text(runtimeContents)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    if let installed {
                        Text("Installiert: \(installed.detectedVersion ?? installed.version)")
                    } else if let size = source.sizeBytes {
                        Text(size.formatted(.byteCount(style: .file)))
                    }
                    if source.sha256 == nil {
                        Label("ohne Prüfsumme", systemImage: "exclamationmark.shield")
                            .help("Die Quelle nennt keine SHA-256-Prüfsumme. Die Datei wird ungeprüft installiert.")
                    }
                    if let license = source.license { Text(license) }
                    if let homepage = source.homepage {
                        Link("Quelle", destination: homepage)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if let phase = model.installs[source.id] {
                    InstallProgressView(phase: phase) { model.cancelInstall(source.id) }
                        .padding(.top, 4)
                }
            }
            Spacer()
            if model.installs[source.id] == nil {
                actions
            }
        }
        .padding(.vertical, 4)
        .confirmationDialog("„\(source.name)“ löschen?", isPresented: $confirmDelete) {
            Button("Löschen", role: .destructive) {
                if let installed { model.remove(installed) }
            }
        } message: {
            Text(deleteMessage)
        }
    }

    @ViewBuilder
    private var actions: some View {
        if let installed {
            HStack {
                if source.kind == .wine, !isDefault, source.isCompatible() {
                    Button("Als Standard") { model.setDefaultEngine(source.id) }
                }
                if let requires = source.requires, requires.contains(where: { model.installedComponent(id: $0) == nil }) {
                    Button("Fehlendes laden") { model.install(source) }
                }
                Menu {
                    Button("Im Finder zeigen") { model.reveal(model.folder(of: installed)) }
                    Button("Neu installieren") { model.install(source) }
                    Divider()
                    Button("Löschen …", role: .destructive) { confirmDelete = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        } else {
            Button(source.isCompatible() ? "Laden" : "Trotzdem laden") { model.install(source) }
                .disabled(source.kind == .wine && !model.rosettaReady)
                .help("Lädt \(model.downloadSize(for: source).formatted(.byteCount(style: .file))) (inkl. benötigter Komponenten)")
        }
    }

    /// Was in den Laufzeit-Bibliotheken steckt (Versionen aus den `version`-Dateien).
    private var runtimeContents: String {
        let runtime = RuntimeLibraries(root: model.folder(of: installed!).appending(path: "files"))
        var parts: [String] = []
        for (name, folder) in [("DXMT", "dxmt"), ("DXVK", "dxvk"), ("DXVK 3 (KosmicKrisp)", "dxvk3")] {
            if let wine = runtime.renderer(folder) {
                parts.append("\(name) \(GraphicsLayout.version(near: wine) ?? "")".trimmingCharacters(in: .whitespaces))
            }
        }
        if runtime.moltenVKDriver != nil { parts.append("MoltenVK") }
        return parts.isEmpty ? "" : "Enthält: " + parts.joined(separator: " · ")
    }

    private var deleteMessage: String {
        var message = "Die Dateien werden endgültig gelöscht. Du kannst die Komponente jederzeit neu laden."
        let users = model.bottlesUsing(source.id)
        if source.kind == .wine, !users.isEmpty {
            message += "\n\nDiese Bottles nutzen die Engine: \(users.map(\.name).joined(separator: ", ")). Sie starten erst wieder, wenn eine andere Engine gewählt oder diese neu geladen ist."
        }
        let engines = model.enginesRequiring(source.id)
        if !engines.isEmpty {
            message += "\n\nDiese Engines brauchen die Komponente und starten ohne sie nicht mehr: \(engines.map(\.name).joined(separator: ", "))."
        }
        return message
    }
}

private struct OrphanComponentRow: View {
    @Environment(AppModel.self) private var model
    let component: InstalledComponent

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(component.name).font(.headline)
                Text("Installiert, aber nicht mehr im Katalog: \(component.detectedVersion ?? component.version)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if component.kind == .wine, model.settings.defaultEngineID != component.id {
                Button("Als Standard") { model.setDefaultEngine(component.id) }
            }
            Button("Löschen", role: .destructive) { model.remove(component) }
        }
    }
}

/// Fortschritt einer Installation mit Abbrechen-Knopf.
struct InstallProgressView: View {
    let phase: InstallPhase
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                if let fraction = phase.fraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
                Text(phase.label).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            .frame(maxWidth: 320)
            Button("Abbrechen", action: cancel)
                .controlSize(.small)
                .disabled(phase == .finishing)
        }
    }
}

struct Badge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}
