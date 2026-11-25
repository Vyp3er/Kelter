import SwiftUI
import WineKit

struct NewBottleSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let onCreated: (String) -> Void

    @State private var name = ""
    /// nil = Standard-Engine
    @State private var engineID: String?

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name, prompt: Text("z. B. Steam"))
                Picker("Engine", selection: $engineID) {
                    Text("Standard (\(model.defaultEngine?.name ?? "keine"))").tag(String?.none)
                    ForEach(model.installedEngines) { engine in
                        Text(engine.name).tag(Optional(engine.id))
                    }
                }
            } footer: {
                Text("Die Bottle wird unter Bottles/\((try? BottleStore.folderName(for: name)) ?? "…") angelegt und gleich mit wineboot eingerichtet.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .navigationTitle("Neue Bottle")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Abbrechen") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Anlegen") {
                    let name = name
                    let engineID = engineID
                    dismiss()
                    Task {
                        if let id = await model.createBottle(name: name, engineID: engineID) {
                            onCreated(id)
                        }
                    }
                }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}
