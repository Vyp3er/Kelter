import SwiftUI

/// Bearbeitet Umgebungsvariablen als Liste aus Name und Wert.
struct EnvironmentEditor: View {
    @Binding var environment: [String: String]

    private struct Row: Identifiable, Equatable {
        let id = UUID()
        var key: String
        var value: String
    }

    @State private var rows: [Row] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if rows.isEmpty {
                Text("Keine eigenen Variablen.").foregroundStyle(.secondary)
            }
            ForEach($rows) { $row in
                HStack {
                    TextField("NAME", text: $row.key)
                        .font(.body.monospaced())
                        .frame(maxWidth: 220)
                    Text("=").foregroundStyle(.secondary)
                    TextField("Wert", text: $row.value)
                        .font(.body.monospaced())
                    Button {
                        rows.removeAll { $0.id == row.id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Variable entfernen")
                }
            }
            Button {
                rows.append(Row(key: "", value: ""))
            } label: {
                Label("Variable hinzufügen", systemImage: "plus")
            }
            .buttonStyle(.borderless)
            if rows.contains(where: { $0.key.contains("=") || $0.key.contains(" ") }) {
                Text("Namen dürfen kein „=“ und keine Leerzeichen enthalten.")
                    .font(.caption).foregroundStyle(.red)
            }
        }
        .onAppear(perform: load)
        .onChange(of: environment) { if dictionary(from: rows) != environment { load() } }
        .onChange(of: rows) { environment = dictionary(from: rows) }
    }

    private func load() {
        rows = environment.sorted { $0.key < $1.key }.map { Row(key: $0.key, value: $0.value) }
    }

    private func dictionary(from rows: [Row]) -> [String: String] {
        var result: [String: String] = [:]
        for row in rows {
            let key = row.key.trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !key.contains("="), !key.contains(" ") else { continue }
            result[key] = row.value
        }
        return result
    }
}
