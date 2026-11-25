import SwiftUI
import WineKit

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: $model.selection) {
                Section("Kelter") {
                    Label("Katalog", systemImage: "square.grid.3x3.fill")
                        .tag(SidebarItem.catalog)
                    Label("Meine Apps", systemImage: "square.grid.2x2")
                        .badge(model.allApps.filter { model.isRunning($0.app, in: $0.bottle) }.count)
                        .tag(SidebarItem.myApps)
                    Label("Controller", systemImage: "gamecontroller")
                        .tag(SidebarItem.controllers)
                }
                Section("Bottles") {
                    ForEach(model.bottles) { bottle in
                        BottleSidebarRow(bottle: bottle)
                            .tag(SidebarItem.bottle(bottle.id))
                    }
                    if model.bottles.isEmpty {
                        Text("Noch keine Bottle")
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Einstellungen") {
                    Label("Einrichtung", systemImage: "checklist")
                        .tag(SidebarItem.setup)
                    Label("Engines & Komponenten", systemImage: "shippingbox")
                        .tag(SidebarItem.components)
                }
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 235)
            .safeAreaInset(edge: .bottom) { DiskSpaceFooter() }
            .toolbar {
                ToolbarItem {
                    Button {
                        model.showNewBottle = true
                    } label: {
                        Label("Neue Bottle", systemImage: "plus")
                    }
                    .help("Leere Bottle anlegen (⌘N)")
                    .disabled(!model.isReady)
                }
            }
        } detail: {
            detail
        }
        .task { await model.start() }
        .sheet(isPresented: $model.showNewBottle) {
            NewBottleSheet { id in model.selection = .bottle(id) }
        }
        .alert(
            "Hoppla",
            isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } }),
            presenting: model.errorMessage
        ) { _ in
            Button("OK") { model.errorMessage = nil }
        } message: { message in
            Text(message)
        }
    }

    @ViewBuilder
    private var detail: some View {
        @Bindable var model = model
        switch model.selection {
        case .catalog:
            CatalogView()
        case let .recipe(id):
            if let recipe = model.recipes.recipe(id: id) {
                RecipeDetailView(recipe: recipe)
            } else {
                ContentUnavailableView("Rezept nicht gefunden", systemImage: "questionmark.square.dashed")
            }
        case .myApps:
            MyAppsView(selection: $model.selection)
        case let .app(id):
            if let ref = model.app(id: id) {
                AppDetailView(bottle: ref.bottle, app: ref.app, selection: $model.selection)
            } else {
                ContentUnavailableView("App nicht gefunden", systemImage: "app.dashed")
            }
        case .controllers:
            ControllerView()
        case .setup, nil:
            SetupView(selection: $model.selection, showNewBottle: $model.showNewBottle)
        case .components:
            ComponentsView()
        case let .bottle(id):
            if let bottle = model.bottle(id: id) {
                BottleDetailView(bottle: bottle, selection: $model.selection)
            } else {
                ContentUnavailableView("Bottle nicht gefunden", systemImage: "wineglass")
            }
        }
    }
}

private struct BottleSidebarRow: View {
    @Environment(AppModel.self) private var model
    let bottle: Bottle

    var body: some View {
        HStack {
            Label(bottle.name, systemImage: "wineglass")
            Spacer()
            if model.bottleActivity[bottle.id] != nil {
                ProgressView().controlSize(.small)
            } else {
                RunStateDot(state: model.runState(of: bottle))
            }
        }
    }
}

/// Freier Speicher unten in der Seitenleiste – der Mac ist knapp bemessen.
private struct DiskSpaceFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let free = model.freeDiskSpace {
            Label("\(free.formatted(.byteCount(style: .file))) frei", systemImage: "internaldrive")
                .font(.caption)
                .foregroundStyle(free < 15_000_000_000 ? Color.orange : Color.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
        }
    }
}

/// Grüner Punkt = läuft, grauer Ring = nur Wine-Hintergrunddienste.
struct RunStateDot: View {
    let state: AppModel.BottleRunState

    var body: some View {
        switch state {
        case .stopped:
            EmptyView()
        case .background:
            Image(systemName: "circle")
                .font(.system(size: 7))
                .foregroundStyle(.secondary)
                .help("Nur Wine-Hintergrunddienste aktiv")
        case let .running(count):
            Image(systemName: "circle.fill")
                .font(.system(size: 7))
                .foregroundStyle(.green)
                .help("\(count) Programm(e) laufen")
        }
    }
}
