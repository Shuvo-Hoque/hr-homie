import AppKit
import ServiceManagement

/// Menu-bar item, settings menu and the schedules:
/// - water: every `intervalMinutes` while someone is at the Mac
/// - eyes: after `eyesMinutes` of continuous screen use (resets when they step away for 2 minutes)
/// - move: after `moveMinutes` of continuous use (resets after 5 minutes away)
/// - prayer: at each of the five prayer times in Kuala Lumpur (JAKIM), once, while someone is at the Mac
/// Each can be switched off in the menu.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let store = Store()
    private var buddy: BuddyController!
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var screenLocked = false

    private var nextWater = Date()
    private var eyesActive: TimeInterval = 0          // seconds of continuous use
    private var moveActive: TimeInterval = 0
    private var snoozedUntil: [Kind: Date] = [:]
    private var snoozeCount: [Kind: Int] = [:]
    private var lastTick = Date()
    private var lastFinished = Date.distantPast
    /// today's random peekaboo moment
    private var peekAt: (day: String, at: Date)?
    private let prayers = PrayerTimes()
    /// the prayer he's announcing / was last snoozed for
    private var prayer: PrayerTimes.Prayer?
    /// after "let's pray" the other reminders stay quiet for a while
    private var quietUntil = Date.distantPast
    private let prayerWindow: TimeInterval = 40 * 60     // he can still come this long after the prayer time
    private var lastRefresh = Date.distantPast
    /// the very first visit introduces him and says where the settings are
    private var welcome = false
    /// menu: "On My Window" asks for the window this once
    private var forceWindow = false

    /// No input for this long: away from the Mac, so reminders wait until they're back.
    private let awayAfter: TimeInterval = 120
    /// Away this long counts as a break for the eyes / for moving.
    private let eyesRestAfter: TimeInterval = 120
    private let moveRestAfter: TimeInterval = 300

    func applicationDidFinishLaunching(_ notification: Notification) {
        quitOtherCopies()
        buddy = BuddyController()
        buddy.onAnswer = { [weak self] kind, answer in self?.handle(kind, answer) ?? .none }
        buddy.onFinish = { [weak self] _ in self?.lastFinished = Date() }
        setUpStatusItem()
        nextWater = Date().addingTimeInterval(TimeInterval(store.intervalMinutes * 60))

        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenLocked = true }
        }
        dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenLocked = false }
        }

        // first launch: show him once so people see what to expect
        if !store.hasLaunchedBefore {
            store.hasLaunchedBefore = true
            welcome = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.remind(.water) }
        }
    }

    // MARK: schedule

    private var isPaused: Bool {
        if let until = store.pausedUntil, until > Date() { return true }
        return false
    }

    private func tick() {
        let now = Date()
        let dt = min(now.timeIntervalSince(lastTick), 30)
        lastTick = now
        store.rollDayIfNeeded()
        updateStatusItem()

        // continuous use: counts while they're using the Mac, resets when they step away long enough
        let idle = idleSeconds()
        if screenLocked || idle >= eyesRestAfter { eyesActive = 0 } else if idle < 60 { eyesActive += dt }
        if screenLocked || idle >= moveRestAfter { moveActive = 0 } else if idle < 60 { moveActive += dt }

        if now.timeIntervalSince(lastRefresh) > 3600 { prayers.refreshIfNeeded(); lastRefresh = now }

        guard !buddy.isShowing, !isPaused, !screenLocked, idle < awayAfter,
              now.timeIntervalSince(lastFinished) > 8 else { return }      // a moment between visits
        // prayer first, then movement (rarest), water, eyes; nothing else while they're at prayer
        if isDue(.prayer, now) { remind(.prayer); return }
        guard now >= quietUntil else { return }
        if let kind = [Kind.move, .water, .eyes].first(where: { isDue($0, now) }) { remind(kind); return }
        maybePeek(now, idle: idle)
    }

    /// Once a day, at a random moment between 10:30 and 16:30, while someone is actively using the Mac and nothing
    /// else is about to happen, he peeks in from the edge.
    private func maybePeek(_ now: Date, idle: TimeInterval) {
        guard store.peekEnabled, store.lastPeekDay != store.today, idle < 20,
              now.timeIntervalSince(lastFinished) > 180 else { return }
        if peekAt?.day != store.today {
            let cal = Calendar.current
            let start = cal.date(bySettingHour: 10, minute: 30, second: 0, of: now)!
            peekAt = (store.today, start.addingTimeInterval(.random(in: 0...(6 * 3600))))
        }
        guard let at = peekAt?.at, now >= at else { return }
        // not if a reminder is due within two minutes
        let soon = now.addingTimeInterval(120)
        if (store.isEnabled(.water) && soon >= nextWater) ||
           (store.isEnabled(.eyes) && eyesActive + 120 >= TimeInterval(store.eyesMinutes * 60)) ||
           (store.isEnabled(.move) && moveActive + 120 >= TimeInterval(store.moveMinutes * 60)) { return }
        store.lastPeekDay = store.today
        buddy.peek(scale: store.buddyScale)
    }

    private func isDue(_ k: Kind, _ now: Date) -> Bool {
        guard store.isEnabled(k) else { return false }
        if k == .prayer {
            let lead = TimeInterval(store.prayerLeadMinutes * 60)
            if let until = snoozedUntil[.prayer] {
                // snoozed: back after the snooze, as long as it's still that prayer's time
                guard now >= until, let p = prayer, now < p.at.addingTimeInterval(prayerWindow) else {
                    if let p = prayer, now >= p.at.addingTimeInterval(prayerWindow) { snoozedUntil[.prayer] = nil }
                    return false
                }
                return true
            }
            guard let p = prayers.current(at: now, lead: lead, window: prayerWindow),
                  !store.prayersShown.contains(p.id) else { return false }
            return true
        }
        if let until = snoozedUntil[k] { return now >= until }
        switch k {
        case .water: return now >= nextWater
        case .eyes: return eyesActive >= TimeInterval(store.eyesMinutes * 60)
        case .move: return moveActive >= TimeInterval(store.moveMinutes * 60)
        case .prayer: return false
        }
    }

    private func idleSeconds() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    private func context() -> Lines.Context {
        Lines.Context(intervalMinutes: store.intervalMinutes, amountML: store.amountML, todayML: store.todayML,
                      goalML: store.goalML, eyesMinutes: store.eyesMinutes, moveMinutes: store.moveMinutes,
                      snoozeCount: 0, snoozeSeconds: store.snoozeSeconds, streak: store.streak,
                      nextTime: nextWater.formatted(date: .omitted, time: .shortened))
    }

    /// Sometimes he sits on the window you're working in instead of the corner (never at prayer time).
    private func onWindow(_ kind: Kind) -> Bool {
        guard kind != .prayer else { return false }
        switch store.placement {
        case "corner": return false
        case "window": return true
        default: return Double.random(in: 0..<1) < 0.5
        }
    }

    private func remind(_ kind: Kind) {
        guard !buddy.isShowing else { return }
        var c = context()
        c.snoozeCount = snoozeCount[kind, default: 0]
        if kind == .prayer {
            // the prayer whose time it is (or the next one, when asked from the menu)
            let now = Date()
            let p = prayers.current(at: now, lead: TimeInterval(store.prayerLeadMinutes * 60), window: prayerWindow)
                ?? (snoozedUntil[.prayer] != nil ? prayer : nil) ?? prayers.next(after: now)
            guard let p else { return }
            if prayer?.id != p.id { snoozeCount[.prayer] = 0; c.snoozeCount = 0 }
            prayer = p
            c.prayerName = p.name; c.prayerTime = p.time
            if !store.prayersShown.contains(p.id) { store.prayersShown.append(p.id) }
        }
        let m = buddy.model
        m.title = Lines.title(kind)
        m.message = Lines.ask(kind, c)
        m.showWater = kind == .water
        m.todayML = store.todayML
        m.goalML = store.goalML
        if welcome && kind == .water {
            welcome = false
            m.title = "Hi, I'm your \(appName) 👋"
            m.message = Lines.keepTail("I'll bring you water every \(store.intervalMinutes) minutes. Settings: the drop in your menu bar, or open \(appName) again.")
        }
        buddy.show(kind, scale: store.buddyScale, onWindow: forceWindow || onWindow(kind))
        forceWindow = false
    }

    private func handle(_ kind: Kind, _ answer: BuddyController.Answer) -> Milestone {
        let now = Date()
        var milestone = Milestone.none
        var c = context()
        switch answer {
        case .yes:
            snoozeCount[kind] = 0
            snoozedUntil[kind] = nil
            switch kind {
            case .water:
                let goal = store.goalML, before = store.todayML
                store.logDrink()
                let after = store.todayML
                milestone = before >= goal ? .beyond : after >= goal ? .goal : (before * 2 < goal && after * 2 >= goal) ? .half : .none
                if milestone == .goal { store.recordGoalMet() }
                nextWater = now.addingTimeInterval(TimeInterval(store.intervalMinutes * 60))
                c = context()
                (buddy.model.title, buddy.model.message) = Lines.water(c, milestone)
                buddy.model.todayML = after
            case .eyes:
                eyesActive = 0                          // the timer in the middle of the screen takes over
            case .move:
                moveActive = 0
                (buddy.model.title, buddy.model.message) = Lines.moveDone
            case .prayer:
                c.prayerName = prayer?.name ?? ""
                (buddy.model.title, buddy.model.message) = Lines.prayerGo(c)
                quietUntil = now.addingTimeInterval(20 * 60)          // praying: the other reminders wait
            }
        case .no:
            snoozeCount[kind, default: 0] += 1
            c.snoozeCount = snoozeCount[kind]!
            if kind == .prayer {
                // gentle, and never the 10-second nag
                snoozedUntil[kind] = now.addingTimeInterval(TimeInterval(max(store.snoozeSeconds, 300)))
                (buddy.model.title, buddy.model.message) = Lines.prayerLater(c)
            } else {
                snoozedUntil[kind] = now.addingTimeInterval(TimeInterval(store.snoozeSeconds))
                (buddy.model.title, buddy.model.message) = Lines.snoozed(c)
            }
        }
        updateStatusItem()
        return milestone
    }

    // MARK: menu bar

    /// Opening the app again (Applications, Spotlight, Launchpad) while it runs pops its menu up at the mouse pointer.
    /// On a MacBook with a crowded menu bar, macOS hides the drop behind the notch, so this is the way in that always works.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMenuAtPointer()
        return false
    }

    private func showMenuAtPointer() {
        guard let menu = statusItem?.menu else { return }
        NSApp.activate(ignoringOtherApps: true)
        menuNeedsUpdate(menu)
        // At the pointer, nudged just enough to fit the whole menu on screen: low down, AppKit would squeeze it
        // above the Dock and make you scroll.
        var p = NSEvent.mouseLocation
        if let vf = NSScreen.screens.first(where: { NSMouseInRect(p, $0.frame, false) })?.visibleFrame {
            let size = menu.size
            p.x = min(max(p.x, vf.minX), vf.maxX - size.width)
            p.y = min(max(p.y, vf.minY + size.height), vf.maxY)
        }
        menu.popUp(positioning: nil, at: p, in: nil)
    }

    /// One copy at a time: two copies (say one on the Desktop and one in Applications) would each put an item in
    /// the menu bar and both send him. The copy opened last wins, so opening a new build replaces the old one.
    private func quitOtherCopies() {
        let me = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != me }
        others.forEach { $0.terminate() }
    }

    /// Just the drop (about 30 pt), filling up with the day's water: on a MacBook with a notch, a full menu bar hides the
    /// leftmost items behind it, and the compact icon still fits in the gap right of the notch. Today's total is in
    /// the menu and the tooltip. `autosaveName` keeps the spot if you ⌘-drag it somewhere else.
    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.autosaveName = "DeskBuddy"
        statusItem.button?.imagePosition = .imageOnly
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateStatusItem()
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        let today = store.todayML, goal = max(store.goalML, 1)
        button.image = dropIcon(level: CGFloat(today) / CGFloat(goal))
        button.toolTip = "\(appName) · \(today) ml of \(litres(store.goalML)) today"
    }

    private func minutes(_ s: TimeInterval) -> String {
        let m = Int(ceil(max(0, s) / 60))
        return m <= 1 ? "a minute" : "\(m) min"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let now = Date()
        let today = store.todayML, goal = store.goalML
        menu.addItem(info("💧 Today: \(today) ml of \(litres(goal))  (\(min(100, today * 100 / max(goal, 1)))%)"))
        if store.streak > 0 { menu.addItem(info("🔥 \(store.streak)-day streak")) }
        if isPaused, let until = store.pausedUntil {
            menu.addItem(info("Paused until \(until.formatted(date: .omitted, time: .shortened))"))
        } else if buddy.isShowing {
            menu.addItem(info("He's on your screen now"))
        } else {
            var next: [String] = []
            if store.isEnabled(.water) { next.append("water in \(minutes(snoozedUntil[.water]?.timeIntervalSince(now) ?? nextWater.timeIntervalSince(now)))") }
            if store.isEnabled(.eyes) { next.append("eyes in \(minutes(snoozedUntil[.eyes]?.timeIntervalSince(now) ?? TimeInterval(store.eyesMinutes * 60) - eyesActive))") }
            if store.isEnabled(.move) { next.append("walk in \(minutes(snoozedUntil[.move]?.timeIntervalSince(now) ?? TimeInterval(store.moveMinutes * 60) - moveActive))") }
            menu.addItem(info(next.isEmpty ? "All reminders are off" : "Next: " + next.joined(separator: " · ")))
        }
        if store.isEnabled(.prayer), let p = prayers.next(after: now) {
            menu.addItem(info("🕌 Next prayer: \(p.name) at \(p.time)"))
        }
        menu.addItem(.separator())

        if buddy.isShowing {
            menu.addItem(item("Send Him Away", #selector(dismissBuddy)))
        } else {
            let now = NSMenuItem(title: "Remind Me Now", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for k in Kind.allCases {
                let i = item(k.menuTitle, #selector(remindNow(_:))); i.representedObject = k.rawValue
                sub.addItem(i)
            }
            sub.addItem(item("👋 Peekaboo", #selector(peekNow)))
            sub.addItem(.separator())
            sub.addItem(item("🪟 💧 Water, on My Window", #selector(remindOnWindow)))
            now.submenu = sub
            menu.addItem(now)
        }
        menu.addItem(item("I Just Drank (+\(store.amountML) ml)", #selector(logManual)))
        menu.addItem(.separator())

        menu.addItem(info("Reminders"))
        for k in Kind.allCases {
            let i = item(k.menuTitle, #selector(toggleKind(_:))); i.representedObject = k.rawValue
            i.state = store.isEnabled(k) ? .on : .off
            menu.addItem(i)
        }
        let peek = item("👋 Peekaboo Visits", #selector(togglePeek))
        peek.state = store.peekEnabled ? .on : .off
        peek.toolTip = "Once a day he peeks in from the edge of the screen and waves"
        menu.addItem(peek)
        menu.addItem(.separator())

        let water = NSMenuItem(title: "Water Settings", action: nil, keyEquivalent: ""); let ws = NSMenu()
        ws.addItem(choices("Remind Every", [15, 20, 30, 45, 60], store.intervalMinutes, { "\($0) minutes" }, #selector(setInterval(_:))))
        ws.addItem(choices("Amount Each Time", [100, 125, 150, 200, 250], store.amountML, { "\($0) ml" }, #selector(setAmount(_:))))
        ws.addItem(choices("Daily Goal", [1500, 2000, 2500, 3000], store.goalML, { litres($0) }, #selector(setGoal(_:))))
        water.submenu = ws
        menu.addItem(water)
        menu.addItem(choices("Eye Break After", [15, 20, 30, 45], store.eyesMinutes, { "\($0) minutes on screen" }, #selector(setEyes(_:))))
        menu.addItem(choices("Walk After", [30, 45, 60, 90], store.moveMinutes, { "\($0) minutes on screen" }, #selector(setMove(_:))))
        let pray = NSMenuItem(title: "Prayer Settings", action: nil, keyEquivalent: ""); let ps = NSMenu()
        ps.addItem(choices("Remind", [0, 5, 10, 15], store.prayerLeadMinutes,
                           { $0 == 0 ? "At prayer time" : "\($0) minutes before" }, #selector(setPrayerLead(_:))))
        ps.addItem(info("Times: JAKIM e-Solat, \(PrayerTimes.place) (\(PrayerTimes.zone))"))
        for p in prayers.prayers(on: now) { ps.addItem(info("   \(p.name)  \(p.time)")) }
        pray.submenu = ps
        menu.addItem(pray)
        menu.addItem(choices("“Not Now” Waits", [10, 60, 300, 600], store.snoozeSeconds,
                             { $0 < 60 ? "\($0) seconds" : $0 == 60 ? "1 minute" : "\($0 / 60) minutes" }, #selector(setSnooze(_:))))
        let placements = [("corner", "In the Corner"), ("mix", "Sometimes on Your Window"), ("window", "On Your Window When He Can")]
        let where_ = NSMenuItem(title: "Where He Shows Up", action: nil, keyEquivalent: ""); let wm = NSMenu()
        for (key, title) in placements {
            let i = item(title, #selector(setPlacement(_:))); i.representedObject = key
            i.state = store.placement == key ? .on : .off
            wm.addItem(i)
        }
        where_.submenu = wm
        menu.addItem(where_)
        menu.addItem(choices("Buddy Size", [80, 100, 125], Int(store.buddyScale * 100),
                             { ["80": "Small", "100": "Medium", "125": "Large"]["\($0)"]! }, #selector(setSize(_:))))
        let sound = item("Sound", #selector(toggleSound))
        sound.state = store.soundOn ? .on : .off
        menu.addItem(sound)
        let login = item("Open at Login", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())

        if isPaused {
            menu.addItem(item("Resume Reminders", #selector(resume)))
        } else {
            menu.addItem(item("Pause for 1 Hour", #selector(pauseHour)))
            menu.addItem(item("Pause Until Tomorrow", #selector(pauseTomorrow)))
        }
        menu.addItem(item("Reset Today", #selector(resetToday)))
        menu.addItem(.separator())
        menu.addItem(item("Quit \(appName)", #selector(quit)))
    }

    private func info(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: ""); i.isEnabled = false; return i
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: ""); i.target = self; return i
    }

    private func choices(_ title: String, _ values: [Int], _ current: Int, _ label: (Int) -> String, _ action: Selector) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for v in values {
            let i = item(label(v), action); i.tag = v; i.state = v == current ? .on : .off
            sub.addItem(i)
        }
        parent.submenu = sub
        return parent
    }

    // MARK: actions

    @objc private func remindNow(_ i: NSMenuItem) {
        if let k = Kind(rawValue: i.representedObject as? String ?? "") { remind(k) }
    }
    @objc private func peekNow() { buddy.peek(scale: store.buddyScale) }
    @objc private func remindOnWindow() { forceWindow = true; remind(.water) }
    @objc private func setPlacement(_ i: NSMenuItem) { if let k = i.representedObject as? String { store.placement = k } }
    @objc private func togglePeek() { store.peekEnabled.toggle() }
    @objc private func toggleKind(_ i: NSMenuItem) {
        guard let k = Kind(rawValue: i.representedObject as? String ?? "") else { return }
        store.setEnabled(k, !store.isEnabled(k))
        snoozedUntil[k] = nil
        if k == .water { nextWater = Date().addingTimeInterval(TimeInterval(store.intervalMinutes * 60)) }
        updateStatusItem()
    }
    @objc private func dismissBuddy() {
        snoozedUntil[buddy.kind] = Date().addingTimeInterval(TimeInterval(store.snoozeSeconds))
        buddy.dismiss()
    }
    @objc private func logManual() {
        store.logDrink()
        if store.todayML >= store.goalML { store.recordGoalMet() }
        nextWater = Date().addingTimeInterval(TimeInterval(store.intervalMinutes * 60))
        updateStatusItem()
    }
    @objc private func setInterval(_ i: NSMenuItem) { store.intervalMinutes = i.tag; nextWater = Date().addingTimeInterval(TimeInterval(i.tag * 60)) }
    @objc private func setAmount(_ i: NSMenuItem) { store.amountML = i.tag }
    @objc private func setGoal(_ i: NSMenuItem) { store.goalML = i.tag; updateStatusItem() }
    @objc private func setEyes(_ i: NSMenuItem) { store.eyesMinutes = i.tag }
    @objc private func setMove(_ i: NSMenuItem) { store.moveMinutes = i.tag }
    @objc private func setSnooze(_ i: NSMenuItem) { store.snoozeSeconds = i.tag }
    @objc private func setPrayerLead(_ i: NSMenuItem) { store.prayerLeadMinutes = i.tag }
    @objc private func setSize(_ i: NSMenuItem) { store.buddyScale = Double(i.tag) / 100 }
    @objc private func toggleSound() { store.soundOn.toggle() }
    @objc private func pauseHour() { store.pausedUntil = Date().addingTimeInterval(3600) }
    @objc private func pauseTomorrow() {
        let cal = Calendar.current
        store.pausedUntil = cal.date(bySettingHour: 8, minute: 0, second: 0, of: cal.date(byAdding: .day, value: 1, to: Date())!)
    }
    @objc private func resume() {
        store.pausedUntil = nil
        nextWater = Date().addingTimeInterval(TimeInterval(store.intervalMinutes * 60))
    }
    @objc private func resetToday() { store.resetToday(); updateStatusItem() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't change Open at Login"
            alert.informativeText = "\(error.localizedDescription)\n\nMove \(appName) to Applications and try again, or add it in System Settings › General › Login Items."
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }
}
