import AppKit
import Observation
import Security
import SlateCore
import SwiftUI

public enum UpdatePreferences {
    /// Check GitHub for a newer Slate when Slate opens (the only time Slate goes online).
    public static let checkAtLaunch = "update.checkAtLaunch"
    /// Download a new version in the background, then offer Restart to Update.
    public static let downloadAutomatically = "update.downloadAutomatically"
    /// Offer beta versions (on while Slate itself is a beta).
    public static let includeBetas = "update.includeBetas"
    public static let skippedTag = "update.skippedTag"
    public static let lastCheck = "update.lastCheck"
}

/// Checks GitHub Releases for a newer Slate, downloads it, and swaps it in on restart.
///
/// The repository comes from `SlateUpdateRepository` in Info.plist (`owner/repo`).
/// Updating: the zip is downloaded and unpacked into a temporary folder and its
/// bundle ID checked; on Restart to Update, open projects are saved, Slate quits, and a
/// small script replaces the app and opens the new one.
@MainActor
@Observable
public final class Updater {
    public enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(AppRelease)
        case downloading(AppRelease, progress: Double)
        case ready(AppRelease, app: URL)
        case failed(String)
    }

    public private(set) var state: State = .idle
    /// Saves every open project before Slate quits to update.
    @ObservationIgnored public var saveAll: () -> Void = {}
    @ObservationIgnored private var task: Task<Void, Never>?

    public init() {
        UserDefaults.standard.register(defaults: [
            UpdatePreferences.checkAtLaunch: true,
            UpdatePreferences.downloadAutomatically: true,
            UpdatePreferences.includeBetas: true,
        ])
    }

    public static var repository: String? {
        (Bundle.main.object(forInfoDictionaryKey: "SlateUpdateRepository") as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// `0.9.0-beta.12`: the marketing version plus the build number, as releases are tagged.
    public static var currentVersion: AppVersion {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "0"
        let build = info["CFBundleVersion"] as? String ?? "0"
        return AppVersion("\(short)-beta.\(build)") ?? AppVersion("0")!
    }

    public var currentVersion: AppVersion { Self.currentVersion }

    /// At launch: a quiet check (nothing shows unless there's an update).
    public func checkAtLaunch() {
        guard Bundle.main.bundleURL.pathExtension == "app",
              UserDefaults.standard.bool(forKey: UpdatePreferences.checkAtLaunch) else { return }
        check(userInitiated: false)
    }

    /// Slate › Check for Updates…
    public func check(userInitiated: Bool) {
        guard task == nil else { return }
        guard let repository = Self.repository, let url = ReleaseFeed.url(repository: repository) else {
            if userInitiated { state = .failed("This copy of Slate doesn't know where its updates come from.") }
            return
        }
        state = .checking
        task = Task {
            defer { task = nil }
            do {
                var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                request.setValue("Slate-Updater", forHTTPHeaderField: "User-Agent")
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    throw UpdateError.message("GitHub didn't answer (\((response as? HTTPURLResponse)?.statusCode ?? 0)).")
                }
                UserDefaults.standard.set(Date(), forKey: UpdatePreferences.lastCheck)
                let skipped = userInitiated ? nil : UserDefaults.standard.string(forKey: UpdatePreferences.skippedTag)
                guard let release = try ReleaseFeed.update(from: data, current: currentVersion,
                                                           includePrereleases: UserDefaults.standard.bool(forKey: UpdatePreferences.includeBetas),
                                                           skipping: skipped) else {
                    state = userInitiated ? .upToDate : .idle
                    return
                }
                state = .available(release)
                if UserDefaults.standard.bool(forKey: UpdatePreferences.downloadAutomatically) || userInitiated {
                    await download(release)
                }
            } catch {
                state = userInitiated ? .failed(error.localizedDescription) : .idle
            }
        }
    }

    public func download(_ release: AppRelease) async {
        state = .downloading(release, progress: 0)
        do {
            let staging = FileManager.default.temporaryDirectory.appending(path: "SlateUpdate-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            let zip = staging.appending(path: release.download.lastPathComponent)
            let (bytes, response) = try await URLSession.shared.bytes(from: release.download)
            let total = max(Int(response.expectedContentLength), release.size, 1)
            FileManager.default.createFile(atPath: zip.path, contents: nil)
            let handle = try FileHandle(forWritingTo: zip)
            var buffer = Data()
            var written = 0
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count >= 256 * 1024 {
                    try handle.write(contentsOf: buffer)
                    written += buffer.count
                    buffer.removeAll(keepingCapacity: true)
                    state = .downloading(release, progress: Double(written) / Double(total))
                }
            }
            try handle.write(contentsOf: buffer)
            try handle.close()
            let app = try await Self.unpack(zip, into: staging)
            state = .ready(release, app: app)
        } catch {
            state = .failed("Couldn't download \(release.version): \(error.localizedDescription)")
        }
    }

    /// Unzips with `ditto` and checks it's Slate.
    static func unpack(_ zip: URL, into folder: URL) async throws -> URL {
        let out = folder.appending(path: "unpacked", directoryHint: .isDirectory)
        try await run("/usr/bin/ditto", ["-x", "-k", zip.path, out.path])
        guard let app = try FileManager.default.contentsOfDirectory(at: out, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" }),
            let bundle = Bundle(url: app), bundle.bundleIdentifier == Bundle.main.bundleIdentifier ?? "app.slate.mac"
        else { throw UpdateError.message("The download isn't a copy of Slate.") }
        try await run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        // A Developer ID copy only accepts an update signed by the same team.
        if let team = teamID(of: Bundle.main.bundleURL), teamID(of: app) != team {
            throw UpdateError.message("The download isn't signed by Slate's developer, so it wasn't installed.")
        }
        return app
    }

    /// The signing team of an app, or nil when it's ad-hoc signed.
    static func teamID(of app: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any] else { return nil }
        return dictionary[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// Where the running app can be replaced, or why not.
    public static var installProblem: String? {
        let path = Bundle.main.bundleURL.path
        if path.contains("/AppTranslocation/") {
            return "Move Slate to your Applications folder first (it's running from a temporary copy macOS made)."
        }
        if !FileManager.default.isWritableFile(atPath: Bundle.main.bundleURL.deletingLastPathComponent().path) {
            return "Slate can't replace itself in \(Bundle.main.bundleURL.deletingLastPathComponent().path). Move it to a folder you can write to, such as Applications."
        }
        return nil
    }

    /// Saves, quits, swaps the app, opens the new one.
    public func restartToUpdate() {
        guard case .ready(_, let app) = state else { return }
        if let problem = Self.installProblem {
            state = .failed(problem)
            return
        }
        saveAll()
        do {
            let script = app.deletingLastPathComponent().deletingLastPathComponent().appending(path: "install.sh")
            try Data(ReleaseFeed.installScript().utf8).write(to: script)
            let process = Process()
            process.executableURL = URL(filePath: "/bin/bash")
            process.arguments = [script.path, String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundleURL.path, app.path]
            try process.run()
            NSApp.terminate(nil)
        } catch {
            state = .failed("Couldn't start the update: \(error.localizedDescription)")
        }
    }

    public func skip(_ release: AppRelease) {
        UserDefaults.standard.set(release.tag, forKey: UpdatePreferences.skippedTag)
        state = .idle
    }

    public func dismiss() { state = .idle }

    private static func run(_ tool: String, _ arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(filePath: tool)
            process.arguments = arguments
            process.terminationHandler = { process in
                if process.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: UpdateError.message("\((tool as NSString).lastPathComponent) failed (\(process.terminationStatus))."))
                }
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }

    enum UpdateError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let text) = self { text } else { nil } }
    }
}

/// The banner Home and project windows show while an update is on its way or ready.
public struct UpdateBanner: View {
    @Environment(SlateAppModel.self) private var model

    public init() {}

    public var body: some View {
        let updater = model.updater
        switch updater.state {
        case .downloading(let release, let progress):
            bar {
                ProgressView(value: progress).frame(width: 120)
                Text("Downloading Slate \(release.version.description)…")
            }
        case .ready(let release, _):
            bar {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(.tint)
                Text("Slate \(release.version.description) is ready.")
                if let page = release.page { Link("What's new", destination: page) }
                Spacer()
                Button("Later") { updater.dismiss() }
                Button("Restart to Update") { updater.restartToUpdate() }
                    .buttonStyle(.borderedProminent)
            }
        case .available(let release):
            bar {
                Image(systemName: "sparkles").foregroundStyle(.tint)
                Text("Slate \(release.version.description) is available.")
                Spacer()
                Button("Skip This Version") { updater.skip(release) }
                Button("Download") { Task { await updater.download(release) } }
                    .buttonStyle(.borderedProminent)
            }
        case .failed(let message):
            bar {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(message).lineLimit(2)
                Spacer()
                Button("OK") { updater.dismiss() }
            }
        case .upToDate:
            bar {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Slate \(updater.currentVersion.description) is the newest version.")
                Spacer()
                Button("OK") { updater.dismiss() }
            }
        case .checking:
            bar {
                ProgressView().controlSize(.small)
                Text("Checking for updates…")
            }
        case .idle:
            EmptyView()
        }
    }

    private func bar<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 10) { content() }
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }
    }
}

/// Settings › General › Updates.
struct UpdateSettings: View {
    @Environment(SlateAppModel.self) private var model
    @AppStorage(UpdatePreferences.checkAtLaunch) private var checkAtLaunch = true
    @AppStorage(UpdatePreferences.downloadAutomatically) private var downloadAutomatically = true
    @AppStorage(UpdatePreferences.includeBetas) private var includeBetas = true

    var body: some View {
        Section("Updates") {
            Toggle("Check for updates when Slate opens", isOn: $checkAtLaunch)
            Toggle("Download updates automatically", isOn: $downloadAutomatically)
                .disabled(!checkAtLaunch)
            Toggle("Include beta versions", isOn: $includeBetas)
            LabeledContent("This version") {
                HStack {
                    Text(Updater.currentVersion.description).monospacedDigit()
                    Button("Check Now") { model.updater.check(userInitiated: true) }
                }
            }
            Text("Checking asks GitHub for Slate's newest release. It's the only time Slate goes online, and it sends nothing about you or your projects.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
