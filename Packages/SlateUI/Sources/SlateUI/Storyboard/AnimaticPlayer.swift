import AppKit
import AVFoundation
import AVKit
import Observation
import SlateCore
import SlateExport
import SwiftUI

/// Plays the animatic: builds the composition for a range, keeps time, and
/// rebuilds (keeping its place) when the boards or the script change.
@MainActor
@Observable
final class AnimaticPlayerModel {
    let storyboard: StoryboardModel
    let root: URL
    private(set) var range: AnimaticRange = .film
    private(set) var timeline = AnimaticTimeline()
    private(set) var currentTime: Double = 0
    private(set) var isPlaying = false
    private(set) var isBuilding = false
    /// Media the composition couldn't read.
    private(set) var missing: [String] = []
    private(set) var errorMessage: String?
    var overlays: AnimaticOverlays = AnimaticPlayerModel.savedOverlays {
        didSet { Self.save(overlays) }
    }

    @ObservationIgnored let player = AVPlayer()
    @ObservationIgnored private var observer: Any?
    @ObservationIgnored private var buildTask: Task<Void, Never>?
    @ObservationIgnored private var clipLengths: [String: Double]?
    /// Selects a frame on the board.
    @ObservationIgnored var onSelect: ((FrameRef) -> Void)?

    init(storyboard: StoryboardModel, root: URL) {
        self.storyboard = storyboard
        self.root = root
        let observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 20), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time) }
        }
        self.observer = observer
    }

    func stop() {
        player.pause()
        buildTask?.cancel()
        isPlaying = false
    }

    // MARK: Building

    /// Plays `range` from its start.
    func play(_ range: AnimaticRange, autoplay: Bool = true) {
        self.range = range
        rebuild(keepTime: false, autoplay: autoplay)
    }

    /// Rebuilds the composition from the current boards and script.
    func rebuild(keepTime: Bool, autoplay: Bool = false) {
        buildTask?.cancel()
        let keep = keepTime ? currentTime : 0
        let wasPlaying = isPlaying || autoplay
        buildTask = Task { [weak self] in
            guard let self else { return }
            if keepTime { try? await Task.sleep(for: .milliseconds(400)) }
            guard !Task.isCancelled else { return }
            await self.build(keep: keep, play: wasPlaying)
        }
    }

    private func build(keep: Double, play: Bool) async {
        isBuilding = true
        defer { isBuilding = false }
        if clipLengths == nil { clipLengths = await storyboard.loadClipLengths() }
        let timeline = storyboard.timeline(range, clipLengths: clipLengths ?? [:])
        do {
            let composed = try await AnimaticComposer.compose(timeline, root: root)
            guard !Task.isCancelled else { return }
            self.timeline = timeline
            missing = composed.missing
            errorMessage = nil
            player.pause()
            player.replaceCurrentItem(with: composed.playerItem())
            let target = min(keep, max(timeline.duration - 0.05, 0))
            await player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            currentTime = target
            if play { player.play() }
            isPlaying = play
        } catch {
            self.timeline = timeline
            player.replaceCurrentItem(with: nil)
            errorMessage = error.localizedDescription
            isPlaying = false
        }
    }

    /// Clip lengths are read again on the next build (after files change).
    func forgetClipLengths() { clipLengths = nil }

    private func tick(_ time: CMTime) {
        guard time.isNumeric else { return }
        currentTime = time.seconds
        let playing = player.rate != 0
        if playing != isPlaying { isPlaying = playing }
    }

    // MARK: Transport

    func togglePlay() {
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            if currentTime >= timeline.duration - 0.05 { seek(to: 0) }
            player.play()
            isPlaying = true
        }
    }

    func seek(to seconds: Double) {
        let clamped = min(max(seconds, 0), max(timeline.duration - 0.01, 0))
        currentTime = clamped
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// The previous or next frame (previous restarts this one if it's been playing a while).
    func stepFrame(_ delta: Int) {
        guard let index = timeline.segmentIndex(at: currentTime) else { return }
        if delta < 0, currentTime - timeline.segments[index].start > 0.5 {
            seek(to: timeline.segments[index].start)
            return
        }
        let target = min(max(index + delta, 0), timeline.segments.count - 1)
        seek(to: timeline.segments[target].start)
    }

    func stepScene(_ delta: Int) {
        let starts = timeline.sceneStarts
        guard let current = starts.lastIndex(where: { $0.start <= currentTime + 0.0001 }) else { return }
        if delta < 0, currentTime - starts[current].start > 0.5 {
            seek(to: starts[current].start)
            return
        }
        let target = min(max(current + delta, 0), starts.count - 1)
        seek(to: starts[target].start)
    }

    var currentSegment: AnimaticSegment? { timeline.segment(at: currentTime) }
    var currentCue: SubtitleCue? { timeline.cue(at: currentTime) }

    /// Selects the frame on screen in the board.
    func selectCurrentFrame() {
        guard let segment = currentSegment, let ref = storyboard.ref(for: segment) else { return }
        onSelect?(ref)
    }

    // MARK: Ranges

    /// Scenes that can be played, in order: (ID, number, heading).
    var scenes: [(id: String, number: String, heading: String)] {
        storyboard.scenes.map { ($0.scene.sceneID!, $0.label, $0.scene.heading) }
    }

    func number(of sceneID: String) -> String? { scenes.first { $0.id == sceneID }?.number }

    var rangeTitle: String {
        switch range {
        case .film: return "Whole Film"
        case .scene(let id): return "Scene \(number(of: id) ?? id)"
        case .scenes(let from, let to):
            let ids = scenes.map(\.id)
            let (a, b) = (ids.firstIndex(of: from) ?? 0) <= (ids.firstIndex(of: to) ?? 0) ? (from, to) : (to, from)
            return "Scenes \(number(of: a) ?? a)–\(number(of: b) ?? b)"
        case .fromFrame(let scene, _): return "From Scene \(number(of: scene) ?? scene)"
        }
    }

    /// The first and last scene of the current range, for the From/To menus.
    var rangeEnds: (from: String?, to: String?) {
        switch range {
        case .film: (scenes.first?.id, scenes.last?.id)
        case .scene(let id): (id, id)
        case .scenes(let from, let to): (from, to)
        case .fromFrame(let scene, _): (scene, scenes.last?.id)
        }
    }

    func setFrom(_ id: String) {
        play(.scenes(from: id, to: rangeEnds.to ?? id), autoplay: isPlaying)
    }

    func setTo(_ id: String) {
        play(.scenes(from: rangeEnds.from ?? id, to: id), autoplay: isPlaying)
    }

    /// Something that changes when the boards or the script do.
    var sourceSignature: Int {
        var hasher = Hasher()
        hasher.combine(storyboard.version)
        let book = storyboard.script.book
        hasher.combine(book.wordCount)
        hasher.combine(book.totalLines)
        for scene in book.scenes {
            hasher.combine(scene.scene.sceneID)
            hasher.combine(scene.scene.heading)
            hasher.combine(scene.duration)
        }
        return hasher.finalize()
    }

    // MARK: Saved overlay choices (per Mac, not per project)

    static var savedOverlays: AnimaticOverlays {
        let defaults = UserDefaults.standard
        func flag(_ key: String) -> Bool { defaults.object(forKey: key) as? Bool ?? true }
        return AnimaticOverlays(heading: flag("animatic.overlay.heading"), caption: flag("animatic.overlay.caption"),
                                subtitles: flag("animatic.overlay.subtitles"))
    }

    static func save(_ overlays: AnimaticOverlays) {
        let defaults = UserDefaults.standard
        defaults.set(overlays.heading, forKey: "animatic.overlay.heading")
        defaults.set(overlays.caption, forKey: "animatic.overlay.caption")
        defaults.set(overlays.subtitles, forKey: "animatic.overlay.subtitles")
    }

    static func time(_ seconds: Double) -> String {
        let total = Int(max(seconds, 0).rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Views

/// The player window's content: the picture with live overlays, then the transport bar.
struct AnimaticPlayerView: View {
    @Bindable var model: AnimaticPlayerModel
    let toggleFullScreen: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                let video = Self.videoRect(in: geometry.size)
                ZStack(alignment: .topLeading) {
                    Color.black
                    AnimaticVideoView(player: model.player)
                    AnimaticOverlayLayer(model: model)
                        .frame(width: video.width, height: video.height)
                        .offset(x: video.minX, y: video.minY)
                    if model.isBuilding && model.timeline.segments.isEmpty {
                        ProgressView().controlSize(.large).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    if let error = model.errorMessage {
                        ContentUnavailableView("Nothing to Play", systemImage: "film.stack", description: Text(error))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { toggleFullScreen() }
            .onTapGesture { model.togglePlay() }
            AnimaticTransport(model: model, toggleFullScreen: toggleFullScreen)
        }
        .frame(minWidth: 560, minHeight: 380)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress { press in
            switch press.key {
            case .space: model.togglePlay()
            case .leftArrow: press.modifiers.contains(.option) ? model.stepScene(-1) : model.stepFrame(-1)
            case .rightArrow: press.modifiers.contains(.option) ? model.stepScene(1) : model.stepFrame(1)
            case .home: model.seek(to: 0)
            default: return .ignored
            }
            return .handled
        }
        .onChange(of: model.sourceSignature) {
            model.forgetClipLengths()
            model.rebuild(keepTime: true)
        }
    }

    /// Where the 16:9 picture sits in the view.
    static func videoRect(in size: CGSize) -> CGRect {
        let ratio = AnimaticComposer.renderSize.width / AnimaticComposer.renderSize.height
        guard size.width > 0, size.height > 0 else { return .zero }
        if size.width / size.height > ratio {
            let width = size.height * ratio
            return CGRect(x: (size.width - width) / 2, y: 0, width: width, height: size.height)
        }
        let height = size.width / ratio
        return CGRect(x: 0, y: (size.height - height) / 2, width: size.width, height: height)
    }
}

/// `AVPlayerView` without its own controls (the transport bar has them).
private struct AnimaticVideoView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}

/// Heading, caption and subtitle, sized like the export (which burns them in).
private struct AnimaticOverlayLayer: View {
    let model: AnimaticPlayerModel

    var body: some View {
        GeometryReader { geometry in
            let unit = geometry.size.height / 1080
            let segment = model.currentSegment
            VStack(alignment: .leading, spacing: 10 * unit) {
                if model.overlays.heading, let segment {
                    pill("\(segment.sceneNumber)  \(segment.heading)", font: .system(size: 28 * unit, weight: .bold), unit: unit)
                }
                if model.overlays.caption, let caption = segment?.caption, !caption.isEmpty {
                    pill(caption, font: .system(size: 24 * unit).italic(), unit: unit)
                }
                Spacer(minLength: 0)
                if model.overlays.subtitles, let cue = model.currentCue {
                    VStack(spacing: 2 * unit) {
                        Text(cue.character)
                            .font(.system(size: 26 * unit, weight: .bold))
                            .foregroundStyle(Color(red: 1, green: 0.85, blue: 0.45))
                        Text(cue.text).font(.system(size: 40 * unit))
                    }
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18 * unit).padding(.vertical, 10 * unit)
                    .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 10 * unit))
                    .frame(maxWidth: geometry.size.width * 0.72 + 36 * unit)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 50 * unit)
                }
            }
            .padding(40 * unit)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .allowsHitTesting(false)
    }

    private func pill(_ text: String, font: Font, unit: CGFloat) -> some View {
        Text(text)
            .font(font)
            .foregroundStyle(.white)
            .lineLimit(2)
            .padding(.horizontal, 14 * unit).padding(.vertical, 8 * unit)
            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8 * unit))
    }
}

/// Play, step, scrub, range, overlays and full screen.
private struct AnimaticTransport: View {
    @Bindable var model: AnimaticPlayerModel
    let toggleFullScreen: () -> Void
    @State private var scrub: Double?

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Text(AnimaticPlayerModel.time(scrub ?? model.currentTime)).monospacedDigit()
                Slider(value: Binding(get: { scrub ?? model.currentTime }, set: { scrub = $0; model.seek(to: $0) }),
                       in: 0...max(model.timeline.duration, 0.1)) { editing in
                    if !editing { scrub = nil }
                }
                .controlSize(.small)
                Text(AnimaticPlayerModel.time(model.timeline.duration)).monospacedDigit().foregroundStyle(.secondary)
            }
            .font(.caption)
            HStack(spacing: 14) {
                Group {
                    Button { model.stepScene(-1) } label: { Image(systemName: "backward.end.fill") }
                        .help("Previous scene (⌥←)")
                    Button { model.stepFrame(-1) } label: { Image(systemName: "backward.frame.fill") }
                        .help("Previous frame (←)")
                    Button { model.togglePlay() } label: {
                        Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").font(.title2).frame(width: 28)
                    }
                    .help("Play or pause (Space)")
                    Button { model.stepFrame(1) } label: { Image(systemName: "forward.frame.fill") }
                        .help("Next frame (→)")
                    Button { model.stepScene(1) } label: { Image(systemName: "forward.end.fill") }
                        .help("Next scene (⌥→)")
                }
                .buttonStyle(.borderless)

                if let segment = model.currentSegment {
                    Button(action: model.selectCurrentFrame) {
                        Text(label(segment)).lineLimit(1).truncationMode(.tail)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Select this frame in the storyboard")
                }
                if !model.missing.isEmpty {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .help("Couldn't read: " + model.missing.joined(separator: ", "))
                }
                Spacer()
                rangeMenu
                Menu {
                    Toggle("Scene Number and Heading", isOn: $model.overlays.heading)
                    Toggle("Caption", isOn: $model.overlays.caption)
                    Toggle("Subtitles", isOn: $model.overlays.subtitles)
                } label: {
                    Label("Overlays", systemImage: "captions.bubble")
                }
                .fixedSize()
                .help("Shown while playing, and burned into the exported .mov")
                Button(action: toggleFullScreen) { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    .buttonStyle(.borderless)
                    .help("Full screen (⌃⌘F)")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var rangeMenu: some View {
        Menu(model.rangeTitle) {
            Button("Whole Film") { model.play(.film, autoplay: model.isPlaying) }
            if let scene = model.currentSegment?.sceneID {
                Button("This Scene") { model.play(.scene(scene), autoplay: model.isPlaying) }
            }
            Divider()
            Menu("From Scene") {
                ForEach(model.scenes, id: \.id) { scene in
                    Button("\(scene.number). \(scene.heading)") { model.setFrom(scene.id) }
                }
            }
            Menu("To Scene") {
                ForEach(model.scenes, id: \.id) { scene in
                    Button("\(scene.number). \(scene.heading)") { model.setTo(scene.id) }
                }
            }
        }
        .fixedSize()
        .help("What to play")
    }

    private func label(_ segment: AnimaticSegment) -> String {
        var parts = ["Scene \(segment.sceneNumber)"]
        parts.append(segment.file == nil ? "no frames yet" : "Frame \(segment.frameIndex + 1)")
        if let caption = segment.caption, !caption.isEmpty { parts.append(caption) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Window

/// The player's own window, so it can go full screen or sit beside the project.
@MainActor
final class AnimaticWindowController: NSWindowController, NSWindowDelegate {
    let model: AnimaticPlayerModel

    init(model: AnimaticPlayerModel, title: String) {
        self.model = model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 620),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = title
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("SlateAnimatic")
        if window.frame.origin == .zero { window.center() }
        super.init(window: window)
        window.delegate = self
        window.contentViewController = NSHostingController(rootView: AnimaticPlayerView(model: model) { [weak window] in
            window?.toggleFullScreen(nil)
        })
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func windowWillClose(_ notification: Notification) {
        model.stop()
    }
}
