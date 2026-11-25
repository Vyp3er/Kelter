import SwiftUI
import WineKit

/// Startseite: Rezepte als Kacheln mit Suchfeld, wie ein kleiner App Store.
struct CatalogView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""

    private var filtered: [AppRecipe] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return model.recipes.recipes }
        return model.recipes.recipes.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.summary.localizedCaseInsensitiveContains(query)
                || ($0.publisher ?? "").localizedCaseInsensitiveContains(query)
                || ($0.category ?? "").localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Katalog").font(.largeTitle.bold())
                    Text("Jede App bekommt ihre eigene Bottle. Kelter lädt nur die offiziellen Installer der Anbieter.")
                        .foregroundStyle(.secondary)
                }

                if !model.isReady {
                    Label {
                        Text("Zuerst unter „Einrichtung“ Rosetta und eine Wine-Engine installieren.")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                    }
                    .foregroundStyle(.orange)
                }

                ForEach(model.recipes.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "doc.badge.exclamationmark")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }

                if filtered.isEmpty {
                    ContentUnavailableView.search(text: search)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 230, maximum: 320), spacing: 16)], spacing: 16) {
                        ForEach(filtered) { recipe in
                            Button {
                                model.selection = .recipe(recipe.id)
                            } label: {
                                RecipeTile(recipe: recipe)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                HStack(spacing: 12) {
                    Text("Eigene Rezepte: JSON-Datei in den Catalog-Ordner legen (Vorlagen unter „Mitgeliefert“).")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("Catalog-Ordner öffnen") { model.open(model.paths.catalog) }
                    Button("Neu laden") { model.reloadRecipes() }
                }
                .padding(.top, 8)
            }
            .padding(28)
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Katalog durchsuchen")
        .navigationTitle("Katalog")
    }
}

/// Kachel eines Rezepts.
struct RecipeTile: View {
    @Environment(AppModel.self) private var model
    let recipe: AppRecipe
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                RecipeIcon(recipe: recipe, size: 52)
                Spacer()
                status
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(recipe.name).font(.headline)
                Text(recipe.publisher ?? recipe.category ?? "").font(.caption).foregroundStyle(.secondary)
            }
            Text(recipe.summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2, reservesSpace: true)
            if let phase = model.recipeInstalls[recipe.id] {
                if let fraction = phase.fraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(hovering ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.08)))
        .scaleEffect(hovering ? 1.01 : 1)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
        .contentShape(RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder
    private var status: some View {
        if model.recipeInstalls[recipe.id] != nil {
            Badge(text: "wird installiert", color: .blue)
        } else if let ref = model.installedApp(for: recipe) {
            Badge(text: model.isRunning(ref.app, in: ref.bottle) ? "läuft" : "installiert", color: .green)
        } else if recipe.isExperimental {
            Badge(text: "experimentell", color: .orange)
        }
    }
}

/// Icon eines Rezepts: nach der Installation das echte Programm-Icon, vorher ein Symbol in der Rezeptfarbe.
struct RecipeIcon: View {
    @Environment(AppModel.self) private var model
    let recipe: AppRecipe
    var size: CGFloat = 52

    var body: some View {
        if let ref = model.installedApp(for: recipe), model.icons[ref.app.id] != nil {
            AppIconView(app: ref.app, size: size)
        } else {
            RoundedRectangle(cornerRadius: size * 0.22)
                .fill(Color(hex: recipe.tint) ?? .accentColor)
                .frame(width: size, height: size)
                .overlay {
                    Image(systemName: recipe.symbol ?? "app.fill")
                        .font(.system(size: size * 0.45, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
        }
    }
}

extension Color {
    /// `#RRGGBB` → Farbe.
    init?(hex: String?) {
        guard var text = hex?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
