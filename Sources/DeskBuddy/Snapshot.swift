import AppKit
import AVFoundation
import SwiftUI

/// `DeskBuddy --snapshot out.png [mode]`: renders what the corner of the screen looks like (a frame of the idle clip
/// with the bubble over his head, on a dark backdrop) without opening any window. For checking the layout and for
/// README screenshots.
/// mode: water (default) | eyes | move | prayer | done | goal | snoozed | break | rested | icon
@MainActor
enum Snapshot {
    static func run(path: String, mode: String) {
        if mode == "break" || mode == "rested" {   // the eye-break timer, on a dark stand-in for the blurred screen
            let m = BreakModel(); m.total = 20; m.end = Date().addingTimeInterval(12.4); m.done = mode == "rested"
            let r = ImageRenderer(content: BreakTimerView(model: m, onSkip: {}).frame(width: 900, height: 620)
                .background(Color(red: 0.16, green: 0.17, blue: 0.22)))
            r.scale = 1
            if let cg = r.cgImage { try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path)) }
            return
        }
        if mode == "icon" {   // the menu-bar drop at a few fill levels, side by side, on a light bar
            let img = NSImage(size: NSSize(width: 5 * 40, height: 40), flipped: false) { r in
                NSColor(white: 0.93, alpha: 1).setFill(); r.fill()
                for (i, lv) in [0.0, 0.25, 0.5, 0.75, 1.0].enumerated() {
                    let icon = dropIcon(level: lv); icon.isTemplate = false
                    icon.draw(in: NSRect(x: CGFloat(i) * 40 + 13, y: 11, width: 14, height: 18))
                }
                return true
            }
            let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            return
        }
        let res = Bundle.main.resourceURL!
        let clips = res.appendingPathComponent("clips")
        let layout = BuddyLayout.load(from: clips, scale: 1)
        let model = PopupModel()
        var c = Lines.Context(todayML: 750, nextTime: "3:45 PM")
        model.visible = true
        model.todayML = 750
        model.tailX = layout.tailX
        switch mode {
        case "prayer":
            c.prayerName = "Asar"; c.prayerTime = "4:18 PM"
            model.title = Lines.title(.prayer); model.message = Lines.ask(.prayer, c); model.showWater = false
            model.face = NSImage(contentsOf: res.appendingPathComponent("face_prayer.png"))
        case "eyes": model.title = Lines.title(.eyes); model.message = Lines.ask(.eyes, c); model.showWater = false
        case "move": model.title = Lines.title(.move); model.message = Lines.ask(.move, c); model.showWater = false
        case "done": c.todayML = 875; model.todayML = 875; (model.title, model.message) = Lines.water(c, .none); model.mode = .done
        case "goal": c.todayML = 2000; c.streak = 3; model.todayML = 2000; (model.title, model.message) = Lines.water(c, .goal); model.mode = .done
        case "snoozed": c.snoozeCount = 2; (model.title, model.message) = Lines.snoozed(c); model.mode = .snoozed
        default: model.title = Lines.title(.water); model.message = Lines.ask(.water, c)
        }
        let face = NSImage(contentsOf: res.appendingPathComponent("face.png")) ?? NSImage()

        let renderer = ImageRenderer(content: PopupView(model: model, face: face)
            .frame(width: layout.popup.width, height: layout.popup.height)
            .environment(\.colorScheme, .light))
        renderer.scale = 2
        guard let bubble = renderer.cgImage else { print("popup render failed"); exit(1) }

        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: clips.appendingPathComponent(mode == "prayer" ? "y_idle.mov" : "idle.mov")))
        gen.requestedTimeToleranceBefore = .zero; gen.requestedTimeToleranceAfter = .zero
        guard let person = try? gen.copyCGImage(at: CMTime(seconds: 0.2, preferredTimescale: 600), actualTime: nil) else {
            print("clip frame failed"); exit(1)
        }

        let W = Int(layout.panel.width * 2) + 200, H = Int(layout.panel.height * 2) + 60
        let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.12, green: 0.13, blue: 0.18, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        ctx.draw(person, in: layout.stage.applying(.init(scaleX: 2, y: 2)))
        ctx.draw(bubble, in: layout.popup.applying(.init(scaleX: 2, y: 2)))
        let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        print("wrote \(path)")
    }
}
