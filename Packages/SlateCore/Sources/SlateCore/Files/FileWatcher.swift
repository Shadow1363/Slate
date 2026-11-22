import CoreServices
import Foundation

/// Reports changes made to a project folder by anything: Finder, VS Code,
/// git, iCloud Drive or Slate itself.
///
/// Two sources feed one stream:
/// - an FSEvents stream on the root (sees every write, including ones that
///   bypass file coordination, like `git checkout` or most editors), and
/// - an `NSFilePresenter` on the root (sees coordinated writes, such as
///   iCloud downloads, and lets Slate's own writes skip notifying itself).
///
/// Each element of `events` is a batch of paths relative to the root. An
/// empty string in a batch means "something changed; rescan everything".
public final class FileWatcher: @unchecked Sendable {
    public let rootURL: URL
    public let events: AsyncStream<Set<String>>

    /// Pass this to `CoordinatedFileIO` so coordinated writes by Slate
    /// aren't reported back through the presenter.
    public var filePresenter: any NSFilePresenter { presenter }

    private let rootPath: String
    private let ignoredTopLevel: Set<String>
    private let latency: TimeInterval
    private let continuation: AsyncStream<Set<String>>.Continuation
    private let queue = DispatchQueue(label: "app.slate.filewatcher")
    private let queueKey = DispatchSpecificKey<Bool>()
    private let presenter: RootPresenter

    // Guarded by `queue`.
    private var stream: FSEventStreamRef?
    private var isRunning = false

    public init(rootURL: URL, latency: TimeInterval = 0.15, ignoring ignoredTopLevel: Set<String> = [ProjectLayout.cache]) {
        self.rootURL = rootURL
        self.rootPath = canonicalPath(rootURL)
        self.ignoredTopLevel = ignoredTopLevel
        self.latency = latency
        let (events, continuation) = AsyncStream<Set<String>>.makeStream(bufferingPolicy: .unbounded)
        self.events = events
        self.continuation = continuation
        self.presenter = RootPresenter(url: rootURL)
        queue.setSpecific(key: queueKey, value: true)
        presenter.onChange = { [weak self] url in
            guard let self else { return }
            let path = canonicalPath(url)
            self.queue.async { [weak self] in self?.emit([path]) }
        }
    }

    deinit {
        stop()
    }

    public func start() {
        onQueue {
            guard !isRunning else { return }
            isRunning = true
            startStream()
        }
        NSFileCoordinator.addFilePresenter(presenter)
    }

    /// Stops watching and finishes `events`. A stopped watcher can't restart.
    public func stop() {
        let wasRunning = onQueue { () -> Bool in
            let wasRunning = isRunning
            isRunning = false
            if let stream {
                FSEventStreamStop(stream)
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
                self.stream = nil
            }
            return wasRunning
        }
        if wasRunning {
            NSFileCoordinator.removeFilePresenter(presenter)
        }
        continuation.finish()
    }

    /// Runs `body` on `queue`, directly if already there (deinit can run on
    /// the queue when a callback drops the last reference).
    private func onQueue<T>(_ body: () -> T) -> T {
        if DispatchQueue.getSpecific(key: queueKey) == true { return body() }
        return queue.sync(execute: body)
    }

    // MARK: - FSEvents

    private func startStream() {
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            let array = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as NSArray
            var batch: [String] = []
            for index in 0..<count {
                let flag = flags[index]
                if flag & UInt32(kFSEventStreamEventFlagMustScanSubDirs) != 0
                    || flag & UInt32(kFSEventStreamEventFlagRootChanged) != 0 {
                    batch.append("")
                } else if let path = array[index] as? String {
                    batch.append(path)
                }
            }
            watcher.emit(batch)
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot)
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [rootPath] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    /// Runs on `queue`. Converts absolute paths to relative ones and drops ignored ones.
    private func emit(_ absolutePaths: [String]) {
        guard isRunning else { return }
        var relative = Set<String>()
        for path in absolutePaths {
            if path.isEmpty {
                relative.insert("")
            } else if let rel = relativePath(path) {
                relative.insert(rel)
            }
        }
        if !relative.isEmpty {
            continuation.yield(relative)
        }
    }

    func relativePath(_ absolute: String) -> String? {
        let rel: String
        if absolute == rootPath {
            rel = ""
        } else if absolute.hasPrefix(rootPath + "/") {
            rel = String(absolute.dropFirst(rootPath.count + 1))
        } else {
            return nil
        }
        if let first = rel.split(separator: "/").first, ignoredTopLevel.contains(String(first)) {
            return nil
        }
        let name = (rel as NSString).lastPathComponent
        if name == ".DS_Store" || name.hasPrefix(".dat.nosync") {
            return nil
        }
        return rel
    }
}

/// Presents the project root so coordinated writes inside it are reported.
private final class RootPresenter: NSObject, NSFilePresenter, @unchecked Sendable {
    let presentedItemURL: URL?
    let presentedItemOperationQueue: OperationQueue
    /// Set once, before the presenter is registered.
    var onChange: (@Sendable (URL) -> Void)?

    init(url: URL) {
        presentedItemURL = url
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "app.slate.filepresenter"
        presentedItemOperationQueue = queue
    }

    func presentedSubitemDidChange(at url: URL) {
        onChange?(url)
    }

    func presentedSubitem(at oldURL: URL, didMoveTo newURL: URL) {
        onChange?(oldURL)
        onChange?(newURL)
    }

    func accommodatePresentedSubitemDeletion(at url: URL, completionHandler: @escaping @Sendable ((any Error)?) -> Void) {
        onChange?(url)
        completionHandler(nil)
    }
}
