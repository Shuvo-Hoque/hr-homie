import AppKit

// A menu-bar app (LSUIElement): no Dock icon, no main window.
MainActor.assumeIsolated {
    let args = CommandLine.arguments
    if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
        Snapshot.run(path: args[i + 1], mode: i + 2 < args.count ? args[i + 2] : "ask")
        exit(0)
    }
    if args.contains("--prayers") {   // print today's and the next prayer times (KL, JAKIM)
        let pt = PrayerTimes(), now = Date()
        for p in pt.prayers(on: now) { print(p.name, p.time, p.id) }
        if let n = pt.next(after: now) { print("next:", n.name, n.time) }
        exit(0)
    }
    if args.contains("--demo") {          // scripted run: drop him mid-screen, answer Not Now, log where he goes
        Demo.run(); return
    }
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}
