import AppKit

/// `DeskBuddy --demo [outdir] [yes]` (yes: answer Okay instead of Not Now): a scripted visit for checking motion without a mouse. He walks in, gets dropped in the
/// middle-right of the screen, answers "Not Now", and walks off by the nearest edge. Logs his window frame and the clip
/// on screen every 0.1 s and saves a capture of his window every 0.5 s.
@MainActor
enum Demo {
    static func run() {
        let out = CommandLine.arguments.first { $0.hasPrefix("/") && $0 != CommandLine.arguments[0] } ?? NSTemporaryDirectory()
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let buddy = BuddyController()
        buddy.model.title = Lines.title(.water)
        buddy.model.message = "Demo"
        buddy.onAnswer = { _, _ in .none }
        var log = ""
        let t0 = CACurrentMediaTime()
        var shot = 0
        // DEMO_DENSE="from,to": capture every tick in that window (default: the drop and landing)
        let d = (ProcessInfo.processInfo.environment["DEMO_DENSE"] ?? "5.6,9.6").split(separator: ",").compactMap { Double($0) }
        let dense = (d.first ?? 5.6, d.last ?? 9.6)
        typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        let cg = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW)
        let capture = unsafeBitCast(dlsym(cg, "CGWindowListCreateImage")!, to: Capture.self)
        buddy.onFinish = { _ in
            log += String(format: "%.2f finished\n", CACurrentMediaTime() - t0)
            try? log.write(toFile: out + "/demo.log", atomically: true, encoding: .utf8)
            exit(0)
        }
        buddy.debugIgnoreMouse = true
        buddy.show(.water, scale: 1)
        Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { _ in
            MainActor.assumeIsolated {
                let t = CACurrentMediaTime() - t0
                let f = buddy.debugFrame
                log += String(format: "%.2f %@ %@ x=%.0f y=%.0f clip=%.2f\n", t, "\(buddy.debugPhase)", buddy.debugRole, f.minX, f.minY, buddy.debugClipTime)
                if Int(t * 10) % 5 == 0 || (t > dense.0 && t < dense.1), let img = capture(.null, 1 << 3, UInt32(buddy.debugWindowNumber), 1)?.takeRetainedValue() {
                    // encode off the main thread: PNG-encoding Retina captures takes long enough to stall the run
                    let path = String(format: "%@/shot_%03d_%.2f_%.0f_%.0f.png", out, shot, t, f.minX, f.minY)
                    DispatchQueue.global(qos: .utility).async {
                        try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?
                            .write(to: URL(fileURLWithPath: path))
                    }
                    shot += 1
                }
            }
        }
        let screen = NSScreen.main!.frame
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.5) {
            // DEMO_DROP_X: where across the screen to drop him (fraction of its width, default 0.7)
            let fx = Double(ProcessInfo.processInfo.environment["DEMO_DROP_X"] ?? "") ?? 0.7
            buddy.debugDrop(at: NSPoint(x: screen.minX + screen.width * fx, y: screen.minY + screen.height * 0.6))
        }
        let answer: BuddyController.Answer = CommandLine.arguments.contains("yes") ? .yes : .no
        DispatchQueue.main.asyncAfter(deadline: .now() + 9.5) { buddy.debugAnswer(answer) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            try? log.write(toFile: out + "/demo.log", atomically: true, encoding: .utf8); exit(1)
        }
        app.run()
    }
}
