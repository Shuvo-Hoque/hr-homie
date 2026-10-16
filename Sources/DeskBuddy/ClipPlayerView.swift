import AppKit
import AVFoundation

/// Plays the buddy's transparent HEVC clips.
/// Clips can be prepared ahead: loaded, decoded to their first frame, paused and hidden, so switching to one is
/// instant (the new frame is on screen in the same display refresh). Other clips load on demand, and the current clip
/// stays up until the new one has a frame, so a switch never flashes an empty frame. Loops use AVPlayerLooper.
@MainActor
final class ClipPlayerView: NSView {
    private final class Entry: @unchecked Sendable {   // only touched on the main thread
        let player: AVPlayer
        let looper: AVPlayerLooper?
        let layer: AVPlayerLayer
        init(player: AVPlayer, looper: AVPlayerLooper?, layer: AVPlayerLayer) {
            self.player = player; self.looper = looper; self.layer = layer
        }
    }

    private var entries: [ObjectIdentifier: Entry] = [:]
    private var current: Entry?
    private var endObserver: NSObjectProtocol?
    private var timeObservers: [(AVPlayer, Any)] = []
    private var pendingShow: NSKeyValueObservation?
    private var top: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for e in entries.values { e.layer.frame = bounds }
        CATransaction.commit()
    }

    /// Load these clips now (first frame decoded, paused, hidden) so playing them later starts instantly.
    func prepare(_ clips: [(AVAsset, Bool)]) {
        for (asset, loop) in clips { _ = entry(asset, loop: loop) }
    }

    /// Release every loaded clip (when he leaves the screen).
    func unprepareAll() {
        stop()
        for e in entries.values { e.player.pause(); e.layer.removeFromSuperlayer() }
        entries = [:]
    }

    /// - markers: callbacks at times (s) into the clip
    /// - fade: seconds the previous clip takes to fade out (0 = cut)
    /// - rate: playback speed (markers are in clip time, so they stay on their frames)
    func play(_ asset: AVAsset, loop: Bool = false, fade: TimeInterval = 0, rate: Float = 1,
              markers: [(TimeInterval, () -> Void)] = [], onEnd: (() -> Void)? = nil) {
        clearObservers()
        pendingShow = nil
        let e = entry(asset, loop: loop)
        let old = current
        current = e
        if e === old || CMTimeCompare(e.player.currentTime(), .zero) != 0 {
            e.player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        }
        for (t, fn) in markers {
            let token = e.player.addBoundaryTimeObserver(forTimes: [NSValue(time: CMTime(seconds: t, preferredTimescale: 600))],
                                                         queue: .main) { MainActor.assumeIsolated { fn() } }
            timeObservers.append((e.player, token))
        }
        if let onEnd, !loop, let item = e.player.currentItem {
            endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item,
                                                                 queue: .main) { _ in MainActor.assumeIsolated { onEnd() } }
        }
        e.player.rate = rate
        if e.layer.isReadyForDisplay {
            show(e, replacing: old, fade: fade)
        } else {
            pendingShow = e.layer.observe(\.isReadyForDisplay, options: [.new]) { [weak self] layer, _ in
                guard layer.isReadyForDisplay else { return }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, self.current === e else { return }
                        self.pendingShow = nil
                        self.show(e, replacing: old, fade: fade)
                    }
                }
            }
        }
    }

    /// Where the current clip is (seconds).
    var currentSeconds: Double { current.map { CMTimeGetSeconds($0.player.currentTime()) } ?? 0 }

    /// Change the current clip's speed mid-play.
    func setRate(_ rate: Float) { current?.player.rate = rate }

    func stop() {
        clearObservers()
        pendingShow = nil
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for e in entries.values { e.layer.opacity = 0; rest(e) }
        CATransaction.commit()
        current = nil
    }

    // MARK: private

    private func entry(_ asset: AVAsset, loop: Bool) -> Entry {
        if let e = entries[ObjectIdentifier(asset)] { return e }
        let item = AVPlayerItem(asset: asset)
        let player: AVPlayer
        var looper: AVPlayerLooper?
        if loop {
            let queue = AVQueuePlayer()
            looper = AVPlayerLooper(player: queue, templateItem: item)
            player = queue
        } else {
            player = AVPlayer(playerItem: item)
            player.actionAtItemEnd = .pause                 // hold the last frame until the next clip takes over
        }
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        player.automaticallyWaitsToMinimizeStalling = false
        let l = AVPlayerLayer(player: player)
        l.frame = bounds
        l.videoGravity = .resizeAspect
        l.backgroundColor = NSColor.clear.cgColor
        l.pixelBufferAttributes = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        l.opacity = 0
        layer?.addSublayer(l)
        let e = Entry(player: player, looper: looper, layer: l)
        entries[ObjectIdentifier(asset)] = e
        return e
    }

    private func show(_ e: Entry, replacing old: Entry?, fade: TimeInterval) {
        top += 1
        CATransaction.begin(); CATransaction.setDisableActions(true)
        e.layer.zPosition = top
        e.layer.opacity = 1
        CATransaction.commit()
        guard let old, old !== e else { return }
        if fade > 0 {
            CATransaction.begin()
            CATransaction.setAnimationDuration(fade)
            CATransaction.setCompletionBlock { MainActor.assumeIsolated { [weak self] in if self?.current !== old { self?.rest(old) } } }
            old.layer.opacity = 0
            CATransaction.commit()
        } else {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            old.layer.opacity = 0
            CATransaction.commit()
            rest(old)
        }
    }

    /// Pause a hidden clip and rewind it, ready to start again instantly.
    private func rest(_ e: Entry) {
        e.player.pause()
        if CMTimeCompare(e.player.currentTime(), .zero) != 0 {
            e.player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    private func clearObservers() {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        for (player, token) in timeObservers { player.removeTimeObserver(token) }
        timeObservers = []
    }
}
