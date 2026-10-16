import AppKit
import SwiftUI

/// The eye break: every screen blurs and dims, and a countdown ring sits in the middle of the active one.
/// The buddy's panel stays above it (sharp, looking far away). Skip is always there, so nobody is locked out.
@MainActor
final class BreakOverlay {
    private var panels: [NSPanel] = []
    let model = BreakModel()
    var onSkip: (() -> Void)?

    var isShowing: Bool { !panels.isEmpty }

    func show(seconds: TimeInterval, on main: NSScreen) {
        hide(animated: false)
        model.total = seconds
        model.end = Date().addingTimeInterval(seconds)
        model.done = false
        for screen in NSScreen.screens {
            let p = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.level = .statusBar                       // over apps, the Dock and the menu bar; the buddy is one level up
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            p.hidesOnDeactivate = false

            let blur = NSVisualEffectView(frame: NSRect(origin: .zero, size: screen.frame.size))
            blur.material = .hudWindow
            blur.blendingMode = .behindWindow          // blurs whatever is on screen behind it
            blur.state = .active
            blur.appearance = NSAppearance(named: .darkAqua)
            blur.autoresizingMask = [.width, .height]
            let tint = NSView(frame: blur.bounds)
            tint.wantsLayer = true
            tint.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.35).cgColor
            tint.autoresizingMask = [.width, .height]
            blur.addSubview(tint)
            if screen == main {
                let host = FirstMouseHostingView(rootView: BreakTimerView(model: model, onSkip: { [weak self] in self?.onSkip?() }))
                host.frame = blur.bounds
                host.autoresizingMask = [.width, .height]
                blur.addSubview(host)
            }
            p.contentView = blur
            p.setFrame(screen.frame, display: false)
            p.alphaValue = 0
            p.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in ctx.duration = 0.5; p.animator().alphaValue = 1 }
            panels.append(p)
        }
    }

    /// "Eyes rested", then the blur fades away.
    func finish(after: TimeInterval = 1.4) {
        guard isShowing else { return }
        model.done = true
        DispatchQueue.main.asyncAfter(deadline: .now() + after) { [weak self] in self?.hide(animated: true) }
    }

    func hide(animated: Bool) {
        let old = panels
        panels = []
        guard animated else { old.forEach { $0.orderOut(nil) }; return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.5
            old.forEach { $0.animator().alphaValue = 0 }
        }, completionHandler: { old.forEach { $0.orderOut(nil) } })
    }
}

@MainActor
final class BreakModel: ObservableObject {
    @Published var end = Date()
    @Published var total: TimeInterval = 20
    @Published var done = false
}

/// The ring in the middle of the screen: 20 → 0, then a green check.
struct BreakTimerView: View {
    @ObservedObject var model: BreakModel
    var onSkip: () -> Void

    private let violet = Color(red: 0.65, green: 0.55, blue: 1.0)
    private let green = Color(red: 0.36, green: 0.89, blue: 0.54)

    var body: some View {
        TimelineView(.animation) { ctx in
            let left = max(0, model.end.timeIntervalSince(ctx.date))
            let elapsed = 1 - left / max(model.total, 1)
            VStack(spacing: 0) {
                ZStack {
                    Circle().stroke(Color.white.opacity(0.15), lineWidth: 14)
                    Circle()
                        .trim(from: 0, to: model.done ? 1 : 1 - elapsed)
                        .stroke(model.done ? green : violet, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    if model.done {
                        Image(systemName: "checkmark").font(.system(size: 78, weight: .bold)).foregroundStyle(green)
                            .transition(.scale.combined(with: .opacity))
                    } else {
                        VStack(spacing: 2) {
                            Text("\(Int(left.rounded(.up)))").font(.system(size: 96, weight: .bold)).monospacedDigit()
                            Text("seconds").font(.system(size: 18, weight: .semibold)).opacity(0.7)
                        }
                    }
                }
                .frame(width: 240, height: 240)
                Text(model.done ? "Eyes rested" : "Look far away")
                    .font(.system(size: 34, weight: .bold)).padding(.top, 34)
                Text(model.done ? "Back to it. Next eye break in a while 👋"
                                : "Find something about 6 m away: out of the window or across the room")
                    .font(.system(size: 17)).opacity(0.75).padding(.top, 10)
                Button(action: onSkip) { Text("Skip").font(.system(size: 14, weight: .medium)) }
                    .buttonStyle(.plain).opacity(model.done ? 0 : 0.55).padding(.top, 40)
            }
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .animation(.spring(response: 0.4, dampingFraction: 0.7), value: model.done)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
