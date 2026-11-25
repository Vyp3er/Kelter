import SwiftUI
import WineKit

/// Ein Rezept: was installiert wird, bekannte Probleme, 1-Klick-Installation mit Fortschritt.
struct RecipeDetailView: View {
    @Environment(AppModel.self) private var model
    let recipe: AppRecipe
    @State private var showTechnical = false

    private var installedRef: AppModel.AppRef? { model.installedApp(for: recipe) }
    private var phase: RecipeInstallPhase? { model.recipeInstalls[recipe.id] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                if let phase {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text(phase.label).font(.headline)
                                Spacer()
                                Button("Abbrechen", role: .destructive) { model.cancelRecipeInstall(recipe) }
                            }
                            if let fraction = phase.fraction {
                                ProgressView(value: fraction)
                            } else {
                                ProgressView().progressViewStyle(.linear)
                            }
                            if case .runningInstaller(true) = phase {
                                Label("Das Installer-Fenster kann hinter Kelter liegen – schau im Dock nach.", systemImage: "macwindow.on.rectangle")
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                            if let started = model.recipeInstallStarted[recipe.id] {
                                NewestLogView(since: started)
                            }
                        }
                        .padding(6)
                    }
                }

                if let description = recipe.description {
                    Text(description).fixedSize(horizontal: false, vertical: true)
                }

                GroupBox("Was beim Installieren passiert") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("\(index + 1).").monospacedDigit().foregroundStyle(.secondary)
                                Text(step)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }

                if let issues = recipe.knownIssues, !issues.isEmpty {
                    GroupBox("Bekannte Probleme") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(issues, id: \.self) { issue in
                                Label(issue, systemImage: "exclamationmark.circle")
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                    }
                }

                DisclosureGroup("Technisches", isExpanded: $showTechnical) {
                    technical.padding(.top, 6)
                }
            }
            .padding(28)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(recipe.name)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    model.selection = .catalog
                } label: {
                    Label("Katalog", systemImage: "chevron.backward")
                }
                .help("Zurück zum Katalog")
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 18) {
            RecipeIcon(recipe: recipe, size: 84)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(recipe.name).font(.largeTitle.bold())
                    if recipe.isExperimental { Badge(text: "experimentell", color: .orange) }
                }
                Text([recipe.publisher, recipe.category].compactMap { $0 }.joined(separator: " · "))
                    .foregroundStyle(.secondary)
                Text(recipe.summary)
            }
            Spacer()
            actions
        }
    }

    @ViewBuilder
    private var actions: some View {
        if let ref = installedRef {
            VStack(alignment: .trailing, spacing: 8) {
                AppStartStopButtons(bottle: ref.bottle, app: ref.app)
                    .controlSize(.large)
                Button("In „Meine Apps“ öffnen") { model.selection = .app(ref.app.id) }
            }
        } else if phase == nil {
            VStack(alignment: .trailing, spacing: 6) {
                Button {
                    model.installRecipe(recipe)
                } label: {
                    Label("Installieren", systemImage: "arrow.down.circle.fill")
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!model.isReady)
                let size = model.downloadSize(for: recipe)
                Text(size > 0 ? "ca. \(size.formatted(.byteCount(style: .file))) Download" : "Größe unbekannt")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var steps: [String] {
        var list: [String] = []
        let bottleName = recipe.name
        list.append("Eine eigene Bottle „\(bottleName)“ anlegen und einrichten (\(recipe.windowsVersion?.displayName ?? "Windows 10"), Grafik: \((recipe.graphicsBackend ?? .dxmt).displayName)).")
        for id in recipe.requiredComponents ?? [] {
            if let source = model.catalog.source(id: id) {
                list.append(model.installedComponent(id: id) == nil ? "\(source.name) laden (einmalig für alle Bottles)." : "\(source.name) verwenden (schon installiert).")
            }
        }
        for id in recipe.prerequisites ?? [] {
            if let prerequisite = model.recipes.prerequisite(id: id) {
                list.append("\(prerequisite.name) installieren – \(prerequisite.summary)")
            }
        }
        let host = recipe.installer.url.host() ?? "dem Anbieter"
        list.append("Den offiziellen Installer von \(host) laden.")
        list.append(recipe.isInteractive
            ? "Installer starten – du klickst dich selbst durch die Fenster."
            : "Installer still ausführen (ohne Rückfragen).")
        list.append("„\(recipe.name)“ unter „Meine Apps“ eintragen – mit Start-Knopf.")
        return list
    }

    private var technical: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            row("Installer", recipe.installer.url.absoluteString)
            row("Argumente", ArgumentList.join(recipe.installer.arguments ?? []).ifEmpty("keine (interaktiv)"))
            row("Start-EXE", recipe.executable)
            row("Startargumente", ArgumentList.join(recipe.arguments ?? []).ifEmpty("keine"))
            row("Grafik", (recipe.graphicsBackend ?? .dxmt).displayName)
            row("Ausnahmen", (recipe.executableBackends ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key) → \($0.value.displayName)" }.joined(separator: ", ").ifEmpty("keine"))
            row("Umgebung", (recipe.environment ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ").ifEmpty("keine"))
            row("Rezept-ID", recipe.id)
        }
        .font(.callout)
        .textSelection(.enabled)
    }

    private func row(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value).font(.callout.monospaced())
        }
    }
}

/// Zeigt während einer Installation immer das gerade aktuelle Log.
struct NewestLogView: View {
    @Environment(AppModel.self) private var model
    let since: Date
    @State private var url: URL?

    var body: some View {
        LogViewer(url: url)
            .task {
                while !Task.isCancelled {
                    let newest = model.newestLog(since: since)
                    if newest != url { url = newest }
                    try? await Task.sleep(for: .seconds(2))
                }
            }
    }
}

extension String {
    func ifEmpty(_ replacement: String) -> String { isEmpty ? replacement : self }
}
