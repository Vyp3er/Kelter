import Foundation

/// Schritt einer laufenden Installation, für die Fortschrittsanzeige.
public enum InstallPhase: Sendable, Equatable {
    case downloading(received: Int64, expected: Int64)
    case verifying
    case extracting
    case finishing

    /// 0…1 während des Downloads, sonst nil (unbestimmter Fortschritt).
    public var fraction: Double? {
        guard case let .downloading(received, expected) = self, expected > 0 else { return nil }
        return min(1, Double(received) / Double(expected))
    }

    public var label: String {
        switch self {
        case let .downloading(received, expected):
            let format = { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
            return expected > 0 ? "Lade … \(format(received)) von \(format(expected))" : "Lade … \(format(received))"
        case .verifying: return "Prüfe Prüfsumme …"
        case .extracting: return "Entpacke …"
        case .finishing: return "Richte ein …"
        }
    }
}

/// Lädt eine Komponente herunter, prüft sie, entpackt sie nach `Engines/<id>/files`
/// und entfernt das Quarantäne-Attribut.
public struct ComponentInstaller: Sendable {
    public let paths: KelterPaths
    private let downloader: FileDownloader

    public init(paths: KelterPaths, downloader: FileDownloader = FileDownloader()) {
        self.paths = paths
        self.downloader = downloader
    }

    @concurrent
    public func install(
        _ source: ComponentSource,
        progress: @escaping @Sendable (InstallPhase) -> Void
    ) async throws -> InstalledComponent {
        let fileManager = FileManager.default
        try paths.createDirectories()

        // Platz für Archiv + entpackten Inhalt (Wine wird beim Entpacken etwa dreimal so groß).
        if let size = source.sizeBytes, let available = paths.availableDiskSpace(), available < size * 5 {
            throw KelterError.notEnoughDiskSpace(needed: size * 5, available: available)
        }

        let fileName = source.url.lastPathComponent.isEmpty ? "\(source.id).archive" : source.url.lastPathComponent
        let archive = paths.downloads.appending(path: fileName)
        let staging = paths.downloads.appending(path: "entpacken-\(source.id)-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        defer {
            try? fileManager.removeItem(at: staging)
            try? fileManager.removeItem(at: archive)
        }

        // 1. Laden
        progress(.downloading(received: 0, expected: source.sizeBytes ?? 0))
        _ = try await downloader.download(from: source.url, to: archive) { received, expected in
            progress(.downloading(received: received, expected: expected > 0 ? expected : (source.sizeBytes ?? 0)))
        }
        try Task.checkCancellation()

        // 2. Prüfen
        var verifiedHash: String?
        if let expected = source.sha256.map(Checksum.normalize), !expected.isEmpty {
            progress(.verifying)
            let actual = try Checksum.sha256(of: archive)
            guard actual == expected else { throw KelterError.checksumMismatch(expected: expected, actual: actual) }
            verifiedHash = actual
        }
        try Task.checkCancellation()

        // 3. Entpacken (bsdtar kann .tar, .tar.gz und .tar.xz)
        progress(.extracting)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        // Mit `extract` nur ausgewählte Ordner entpacken (z. B. ohne Apples D3DMetal aus der Sikarugir-Vorlage).
        let tar = try await Command.run(
            URL(fileURLWithPath: "/usr/bin/tar"),
            ["-xf", archive.path, "-C", staging.path] + (source.extract ?? [])
        )
        guard tar.succeeded else { throw KelterError.extractionFailed(tar.output) }

        let contentRoot: URL
        switch source.kind {
        case .wine:
            guard let root = WineLayout.findWineRoot(in: staging) else { throw KelterError.wineNotFoundInArchive }
            contentRoot = root
        case .runtime:
            guard let root = RuntimeLibraries.findRoot(in: staging) else {
                throw KelterError.extractionFailed("Im Archiv fehlt der Ordner „Frameworks“ mit den Bibliotheken.")
            }
            contentRoot = root
        case .dxmt, .dxvk, .moltenvk:
            contentRoot = ComponentLayout.singleTopLevelDirectory(in: staging) ?? staging
        }

        // 4. An den endgültigen Ort verschieben
        progress(.finishing)
        let store = ComponentStore(paths: paths)
        let destination = store.directory(for: source.id)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        try fileManager.moveItem(at: contentRoot, to: store.filesDirectory(for: source.id))

        // Gatekeeper blockiert Dateien mit Quarantäne-Attribut. URLSession setzt es normalerweise
        // nicht, aber sicher ist sicher (z. B. bei Archiven, die schon markierte Dateien enthalten).
        _ = try? await Command.run(URL(fileURLWithPath: "/usr/bin/xattr"), ["-dr", "com.apple.quarantine", destination.path])

        var detectedVersion: String?
        if source.kind == .wine {
            detectedVersion = await WineLayout.detectVersion(root: store.filesDirectory(for: source.id))
        }

        let installed = InstalledComponent(
            id: source.id,
            kind: source.kind,
            name: source.name,
            version: source.version,
            detectedVersion: detectedVersion,
            sourceURL: source.url,
            sha256: verifiedHash,
            installedAt: .now,
            features: source.features ?? [],
            requires: source.requires
        )
        try store.save(installed)
        return installed
    }
}
