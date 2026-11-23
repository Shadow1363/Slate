import Foundation

/// The whisper.cpp models Slate offers, downloaded from Hugging Face on demand.
public enum WhisperModel: String, CaseIterable, Identifiable, Sendable {
    case baseEnglish = "base.en"
    case base
    case smallEnglish = "small.en"
    case small
    case largeTurbo = "large-v3-turbo-q5_0"

    public static let defaultModel = WhisperModel.base

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .baseEnglish: "Base, English only"
        case .base: "Base, any language"
        case .smallEnglish: "Small, English only"
        case .small: "Small, any language"
        case .largeTurbo: "Large Turbo, any language"
        }
    }

    /// Roughly how big the download is, for the picker.
    public var sizeDescription: String {
        switch self {
        case .baseEnglish, .base: "142 MB"
        case .smallEnglish, .small: "466 MB"
        case .largeTurbo: "547 MB"
        }
    }

    public var fileName: String { "ggml-\(rawValue).bin" }

    public var downloadURL: URL {
        URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(fileName)")!
    }

    public var isEnglishOnly: Bool { rawValue.hasSuffix(".en") }

    /// `~/Library/Application Support/Slate/Whisper`.
    public static var folder: URL {
        folderOverride ?? URL.applicationSupportDirectory.appending(path: "Slate/Whisper", directoryHint: .isDirectory)
    }

    /// Tests install into a temporary folder instead.
    nonisolated(unsafe) static var folderOverride: URL?

    public var localURL: URL { Self.folder.appending(path: fileName) }

    public var isDownloaded: Bool { FileManager.default.fileExists(atPath: localURL.path) }
}

/// Something Settings › Voice can download for Whisper.
public enum WhisperDownload: Equatable, Sendable {
    case engine
    case model(WhisperModel)
}

/// Downloads the Whisper engine or a model, reporting progress. One at a time.
@MainActor
@Observable
public final class WhisperModelDownloads {
    public private(set) var downloading: WhisperDownload?
    public private(set) var progress: Double = 0
    public private(set) var lastError: String?
    /// Bumped when something appears or disappears, so views re-read `isDownloaded` / `isInstalled`.
    public private(set) var revision = 0

    private var task: Task<Void, Never>?

    public init() {}

    public func download(_ item: WhisperDownload) {
        guard downloading == nil else { return }
        downloading = item
        progress = 0
        lastError = nil
        task = Task {
            do {
                switch item {
                case .engine:
                    let zip = try await fetch(WhisperEngine.downloadURL)
                    defer { try? FileManager.default.removeItem(at: zip) }
                    try FileManager.default.createDirectory(at: WhisperModel.folder, withIntermediateDirectories: true)
                    try await Task.detached(priority: .userInitiated) { try WhisperEngine.install(zip: zip) }.value
                case .model(let model):
                    let file = try await fetch(model.downloadURL)
                    defer { try? FileManager.default.removeItem(at: file) }
                    try FileManager.default.createDirectory(at: WhisperModel.folder, withIntermediateDirectories: true)
                    try? FileManager.default.removeItem(at: model.localURL)
                    try FileManager.default.moveItem(at: file, to: model.localURL)
                }
                progress = 1
            } catch is CancellationError {
            } catch {
                lastError = error.localizedDescription
            }
            downloading = nil
            revision += 1
        }
    }

    public func cancel() {
        task?.cancel()
    }

    public func delete(_ model: WhisperModel) {
        try? FileManager.default.removeItem(at: model.localURL)
        revision += 1
    }

    public func uninstallEngine() {
        WhisperEngine.uninstall()
        revision += 1
    }

    /// Downloads to a temporary file and returns it.
    private func fetch(_ url: URL) async throws -> URL {
        let delegate = DownloadDelegate { [weak self] fraction in
            Task { @MainActor in self?.progress = fraction }
        }
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: url)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.finish = { continuation.resume(with: $0) }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }
}

/// Reports a download's progress and hands over the finished file.
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let onProgress: @Sendable (Double) -> Void
    /// Called once, with the file moved somewhere it survives the callback.
    var finish: ((Result<URL, any Error>) -> Void)?
    private var finished = false
    private let lock = NSLock()

    init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    private func complete(_ result: Result<URL, any Error>) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        finish?(result)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            complete(.failure(VoiceError.whisperFailed("the download failed (HTTP \(status))")))
            return
        }
        let kept = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".bin")
        do {
            try FileManager.default.moveItem(at: location, to: kept)
            complete(.success(kept))
        } catch {
            complete(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error {
            complete(.failure((error as? URLError)?.code == .cancelled ? CancellationError() : error))
        }
    }
}
