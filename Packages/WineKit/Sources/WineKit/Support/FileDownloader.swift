import Foundation

/// Lädt große Dateien mit Fortschrittsanzeige herunter (URLSession-Download-Task).
public final class FileDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    public typealias ProgressHandler = @Sendable (_ received: Int64, _ expected: Int64) -> Void

    private struct Pending {
        let destination: URL
        let progress: ProgressHandler
        let continuation: CheckedContinuation<URL, Error>
        var lastReport = Date.distantPast
        var movedFile: URL?
        var failure: Error?
    }

    private let lock = NSLock()
    private var pending: [Int: Pending] = [:]
    private var session: URLSession!

    public override init() {
        super.init()
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 60 * 60 * 3
        configuration.waitsForConnectivity = true
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    /// Lädt `url` nach `destination` (eine vorhandene Datei wird ersetzt).
    public func download(from url: URL, to destination: URL, progress: @escaping ProgressHandler) async throws -> URL {
        let taskBox = DownloadTaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.downloadTask(with: url)
                lock.withLock {
                    pending[task.taskIdentifier] = Pending(destination: destination, progress: progress, continuation: continuation)
                }
                taskBox.set(task)
                task.resume()
            }
        } onCancel: {
            taskBox.cancel()
        }
    }

    // MARK: URLSessionDownloadDelegate

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        // Höchstens ~7 Meldungen pro Sekunde, damit die Oberfläche nicht geflutet wird.
        let handler: ProgressHandler? = lock.withLock {
            guard var entry = pending[downloadTask.taskIdentifier] else { return nil }
            let now = Date()
            guard now.timeIntervalSince(entry.lastReport) >= 0.15 || totalBytesWritten == totalBytesExpectedToWrite else { return nil }
            entry.lastReport = now
            pending[downloadTask.taskIdentifier] = entry
            return entry.progress
        }
        handler?(totalBytesWritten, totalBytesExpectedToWrite)
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let id = downloadTask.taskIdentifier
        guard let destination = lock.withLock({ pending[id]?.destination }) else { return }
        // Die temporäre Datei existiert nur bis zum Ende dieser Methode, also sofort verschieben.
        do {
            if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw KelterError.httpStatus(http.statusCode, downloadTask.originalRequest?.url)
            }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            lock.withLock { pending[id]?.movedFile = destination }
        } catch {
            lock.withLock { pending[id]?.failure = error }
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let entry = lock.withLock({ pending.removeValue(forKey: task.taskIdentifier) }) else { return }
        if let error {
            let cancelled = (error as? URLError)?.code == .cancelled
            entry.continuation.resume(throwing: cancelled ? CancellationError() : error)
        } else if let failure = entry.failure {
            entry.continuation.resume(throwing: failure)
        } else if let file = entry.movedFile {
            entry.continuation.resume(returning: file)
        } else {
            entry.continuation.resume(throwing: KelterError.downloadFailed)
        }
    }
}

/// Merkt sich den Download-Task, damit ein Abbruch ihn auch dann erreicht,
/// wenn er eintrifft, bevor der Task gestartet wurde.
private final class DownloadTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var cancelled = false

    func set(_ task: URLSessionTask) {
        let alreadyCancelled = lock.withLock {
            self.task = task
            return cancelled
        }
        if alreadyCancelled { task.cancel() }
    }

    func cancel() {
        let task = lock.withLock {
            cancelled = true
            return self.task
        }
        task?.cancel()
    }
}
