import AppKit
import AVFoundation
import SwiftUI

/// Where things sit in the panel (points, origin bottom-left). Standing: the clip stage in the corner, the bubble above
/// his head. Sitting (on a window's top edge): the same stage, with his seat on `seatY`.
struct BuddyLayout {
    let panel: CGSize
    let stage: CGRect
    let popup: CGRect
    /// tail tip x from the bubble's left edge
    let tailX: CGFloat
    /// his head (centre x, top y) and roughly where his hands hold the glass, in panel points
    let headX: CGFloat
    let headY: CGFloat
    let glass: CGPoint
    /// his body while he waits: clicks here poke him, drags pick him up
    let body: CGRect
    /// sitting: the seat line (the window's top edge), from the panel's bottom
    let seatY: CGFloat?
    /// where your hand holds him when you pick him up (his collar in the dangling pose)
    let grab: CGPoint

    struct SitInfo: Decodable { let headX, headTop, seatY: Double; let body: [Double] }
    private struct StageInfo: Decodable {
        let width, height, headX, headTop: Double
        let sit: [String: SitInfo]?
        let grab: [String: [Double]]?
    }

    /// `sitting`: "glass" / "empty" for the sitting pose of that variant; nil for standing.
    static func load(from clips: URL, scale: CGFloat, sitting: String? = nil, variant: String = "glass") -> BuddyLayout {
        let i = (try? JSONDecoder().decode(StageInfo.self, from: Data(contentsOf: clips.appendingPathComponent("stage.json"))))
            ?? StageInfo(width: 960, height: 760, headX: 640, headTop: 118, sit: nil, grab: nil)
        let k = scale / 2                                                  // clips are 2x pixels
        let sw = i.width * k, sh = i.height * k
        let pt = { (x: Double, y: Double) in CGPoint(x: x * k, y: (i.height - y) * k) }   // stage px (top-left) -> pt
        let sit = sitting.flatMap { i.sit?[$0] }
        let head = pt(sit?.headX ?? i.headX, sit?.headTop ?? i.headTop)
        let popupW: CGFloat = 320, popupH: CGFloat = 260, margin: CGFloat = 10
        let popupBottom = head.y + 2                                       // tail tip just above his hair
        let popupX = max(margin, head.x - popupW / 2)                      // bubble centred over his head
        var body = CGRect(x: head.x - 56 * scale, y: 8 * scale, width: 112 * scale, height: head.y - 8 * scale)
        if let b = sit?.body, b.count == 4 {
            let lo = pt(b[0], b[3]), hi = pt(b[2], b[1])
            body = CGRect(x: lo.x, y: lo.y, width: hi.x - lo.x, height: hi.y - lo.y)
        }
        let g = i.grab?[variant] ?? [i.headX, i.headTop + 80]
        let seat = sit.map { pt(0, $0.seatY).y }
        return BuddyLayout(panel: CGSize(width: max(sw, popupX + popupW), height: popupBottom + popupH),
                           stage: CGRect(x: 0, y: 0, width: sw, height: sh),
                           popup: CGRect(x: popupX, y: popupBottom, width: popupW, height: popupH),
                           tailX: head.x - popupX - 10,                  // the bubble is inset 10 pt in its host
                           headX: head.x, headY: head.y,
                           glass: CGPoint(x: head.x - 14 * scale, y: seat.map { $0 + (head.y - $0) * 0.55 } ?? sh * 0.62),
                           body: body, seatY: seat, grab: pt(g[0], g[1]))
    }
}

/// The buddy on screen: a transparent, click-through panel. Usually he walks in at the bottom-left corner; sometimes he
/// climbs up and sits on the top edge of the window you're working in. He waits under the bubble until it's answered
/// (no timeout), then reacts and leaves by the nearest screen edge. You can poke him, or pick him up and drop him anywhere.
/// The clips he may need next are loaded ahead (ClipPlayerView.prepare), so every switch is instant.
@MainActor
final class BuddyController {
    enum Answer { case yes, no }
    enum Phase { case hidden, entering, waiting, reacting, peeking, dragging, falling }
    enum Pose { case stand, sit }

    private(set) var phase: Phase = .hidden
    private(set) var kind: Kind = .water
    private var pose: Pose = .stand
    var isShowing: Bool { phase != .hidden }
    /// The app logs the answer and fills in the bubble's words; for water it returns how far the drink got the day.
    var onAnswer: ((Kind, Answer) -> Milestone)?
    var onFinish: ((Kind) -> Void)?

    let model = PopupModel()
    private let panel: NSPanel
    private let stage = ClipPlayerView(frame: .zero)
    private let popup: FirstMouseHostingView<PopupView>
    private let clipsURL: URL
    private var assets: [String: AVAsset] = [:]
    private var layout: BuddyLayout?
    private var screen: NSScreen?
    private var scale: CGFloat = 1
    private var mouseTimer: Timer?
    private var mouseMonitors: [Any] = []
    private let overlay = BreakOverlay()
    private let pokeView = PokeView()
    private var pokes = 0
    private var doneText = ("", "")
    private var askMessage = ""
    private var messageToken = 0
    private var faces: [Kind: NSImage] = [:]
    /// the clip playing now ("enter", "idle", "giggle", "land", …): end handlers check it, so a newer clip wins
    private var role = ""

    // sitting on a window
    private var trackedWindow: CGWindowID?
    private var lastWindowFrame: NSRect?
    private var trackTimer: Timer?
    private var lastTrack = Date()
    private var wobble: CGFloat = 0, wobbleV: CGFloat = 0

    // falling and walking off
    private var motionTimer: Timer?
    /// a walk-off clip's switch to its in-place walk (or run) cycle; dir -1 = off to the left, +1 = to the right
    private struct Walk: Decodable { let switchAt, clipHeadX, loopHeadX, speed: Double; let loop: String; let dir: Double? }
    private var walks: [String: Walk] = [:]
    /// landing: how far his dangling feet hang above the landing pose (stage px), and when in land.mov he's at the
    /// bottom of the crouch / back at full height (s)
    private struct Land: Decodable { let gap, bottom, up: Double }
    /// a long, non-repeating walk-off: per frame, how far (stage px) the ground has moved under him since its start
    private struct LongWalk: Decodable { let clip: String; let headX: Double; let offsets: [Double] }
    private var longs: [String: LongWalk] = [:]
    private var lands: [String: Land] = [:]
    private var thuds: [NSSound] = []
    private let riseRate: Float = 1.8                 // standing back up after a drop: snappy

    // timings inside the clips (seconds)
    private let popupIn = 3.2           // he has stopped and faces the camera
    private let thumbsUp = 7.4          // drink.mov: the thumbs-up after drinking
    private let cheersSip = 2.6          // drink.mov: first sip (the drops), after the toast
    private let cheersDone = 5.6         // drink.mov: "Cheers! 🥂" gives way to the result line
    private let sadTurn = 2.9           // sad.mov / sad_empty.mov: sad face ~1.5-2.5 s, then he turns away, head down
    private let climbPopup = 4.0        // climbin: he has sat down
    private let sitSip = 2.6, sitDone = 4.6, sitThumbs = 5.0, sitYesHide = 6.0     // sityes (glass)
    private let sitYesEmptyHide = 1.8   // sityes_empty: thumbs up, then he climbs down
    private let sitNoHide = 3.4         // sitno: sad face, then he tips back behind the window
    static let lookAwaySeconds = 20.0   // lookfar.mov holds his far-away gaze this long, then he turns back

    private static let roles = ["giggle", "flinch", "hey", "silly", "dangle", "land", "sit", "climbin", "sityes", "sitno"]
    private static let exits = ["leave", "sad", "drink"]

    init() {
        let res = Bundle.main.resourceURL!
        clipsURL = res.appendingPathComponent("clips")
        let names = ["walkin", "idle", "drink", "leave", "sad", "enter_empty", "idle_empty", "lookfar", "leave_empty",
                     "sad_empty", "peek", "y_enter", "y_idle", "y_go", "y_later", "y_sad",
                     "walk_leave", "walk_sad", "walk_drink", "walk_leave_empty", "walk_sad_empty",
                     "drink_r", "sad_r", "sad_empty_r", "leave_empty_r",
                     "walk_drink_r", "walk_sad_r", "walk_sad_empty_r", "walk_leave_empty_r"]
            + Self.roles + Self.roles.map { $0 + "_empty" }
        for name in names {
            let url = clipsURL.appendingPathComponent("\(name).mov")
            if FileManager.default.fileExists(atPath: url.path) { assets[name] = AVURLAsset(url: url) }
        }
        struct StageFile: Decodable { let walk: [String: Walk]?; let land: [String: Land]?; let long: [String: LongWalk]? }
        let stageFile = try? JSONDecoder().decode(StageFile.self, from: Data(contentsOf: clipsURL.appendingPathComponent("stage.json")))
        walks = stageFile?.walk ?? [:]
        lands = stageFile?.land ?? [:]
        longs = stageFile?.long ?? [:]
        for lw in longs.values {
            let url = clipsURL.appendingPathComponent("\(lw.clip).mov")
            if FileManager.default.fileExists(atPath: url.path) { assets[lw.clip] = AVURLAsset(url: url) }
        }
        thuds = (1...2).compactMap { NSSound(contentsOf: res.appendingPathComponent("sounds/thud\($0).wav"), byReference: false) }
        let face = NSImage(contentsOf: res.appendingPathComponent("face.png")) ?? NSImage()
        faces = [.water: face, .eyes: face, .move: face,
                 .prayer: NSImage(contentsOf: res.appendingPathComponent("face_prayer.png")) ?? face]

        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(NSWindow.Level.statusBar.rawValue + 1)   // above apps, the Dock and the eye-break blur
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovable = false
        panel.ignoresMouseEvents = true
        panel.acceptsMouseMovedEvents = true

        popup = FirstMouseHostingView(rootView: PopupView(model: model, face: face))
        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.clear.cgColor
        content.addSubview(stage)
        content.addSubview(pokeView)
        content.addSubview(popup)
        panel.contentView = content

        model.onYes = { [weak self] in self?.answer(.yes) }
        model.onNo = { [weak self] in self?.answer(.no) }
        overlay.onSkip = { [weak self] in self?.skipBreak() }
        pokeView.onPoke = { [weak self] in self?.poke() }
        pokeView.onDragBegan = { [weak self] in self?.dragBegan() }
        pokeView.onDragMoved = { [weak self] in self?.dragMoved() }
        pokeView.onDragEnded = { [weak self] in self?.dragEnded() }
    }

    // MARK: clips

    /// The glass for water, empty hands for the breaks.
    private var variant: String { kind == .water ? "glass" : "empty" }
    private var suffix: String { kind == .water ? "" : "_empty" }

    /// Whether the current reminder has its own clip for a role (poke, drag and sitting clips; not for prayer time).
    private func has(_ role: String) -> Bool { kind != .prayer && assets[role + suffix] != nil }

    /// The clip file for a role in the current reminder.
    private func name(_ role: String) -> String {
        let water = ["enter": "walkin", "idle": "idle", "leave": "leave", "sad": "sad", "drink": "drink"]
        let empty = ["enter": "enter_empty", "idle": "idle_empty", "leave": "leave_empty", "sad": "sad_empty"]
        // prayer time is the other character: in from the edge, waits, "let's go pray", or sad and head down on Not Now
        let prayer = ["enter": "y_enter", "idle": "y_idle", "leave": "y_go", "sad": "y_sad"]
        let names = kind == .water ? water : kind == .prayer ? prayer : empty
        if let n = names[role], assets[n] != nil { return n }
        if assets[role + suffix] != nil { return role + suffix }
        return names["leave"]!
    }

    private func clip(_ role: String) -> AVAsset { assets[name(role)] ?? assets["leave"]! }

    /// Play a role's clip; `role` remembers what's on screen so stale end handlers do nothing.
    private func run(_ r: String, loop: Bool = false, fade: TimeInterval = 0,
                     markers: [(TimeInterval, () -> Void)] = [], onEnd: (() -> Void)? = nil) {
        role = r
        stage.play(clip(r), loop: loop, fade: fade, markers: markers, onEnd: onEnd)
    }

    /// Load the clips this visit can switch to at a moment's notice.
    private func prepareClips() {
        var now: [(String, Bool)] = [("enter", false), ("idle", true)]
        if pose == .sit { now += [("climbin", false), ("sit", true)] }
        for r in ["giggle", "hey", "silly", "land"] where has(r) { now.append((r, false)) }
        if has("dangle") { now.append(("dangle", true)) }
        stage.prepare(now.map { (clip($0.0), $0.1) })
        // the reactions, a moment later (they start with a cross-fade, so they're less urgent)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.phase != .hidden else { return }
            var later = Self.exits.map { (self.clip($0), false) }
            later += Self.exits.compactMap { self.assets[self.name($0) + "_r"] }.map { ($0, false) }
            if self.pose == .sit { later += ["sityes", "sitno"].filter { self.has($0) }.map { (self.clip($0), false) } }
            if self.kind == .eyes, let look = self.assets["lookfar"] { later.append((look, false)) }
            self.stage.prepare(later)
        }
    }

    // MARK: show / react / leave

    /// The app sets the bubble's words before calling this. `onWindow`: try to sit on the front window.
    func show(_ kind: Kind, scale: Double, onWindow: Bool = false) {
        guard phase == .hidden, let screen = activeScreen() else { return }
        self.kind = kind
        self.screen = screen
        self.scale = CGFloat(scale)
        askMessage = model.message
        model.face = faces[kind]
        model.mode = .ask
        model.visible = false
        phase = .entering
        if onWindow, has("climbin"), has("sit"), let w = Windows.front(), sit(on: w) {
            // he climbs up from behind the window and sits on its top edge
            pose = .sit
            prepareClips()
            panel.orderFrontRegardless()
            run("climbin", markers: [(climbPopup, { [weak self] in self?.presentPopup() })],
                onEnd: { [weak self] in self?.settle(after: "climbin") })
            startTracking()
        } else {
            pose = .stand
            apply(standing(), NSPoint(x: screen.visibleFrame.minX, y: screen.frame.minY))
            prepareClips()
            panel.orderFrontRegardless()
            run("enter", markers: [(popupIn, { [weak self] in self?.presentPopup() })],
                onEnd: { [weak self] in self?.settle(after: "enter") })
        }
        startMouseTracking()
    }

    /// Hide immediately (menu: Send Him Away).
    func dismiss() {
        guard phase != .hidden else { return }
        finish()
    }

    /// He has stopped and faces you: the bubble pops up, and from now on he can be poked, picked up or answered.
    private func presentPopup() {
        guard phase == .entering else { return }
        phase = .waiting
        model.visible = true
        sound("Glass")
        updateMousePassThrough()
    }

    /// The entrance (or a landing) has finished: wait in the idle loop, unless something else already took over.
    private func settle(after r: String) {
        guard role == r, phase == .waiting || phase == .entering else { return }
        phase = .waiting
        model.visible = true
        run(pose == .sit ? "sit" : "idle", loop: true)
    }

    private func answer(_ a: Answer) {
        guard phase == .entering || phase == .waiting else { return }
        phase = .reacting
        messageToken += 1
        let milestone = onAnswer?(kind, a) ?? .none
        let hide: (TimeInterval) -> (TimeInterval, () -> Void) = { [weak self] t in (t, { self?.model.visible = false }) }
        let end: () -> Void = { [weak self] in self?.finish() }

        if pose == .sit { answerSitting(a, milestone, hide, end); return }
        switch (kind, a) {
        case (.water, .yes):
            // "Cheers! 🥂": he raises his glass to you, drinks (the drops), thumbs up, then the day's result line
            var marks = cheers(milestone, sip: cheersSip, done: cheersDone, thumbs: thumbsUp)
            marks.append(hide(milestone == .goal ? thumbsUp + 1.8 : cheersDone + 3.2))
            exit("drink", fade: 0.2, markers: marks, onEnd: end)
        case (.eyes, .yes):
            // the screen blurs with a 20 s timer in the middle; he stays sharp, looking far away,
            // then "Eyes rested", the blur fades, and he walks off
            model.visible = false
            if let screen { overlay.show(seconds: Self.lookAwaySeconds, on: screen) }
            role = "lookfar"
            stage.play(assets["lookfar"] ?? clip("idle"), fade: 0.2, markers: [(Self.lookAwaySeconds, { [weak self] in
                self?.overlay.finish()
                self?.sound("Glass")
            })], onEnd: { [weak self] in
                guard let self, self.role == "lookfar" else { return }
                (self.model.title, self.model.message) = Lines.eyesDone
                self.model.mode = .done
                self.model.visible = true
                self.exit("leave", fade: 0.15, markers: [hide(1.6)], onEnd: end)
            })
        case (_, .yes):
            // movement: "Let's go!"; prayer: he beckons "come on, let's go pray"
            model.mode = .done
            exit("leave", fade: 0.15, markers: [hide(kind == .prayer ? 2.6 : 2.4)], onEnd: end)
        case (_, .no):
            // a sad face, a sigh, then he shuffles off with his head down; the bubble stays up through the sad face
            model.mode = .snoozed
            exit("sad", fade: 0.15, markers: [hide(sadTurn)], onEnd: end)
        }
    }

    /// The water "Cheers! 🥂" sequence: toast line, drops on the first sip, the day's result line, confetti at the goal.
    private func cheers(_ m: Milestone, sip: TimeInterval, done: TimeInterval, thumbs: TimeInterval) -> [(TimeInterval, () -> Void)] {
        doneText = (model.title, model.message)
        (model.title, model.message) = Lines.cheers
        model.mode = .done
        var marks: [(TimeInterval, () -> Void)] = [
            (sip, { [weak self] in self?.splash() }),
            (done, { [weak self] in guard let self else { return }; (self.model.title, self.model.message) = self.doneText }),
        ]
        if m == .goal { marks.append((thumbs, { [weak self] in self?.celebrate() })) }
        return marks
    }

    /// Answers while he sits on a window: he does it there, then climbs back down behind the window.
    private func answerSitting(_ a: Answer, _ m: Milestone, _ hide: (TimeInterval) -> (TimeInterval, () -> Void),
                               _ end: @escaping () -> Void) {
        switch (kind, a) {
        case (.water, .yes):
            var marks = cheers(m, sip: sitSip, done: sitDone, thumbs: sitThumbs)
            marks.append(hide(sitYesHide))
            run("sityes", fade: 0.2, markers: marks, onEnd: end)
        case (.eyes, .yes):
            // he keeps sitting there while the screen blurs, then climbs down
            model.visible = false
            if let screen { overlay.show(seconds: Self.lookAwaySeconds, on: screen) }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.lookAwaySeconds) { [weak self] in
                guard let self, self.phase == .reacting, self.kind == .eyes else { return }
                self.overlay.finish()
                self.sound("Glass")
                (self.model.title, self.model.message) = Lines.eyesDone
                self.model.mode = .done
                self.model.visible = true
                self.run("sityes", fade: 0.15, markers: [(self.sitYesEmptyHide + 1, { [weak self] in
                    self?.model.visible = false })], onEnd: end)
            }
        case (_, .yes):
            model.mode = .done
            run("sityes", fade: 0.15, markers: [hide(sitYesEmptyHide)], onEnd: end)
        case (_, .no):
            model.mode = .snoozed
            run("sitno", fade: 0.15, markers: [hide(sitNoHide)], onEnd: end)
        }
    }

    /// Show a line for a moment, then go back to the reminder's own line.
    private func say(_ line: String, for seconds: TimeInterval) {
        messageToken += 1
        let token = messageToken
        model.message = line
        model.visible = true
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.messageToken == token, self.phase == .waiting else { return }
            self.model.message = self.askMessage
        }
    }

    /// A click on him while he waits: a giggle or a "hey!", and every third poke a dizzy spin; just his body, no words.
    /// The clips are cut to start on the first frame of movement, and a new poke interrupts the current reaction.
    /// Each reaction starts and ends in his waiting pose. On a window, he wobbles instead.
    private func poke() {
        guard phase == .waiting else { return }
        if pose == .sit {
            wobbleV += 3.2
            return
        }
        guard has("giggle") || has("hey") else { return }
        pokes += 1
        let silly = pokes % 3 == 0
        let r = silly ? "silly" : ["giggle", "flinch", "hey"].filter { has($0) }.randomElement() ?? "giggle"
        run(r, fade: 0.05, onEnd: { [weak self] in
            guard let self, self.role == r, self.phase == .waiting else { return }
            self.run("idle", loop: true, fade: 0.1)
        })
    }

    /// Peekaboo: he leans in from the screen's left edge, waves and ducks away. No bubble, nothing to answer.
    func peek(scale: Double) {
        guard phase == .hidden, let screen = activeScreen(), let clip = assets["peek"] else { return }
        self.screen = screen
        self.scale = CGFloat(scale)
        kind = .water
        pose = .stand
        apply(standing(), NSPoint(x: screen.visibleFrame.minX, y: screen.frame.minY))
        model.visible = false
        panel.ignoresMouseEvents = true
        panel.orderFrontRegardless()
        phase = .peeking
        role = "peek"
        stage.play(clip, onEnd: { [weak self] in self?.finish() })
    }

    /// Skip on the eye-break timer: the blur goes, and he leaves looking sad about it.
    private func skipBreak() {
        guard phase == .reacting, kind == .eyes else { return }
        overlay.hide(animated: true)
        (model.title, model.message) = Lines.eyesSkipped
        model.mode = .snoozed
        model.visible = true
        let end: () -> Void = { [weak self] in self?.finish() }
        let hideAt: (TimeInterval) -> (TimeInterval, () -> Void) = { [weak self] t in (t, { self?.model.visible = false }) }
        if pose == .sit {
            run("sitno", fade: 0.15, markers: [hideAt(sitNoHide)], onEnd: end)
        } else {
            exit("sad", fade: 0.15, markers: [hideAt(sadTurn)], onEnd: end)
        }
    }

    private func finish() {
        if phase == .dragging { NSCursor.closedHand.pop() }
        pokes = 0
        messageToken += 1
        motionTimer?.invalidate(); motionTimer = nil
        stopTracking()
        overlay.hide(animated: false)
        stopMouseTracking()
        model.visible = false
        panel.ignoresMouseEvents = true
        panel.orderOut(nil)
        stage.unprepareAll()
        pose = .stand
        role = ""
        phase = .hidden
        onFinish?(kind)
    }

    private func sound(_ name: String) {
        if UserDefaults.standard.object(forKey: "soundOn") as? Bool ?? true { NSSound(named: name)?.play() }
    }

    // MARK: walking off by the nearest edge

    /// Play a walk-off clip ("leave", "sad", "drink"). Every direction is real footage, never mirrored: "<clip>" walks
    /// (or, after a drink, jogs) off to the left, "<clip>_r" to the right. In his corner the left clip takes him off
    /// the screen edge as filmed. Anywhere else he heads for the nearer edge (if there's footage for that side), and
    /// once the clip has him striding, its in-place walk cycle takes over while the window moves at his real speed,
    /// until he's off the screen.
    private func exit(_ r: String, fade: TimeInterval, markers: [(TimeInterval, () -> Void)], onEnd: @escaping () -> Void) {
        let left = name(r), right = left + "_r"
        guard pose == .stand, let l = layout, let scr = screen else {
            run(r, fade: fade, markers: markers, onEnd: onEnd); return
        }
        let head = panel.frame.minX + l.headX
        let canRight = assets[right] != nil && walks[right] != nil
        let toRight = canRight && scr.frame.maxX - head < head - scr.frame.minX
        let clipName = toRight ? right : left
        guard let w = walks[clipName], let loop = assets[w.loop] else {
            run(r, fade: fade, markers: markers, onEnd: onEnd); return
        }
        if !toRight && panel.frame.minX <= scr.visibleFrame.minX + 4 {
            run(r, fade: fade, markers: markers, onEnd: onEnd); return
        }
        stage.prepare([(loop, true)])
        let long = longs[clipName].flatMap { lw in assets[lw.clip].map { (lw, $0) } }
        if let (_, asset) = long { stage.prepare([(asset, false)]) }
        role = r
        stage.play(assets[clipName]!, fade: fade, markers: markers + [(w.switchAt, { [weak self] in
            if let (lw, asset) = long {
                self?.walkLong(lw, asset, w, loop, screen: scr, onEnd: onEnd)
            } else {
                self?.walkOff(w, loop, screen: scr, onEnd: onEnd)
            }
        })])
    }

    /// The long walk: one continuous take, no repeats. Each displayed frame moves the window by exactly how far the
    /// ground moved under him in that frame, so his planted foot stays put on the screen. If the take runs out before
    /// he's off the screen (a very wide display), the stride loop carries on from there.
    private func walkLong(_ lw: LongWalk, _ asset: AVAsset, _ w: Walk, _ loop: AVAsset, screen scr: NSScreen,
                          onEnd: @escaping () -> Void) {
        guard phase == .reacting, let l = layout else { return }
        model.visible = false
        let k = scale / 2, dir = CGFloat(w.dir ?? -1)
        let x0 = panel.frame.minX + (w.clipHeadX - lw.headX) * k, y = panel.frame.minY
        panel.setFrameOrigin(NSPoint(x: x0, y: y))
        role = "walklong"
        let offsets = lw.offsets.map { CGFloat($0) }
        let gone = dir < 0 ? scr.frame.minX - 90 * scale - l.headX : scr.frame.maxX + 90 * scale - l.headX
        var finished = false
        let handOver: () -> Void = { [weak self] in
            // out of footage: continue with the stride loop from where his head is now
            guard let self, !finished else { return }
            finished = true
            self.motionTimer?.invalidate()
            let last = offsets.last ?? 0
            let shifted = Walk(switchAt: 0, clipHeadX: lw.headX, loopHeadX: w.loopHeadX, speed: w.speed, loop: w.loop, dir: w.dir)
            self.panel.setFrameOrigin(NSPoint(x: x0 + last * k * dir, y: y))
            self.walkOff(shifted, loop, screen: scr, onEnd: onEnd)
        }
        stage.play(asset, onEnd: handOver)
        motionTimer?.invalidate()
        motionTimer = every(1.0 / 120) { [weak self] timer in
            guard let self, !finished else { timer.invalidate(); return }
            let f = CGFloat(self.stage.currentSeconds * 24)
            let i = min(max(Int(f), 0), offsets.count - 1), j = min(i + 1, offsets.count - 1)
            let off = offsets[i] + (offsets[j] - offsets[i]) * (f - CGFloat(i))
            let x = x0 + off * k * dir
            self.panel.setFrameOrigin(NSPoint(x: x, y: y))
            if dir < 0 ? x <= gone : x >= gone {
                finished = true
                timer.invalidate()
                onEnd()
            }
        }
    }

    private func walkOff(_ w: Walk, _ loop: AVAsset, screen scr: NSScreen, onEnd: @escaping () -> Void) {
        guard phase == .reacting, let l = layout else { return }
        model.visible = false
        let k = scale / 2, dir = CGFloat(w.dir ?? -1)
        // keep his head where it is: the clip had it at clipHeadX, the walk cycle holds it at loopHeadX
        let x0 = panel.frame.minX + (w.clipHeadX - w.loopHeadX) * k, y = panel.frame.minY
        panel.setFrameOrigin(NSPoint(x: x0, y: y))
        role = "walk"
        stage.play(loop, loop: true)
        let v = w.speed * k * dir                                       // points per second
        let gone = dir < 0 ? scr.frame.minX - 90 * scale - l.headX : scr.frame.maxX + 90 * scale - l.headX
        let t0 = CACurrentMediaTime()
        motionTimer?.invalidate()
        motionTimer = every(1.0 / 60) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let x = x0 + v * CGFloat(CACurrentMediaTime() - t0)
            self.panel.setFrameOrigin(NSPoint(x: x, y: y))
            if dir < 0 ? x <= gone : x >= gone {
                timer.invalidate()
                onEnd()
            }
        }
    }

    /// A repeating timer that keeps firing during menu tracking and window drags.
    private func every(_ interval: TimeInterval, _ fn: @escaping (Timer) -> Void) -> Timer {
        let t = Timer(timeInterval: interval, repeats: true) { t in MainActor.assumeIsolated { fn(t) } }
        RunLoop.main.add(t, forMode: .common)
        return t
    }

    // MARK: scripted checks (DeskBuddy --demo)

    var debugFrame: NSRect { panel.frame }
    /// scripted runs: never take real clicks (a person at the Mac might click the test buddy)
    var debugIgnoreMouse = false
    var debugWindowNumber: Int { panel.windowNumber }
    var debugRole: String { role }
    var debugClipTime: Double { stage.currentSeconds }
    var debugPhase: Phase { phase }

    /// Pick him up and let go at `point` (screen coordinates of his collar), as a drag would.
    func debugDrop(at point: NSPoint) {
        guard phase == .waiting, has("dangle") else { return }
        phase = .dragging
        pose = .stand
        let l = standing()
        apply(l, NSPoint(x: point.x - l.grab.x, y: point.y - l.grab.y))
        run("dangle", loop: true)
        model.visible = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.fall(windowGone: false) }
    }

    func debugAnswer(_ a: Answer) { answer(a) }

    // MARK: picking him up

    private func dragBegan() {
        guard phase == .waiting, has("dangle"), has("land") else { return }
        phase = .dragging
        messageToken += 1
        stopTracking()
        model.visible = false
        pose = .stand
        let l = standing()
        let m = NSEvent.mouseLocation
        apply(l, NSPoint(x: m.x - l.grab.x, y: m.y - l.grab.y))
        run("dangle", loop: true)
        NSCursor.closedHand.push()
        sound("Pop")
        stage.layer?.removeAnimation(forKey: "squash")
    }

    private func dragMoved() {
        guard phase == .dragging, let l = layout else { return }
        let m = NSEvent.mouseLocation
        panel.setFrameOrigin(NSPoint(x: m.x - l.grab.x, y: m.y - l.grab.y))
    }

    private func dragEnded() {
        guard phase == .dragging else { return }
        NSCursor.closedHand.pop()
        fall(windowGone: false)
    }

    /// He drops to the bottom of the screen with gravity (faster and faster), lands, dusts himself off, and waits
    /// where he landed.
    private func fall(windowGone: Bool) {
        phase = .falling
        model.visible = false
        if windowGone {
            // the window he sat on went away: switch to the flailing pose right where he was
            guard let sitting = layout else { return }
            let head = NSPoint(x: panel.frame.minX + sitting.headX, y: panel.frame.minY + sitting.headY)
            stopTracking()
            let l = standing()
            pose = .stand
            apply(l, NSPoint(x: head.x - l.headX, y: head.y - l.headY))
            run("dangle", loop: true)
        }
        guard let l = layout else { return }
        let mid = NSPoint(x: panel.frame.minX + l.headX, y: panel.frame.minY + l.headY)
        let scr = NSScreen.screens.first { NSMouseInRect(mid, $0.frame, false) } ?? screen ?? NSScreen.main!
        screen = scr
        // land on the bottom of the screen, with the bubble still on it
        let x1 = min(max(panel.frame.minX, scr.visibleFrame.minX + 8 - l.popup.minX), scr.visibleFrame.maxX - 8 - l.popup.maxX)
        // fall until his dangling feet reach the bottom of the screen: the landing clip starts on its touchdown frame,
        // where he stands that much lower in the stage, so the window steps back up by the same amount at impact
        let gap = CGFloat(lands[variant]?.gap ?? 0) * scale / 2
        let start = panel.frame.origin, y1 = scr.frame.minY - gap
        let drop = max(0, start.y - y1)
        let duration = max(0.1, sqrt(2 * drop / 3000))                     // g = 3000 pt/s²
        let t0 = CACurrentMediaTime()
        motionTimer?.invalidate()
        motionTimer = every(1.0 / 120) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let p = min(1, CGFloat(CACurrentMediaTime() - t0) / duration)
            self.panel.setFrameOrigin(NSPoint(x: start.x + (x1 - start.x) * p, y: start.y - drop * p * p))
            if p >= 1 {
                timer.invalidate()
                self.panel.setFrameOrigin(NSPoint(x: x1, y: scr.frame.minY))
                self.land(windowGone: windowGone)
            }
        }
    }

    /// Touchdown: a thud, a squash and a puff of dust on the impact frame; the crouch plays at real speed, then he
    /// springs back up faster. The bubble comes back as he straightens up.
    private func land(windowGone: Bool) {
        guard phase == .falling else { return }
        let info = lands[variant]
        let bottom = info?.bottom ?? 0.5, up = info?.up ?? 2.5
        run("land", markers: [
            (bottom, { [weak self] in self?.stage.setRate(self?.riseRate ?? 1) }),
            (bottom + (up - bottom) * 0.55, { [weak self] in
                // nearly up: the bubble comes back, and he can be poked, picked up or answered again
                guard let self, self.phase == .falling else { return }
                self.phase = .waiting
                if self.model.mode == .ask { self.say(Lines.landed(windowGone: windowGone), for: 3.0) }
                self.updateMousePassThrough()
            }),
        ], onEnd: { [weak self] in self?.settle(after: "land") })
        thud()
        squash()
        if let l = layout {
            Effects.burst(in: panel.contentView?.layer, at: CGPoint(x: l.headX, y: 10 * scale), kind: .dust,
                          scale: l.stage.height / 380)
        }
    }

    private func thud() {
        guard UserDefaults.standard.object(forKey: "soundOn") as? Bool ?? true, let s = thuds.randomElement() else { return }
        s.stop()
        s.play()
    }

    /// A quick cartoon squash and stretch about his feet.
    private func squash() {
        guard let layer = stage.layer, let l = layout else { return }
        let feet = CGPoint(x: l.headX, y: 10 * scale)
        func t(_ sx: CGFloat, _ sy: CGFloat) -> NSValue {
            var m = CATransform3DMakeTranslation(feet.x, feet.y, 0)
            m = CATransform3DScale(m, sx, sy, 1)
            return NSValue(caTransform3D: CATransform3DTranslate(m, -feet.x, -feet.y, 0))
        }
        let a = CAKeyframeAnimation(keyPath: "sublayerTransform")
        a.values = [t(1, 1), t(1.05, 0.92), t(0.98, 1.03), t(1, 1)]
        a.keyTimes = [0, 0.3, 0.65, 1]
        a.duration = 0.3
        a.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeInEaseOut),
                             CAMediaTimingFunction(name: .easeOut)]
        layer.add(a, forKey: "squash")
    }

    // MARK: sitting on a window

    /// Place him on the top edge of `w`, near its right end, if there's room above it for him and the bubble.
    private func sit(on w: Windows.Info) -> Bool {
        let l = BuddyLayout.load(from: clipsURL, scale: scale, sitting: variant, variant: variant)
        let top = NSPoint(x: w.frame.midX, y: w.frame.maxY - 1)
        guard let seat = l.seatY, let scr = NSScreen.screens.first(where: { NSMouseInRect(top, $0.frame, false) })
        else { return false }
        let vis = scr.visibleFrame
        let headX = max(w.frame.minX + 200 * scale, w.frame.maxX - 190 * scale)
        let origin = NSPoint(x: headX - l.headX, y: w.frame.maxY - seat)
        guard origin.y + l.panel.height <= vis.maxY,
              origin.x + l.popup.minX >= vis.minX + 4, origin.x + l.popup.maxX <= vis.maxX - 4 else { return false }
        apply(l, origin)
        screen = scr
        trackedWindow = w.id
        lastWindowFrame = w.frame
        return true
    }

    private func startTracking() {
        trackTimer?.invalidate()
        lastTrack = Date()
        trackTimer = every(1.0 / 60) { [weak self] _ in self?.track() }
    }

    private func stopTracking() {
        trackTimer?.invalidate(); trackTimer = nil
        trackedWindow = nil
        lastWindowFrame = nil
        wobble = 0; wobbleV = 0
        setWobble(0)
    }

    /// Follow the window he sits on; lean against its motion and settle back; fall if it goes away.
    private func track() {
        guard pose == .sit, let id = trackedWindow else { return }
        let now = Date(), dt = CGFloat(min(0.1, max(1.0 / 120, now.timeIntervalSince(lastTrack))))
        lastTrack = now
        guard let f = Windows.frame(id) else {
            if phase == .entering || phase == .waiting { fall(windowGone: true) } else { stopTracking() }
            return
        }
        var vx: CGFloat = 0
        if let last = lastWindowFrame, f != last {
            let dx = f.maxX - last.maxX, dy = f.maxY - last.maxY
            vx = dx / dt
            panel.setFrameOrigin(NSPoint(x: panel.frame.minX + dx, y: panel.frame.minY + dy))
            lastWindowFrame = f
        }
        // a damped spring: he leans back when the window moves under him, then rocks back upright
        let target = max(-0.3, min(0.3, vx * 0.00035))
        wobbleV += (90 * (target - wobble) - 9 * wobbleV) * dt
        wobble += wobbleV * dt
        setWobble(abs(wobble) < 0.0005 && abs(wobbleV) < 0.001 ? 0 : wobble)
    }

    /// Rotate him about his seat.
    private func setWobble(_ a: CGFloat) {
        guard let layer = stage.layer else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if a == 0 || pose != .sit {
            layer.sublayerTransform = CATransform3DIdentity
        } else if let l = layout, let seat = l.seatY {
            var t = CATransform3DMakeTranslation(l.headX, seat, 0)
            t = CATransform3DRotate(t, a, 0, 0, 1)
            layer.sublayerTransform = CATransform3DTranslate(t, -l.headX, -seat, 0)
        }
        CATransaction.commit()
    }

    // MARK: effects

    /// A little spray of water drops from his glass.
    private func splash() {
        guard let l = layout, phase == .reacting else { return }
        Effects.burst(in: panel.contentView?.layer, at: l.glass, kind: .drops, scale: l.stage.height / 380)
    }

    /// Confetti and a fanfare on the thumbs-up when the day's goal is reached.
    private func celebrate() {
        guard let l = layout else { return }
        Effects.burst(in: panel.contentView?.layer, at: CGPoint(x: l.headX, y: l.headY - 20 * scale), kind: .confetti,
                      scale: l.stage.height / 380)
        sound("Hero")
    }

    // MARK: layout

    /// The screen the user is working on: the one with the mouse.
    private func activeScreen() -> NSScreen? {
        let p = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) } ?? NSScreen.main
    }

    private func standing() -> BuddyLayout { BuddyLayout.load(from: clipsURL, scale: scale, variant: variant) }

    private func apply(_ l: BuddyLayout, _ origin: NSPoint) {
        layout = l
        panel.setFrame(NSRect(origin: origin, size: l.panel), display: false)
        stage.frame = l.stage
        pokeView.frame = l.body
        popup.frame = l.popup
        model.tailX = l.tailX
        pokeView.window?.invalidateCursorRects(for: pokeView)
    }

    // MARK: clicks

    /// Clicks pass through the panel except over the bubble and (while he waits) over him. The hot areas are checked
    /// on every mouse move, so the first click on him or the bubble always lands; a timer covers him moving under a
    /// still mouse.
    private func startMouseTracking() {
        stopMouseTracking()
        mouseTimer = every(1.0 / 30) { [weak self] _ in self?.updateMousePassThrough() }
        let types: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: types, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.updateMousePassThrough() }
        }) { mouseMonitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: types, handler: { [weak self] e in
            MainActor.assumeIsolated { self?.updateMousePassThrough() }
            return e
        }) { mouseMonitors.append(l) }
    }

    private func stopMouseTracking() {
        mouseTimer?.invalidate(); mouseTimer = nil
        mouseMonitors.forEach { NSEvent.removeMonitor($0) }
        mouseMonitors = []
    }

    private func updateMousePassThrough() {
        if debugIgnoreMouse { panel.ignoresMouseEvents = true; return }
        if phase == .dragging { panel.ignoresMouseEvents = false; return }
        let mouse = NSEvent.mouseLocation
        var hot = false
        if model.visible, model.mode == .ask, let win = popup.window {
            let bubble = win.convertToScreen(popup.convert(popup.bounds, to: nil))
            let fit = popup.fittingSize
            hot = NSMouseInRect(mouse, NSRect(x: bubble.minX, y: bubble.minY, width: bubble.width,
                                              height: min(fit.height, bubble.height)), false)
        }
        if !hot, phase == .waiting, pose == .sit || has("giggle") || has("hey") || has("dangle"),
           let win = pokeView.window {
            // a little margin around him, so a click on his edge still counts
            let body = win.convertToScreen(pokeView.convert(pokeView.bounds, to: nil)).insetBy(dx: -8, dy: -6)
            hot = NSMouseInRect(mouse, body, false)
        }
        panel.ignoresMouseEvents = !hot
    }
}

/// The click target over his body while he waits: a click pokes him, a drag picks him up.
final class PokeView: NSView {
    var onPoke: () -> Void = {}
    var onDragBegan: () -> Void = {}
    var onDragMoved: () -> Void = {}
    var onDragEnded: () -> Void = {}
    private var downAt: NSPoint?
    private var dragging = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { downAt = NSEvent.mouseLocation; dragging = false }
    override func mouseDragged(with event: NSEvent) {
        guard let d = downAt else { return }
        let m = NSEvent.mouseLocation
        if !dragging, hypot(m.x - d.x, m.y - d.y) > 4 { dragging = true; onDragBegan() }
        if dragging { onDragMoved() }
    }
    override func mouseUp(with event: NSEvent) {
        if dragging { onDragEnded() } else if downAt != nil { onPoke() }
        downAt = nil
        dragging = false
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
}
