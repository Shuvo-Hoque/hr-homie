import AppKit
import QuartzCore

/// One-shot particle bursts: water drops when he drinks, confetti when the day's goal is reached.
@MainActor
enum Effects {
    enum Kind { case drops, confetti, dust }

    static func burst(in host: CALayer?, at point: CGPoint, kind: Kind, scale: CGFloat = 1) {
        guard let host else { return }
        let e = CAEmitterLayer()
        e.frame = host.bounds
        e.emitterPosition = point
        e.emitterShape = .point
        e.beginTime = CACurrentMediaTime()
        e.emitterCells = kind == .drops ? dropCells(scale) : kind == .dust ? dustCells(scale) : confettiCells(scale)
        e.zPosition = 10
        host.addSublayer(e)
        DispatchQueue.main.asyncAfter(deadline: .now() + (kind == .drops ? 0.18 : kind == .dust ? 0.07 : 0.3)) { e.birthRate = 0 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { e.removeFromSuperlayer() }
    }

    private static func dropCells(_ s: CGFloat) -> [CAEmitterCell] {
        [NSColor(red: 0.35, green: 0.65, blue: 1, alpha: 1), NSColor(red: 0.55, green: 0.8, blue: 1, alpha: 1),
         NSColor(red: 0.15, green: 0.5, blue: 1, alpha: 1)].map { color in
            let c = CAEmitterCell()
            c.contents = symbol("drop.fill", color: color, size: 22)
            c.birthRate = 30
            c.lifetime = 1.4
            c.velocity = 240 * s; c.velocityRange = 90 * s
            c.emissionLongitude = .pi / 2; c.emissionRange = .pi / 3     // upwards, in a fan
            c.yAcceleration = -620 * s                                   // and falling back
            c.scale = 0.55 * s; c.scaleRange = 0.25 * s
            c.alphaSpeed = -0.55
            return c
        }
    }

    /// A low puff of dust kicked out to both sides of his feet.
    private static func dustCells(_ s: CGFloat) -> [CAEmitterCell] {
        let puff = soft(NSColor(calibratedRed: 0.86, green: 0.82, blue: 0.75, alpha: 0.75), size: 28)
        return [0, CGFloat.pi].map { dir in
            let c = CAEmitterCell()
            c.contents = puff
            c.birthRate = 140
            c.lifetime = 0.55; c.lifetimeRange = 0.15
            c.velocity = 120 * s; c.velocityRange = 50 * s
            c.emissionLongitude = dir; c.emissionRange = 0.3
            c.yAcceleration = 50 * s                                      // drifts up a little as it slows
            c.scale = 0.45 * s; c.scaleRange = 0.2 * s; c.scaleSpeed = 0.9 * s
            c.alphaSpeed = -1.6
            return c
        }
    }

    private static func soft(_ color: NSColor, size: CGFloat) -> CGImage? {
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { r in
            let g = NSGradient(colors: [color, color.withAlphaComponent(0)])
            g?.draw(in: NSBezierPath(ovalIn: r), relativeCenterPosition: .zero)
            return true
        }
        var r = NSRect(origin: .zero, size: img.size)
        return img.cgImage(forProposedRect: &r, context: nil, hints: nil)
    }

    private static func confettiCells(_ s: CGFloat) -> [CAEmitterCell] {
        let colors: [NSColor] = [.systemPink, .systemYellow, .systemBlue, .systemGreen, .systemPurple, .systemOrange]
        return colors.map { color in
            let c = CAEmitterCell()
            c.contents = piece(color)
            c.birthRate = 45
            c.lifetime = 2.6
            c.velocity = 330 * s; c.velocityRange = 120 * s
            c.emissionLongitude = .pi / 2; c.emissionRange = .pi / 2.2
            c.yAcceleration = -380 * s
            c.spin = 3; c.spinRange = 8
            c.scale = 0.9 * s; c.scaleRange = 0.4 * s
            c.alphaSpeed = -0.3
            return c
        } + dropCells(s).map { $0.birthRate = 12; return $0 }
    }

    private static func symbol(_ name: String, color: NSColor, size: CGFloat) -> CGImage? {
        let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: .bold).applying(.init(paletteColors: [color]))
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) else { return nil }
        var r = NSRect(origin: .zero, size: img.size)
        return img.cgImage(forProposedRect: &r, context: nil, hints: nil)
    }

    private static func piece(_ color: NSColor) -> CGImage? {
        let img = NSImage(size: NSSize(width: 10, height: 16), flipped: false) { r in
            color.setFill()
            NSBezierPath(roundedRect: r, xRadius: 2, yRadius: 2).fill()
            return true
        }
        var r = NSRect(origin: .zero, size: img.size)
        return img.cgImage(forProposedRect: &r, context: nil, hints: nil)
    }
}

/// The menu-bar drop: an outline that fills from the bottom as the day's water adds up.
func dropIcon(level: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: 14, height: 18), flipped: false) { rect in
        let r = rect.insetBy(dx: 1.5, dy: 1.2)
        let w = r.width
        let p = NSBezierPath()
        p.move(to: NSPoint(x: r.midX, y: r.maxY))
        p.curve(to: NSPoint(x: r.minX, y: r.minY + w / 2), controlPoint1: NSPoint(x: r.midX - w * 0.18, y: r.maxY - r.height * 0.28),
                controlPoint2: NSPoint(x: r.minX, y: r.minY + w * 0.95))
        p.appendArc(withCenter: NSPoint(x: r.midX, y: r.minY + w / 2), radius: w / 2, startAngle: 180, endAngle: 360)
        p.curve(to: NSPoint(x: r.midX, y: r.maxY), controlPoint1: NSPoint(x: r.maxX, y: r.minY + w * 0.95),
                controlPoint2: NSPoint(x: r.midX + w * 0.18, y: r.maxY - r.height * 0.28))
        p.close()
        NSColor.black.setStroke()
        p.lineWidth = 1.4
        p.stroke()
        NSGraphicsContext.saveGraphicsState()
        p.addClip()
        NSColor.black.setFill()
        NSRect(x: rect.minX, y: r.minY, width: rect.width, height: r.height * min(max(level, 0), 1)).fill()
        NSGraphicsContext.restoreGraphicsState()
        return true
    }
    img.isTemplate = true            // drawn in the menu bar's own colour (light or dark)
    return img
}
