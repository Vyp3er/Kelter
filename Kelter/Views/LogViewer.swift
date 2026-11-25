import AppKit
import SwiftUI
import WineKit

/// Log-Verlauf: Auswahl eines früheren Logs plus Anzeige.
struct LogPanel: View {
    /// Logs, neueste zuerst.
    let logs: [URL]
    /// Wird bevorzugt angezeigt (z. B. das gerade gestartete Log).
    var preferred: URL?
    @State private var selected: URL?

    private var shown: URL? { selected ?? preferred ?? logs.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if logs.count > 1 {
                Picker("Log", selection: Binding(get: { shown }, set: { selected = $0 })) {
                    ForEach(logs, id: \.self) { url in
                        Text(Self.title(for: url)).tag(Optional(url))
                    }
                }
                .frame(maxWidth: 360)
            }
            LogViewer(url: shown)
        }
        .onChange(of: preferred) { selected = nil }
    }

    /// „Steam-2026-11-25_14-03-12.log“ → „25.11.2026, 14:03:12“
    static func title(for url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent
        guard let range = name.range(of: #"\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}"#, options: .regularExpression) else { return name }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        guard let date = formatter.date(from: String(name[range])) else { return name }
        return date.formatted(date: .numeric, time: .standard)
    }
}

/// Zeigt eine Logdatei an und liest sie jede Sekunde neu, solange die Ansicht sichtbar ist.
/// Darüber stehen Hinweise des ``LogAnalyzer`` (Anti-Cheat, fehlende DLLs, Abstürze).
struct LogViewer: View {
    let url: URL?
    @State private var text = ""
    @State private var findings: [LogFinding] = []
    @State private var copied = false

    /// Große Logs nur am Ende anzeigen, damit die Oberfläche flüssig bleibt.
    private static let maxBytes = 256 * 1024

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(findings) { finding in
                FindingView(finding: finding)
            }

            HStack {
                Text(url?.lastPathComponent ?? "Noch kein Log – starte ein Programm.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(copied ? "Kopiert" : "Log kopieren") { copy() }
                    .disabled(text.isEmpty)
                Button("Im Finder zeigen") {
                    if let url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
                .disabled(url == nil)
            }
            .controlSize(.small)

            ScrollView {
                Text(text.isEmpty ? " " : text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .defaultScrollAnchor(.bottom)
            .frame(minHeight: 200, maxHeight: 360)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
        }
        .task(id: url) {
            text = ""
            findings = []
            while !Task.isCancelled {
                reload()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func reload() {
        guard let url, let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(Self.maxBytes) ? size - UInt64(Self.maxBytes) : 0
        try? handle.seek(toOffset: start)
        let data = (try? handle.readToEnd()) ?? Data()
        var newText = String(decoding: data, as: UTF8.self)
        if start > 0 { newText = "… (Anfang gekürzt, vollständiges Log im Finder)\n" + newText }
        guard newText != text else { return }
        text = newText
        findings = LogAnalyzer.analyze(newText)
    }

    /// Kopiert das vollständige Log, nicht nur den angezeigten Ausschnitt.
    private func copy() {
        guard let url, let full = try? String(contentsOf: url, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(full, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}

private struct FindingView: View {
    let finding: LogFinding

    private var style: (icon: String, color: Color) {
        switch finding.kind {
        case .antiCheat: ("shield.slash", .red)
        case .crash: ("exclamationmark.octagon", .red)
        case .missingLibrary: ("puzzlepiece.extension", .orange)
        case .setup: ("wrench.and.screwdriver", .orange)
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: style.icon).foregroundStyle(style.color).font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(finding.title).font(.callout.bold())
                Text(finding.detail).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(style.color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}
