import SwiftUI

@main
struct KelterApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("Kelter", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 940, minHeight: 620)
        }
        .defaultSize(width: 1120, height: 760)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Neue Bottle …") { model.showNewBottle = true }
                    .keyboardShortcut("n")
                    .disabled(!model.isReady)
            }
            CommandMenu("Gehe zu") {
                Button("Katalog") { model.selection = .catalog }
                    .keyboardShortcut("1")
                Button("Meine Apps") { model.selection = .myApps }
                    .keyboardShortcut("2")
                Button("Controller") { model.selection = .controllers }
                    .keyboardShortcut("3")
                Divider()
                Button("Einrichtung") { model.selection = .setup }
                    .keyboardShortcut("4")
                Button("Engines & Komponenten") { model.selection = .components }
                    .keyboardShortcut("5")
                Divider()
                Button("Kelter-Ordner im Finder zeigen") { model.open(model.paths.root) }
                Button("Logs im Finder zeigen") { model.open(model.paths.logs) }
                Button("Katalog neu laden") { model.reloadRecipes() }
                    .keyboardShortcut("r")
            }
        }
    }
}
