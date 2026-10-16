import AppKit
import SwiftUI

/// What the speech bubble over the buddy's head shows. The app fills in the words; the view only lays them out.
@MainActor
final class PopupModel: ObservableObject {
    enum Mode { case ask, done, snoozed }
    @Published var mode: Mode = .ask
    @Published var visible = false
    @Published var title = ""
    @Published var message = ""
    /// the water bar ("750 ml of 2 L today"); off for eye and movement breaks
    @Published var showWater = true
    @Published var todayML = 0
    @Published var goalML = 2000
    /// x of the tail tip from the bubble's left edge (points): right over his head
    @Published var tailX: CGFloat = 100
    /// whose face is in the header (each character has his own)
    @Published var face: NSImage?
    var onYes: () -> Void = {}
    var onNo: () -> Void = {}
}

struct PopupView: View {
    @ObservedObject var model: PopupModel
    let face: NSImage

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(nsImage: model.face ?? face).resizable().frame(width: 22, height: 22).clipShape(Circle())
                Text(appName.uppercased()).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).kerning(0.4)
                Spacer()
                Text("now").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            Text(model.title).font(.system(size: 17, weight: .bold)).padding(.top, 10).fixedSize(horizontal: false, vertical: true)
            Text(model.message).font(.system(size: 13)).foregroundStyle(.secondary).padding(.top, 3)
                .fixedSize(horizontal: false, vertical: true)
            if model.showWater && model.mode != .snoozed {
                VStack(alignment: .leading, spacing: 5) {
                    Meter(progress: CGFloat(model.todayML) / CGFloat(max(model.goalML, 1)), color: Color(red: 0.11, green: 0.44, blue: 1.0))
                    Text("\(model.todayML) ml of \(litres(model.goalML)) today")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).monospacedDigit()
                }
                .padding(.top, 12)
            }
            if model.mode == .ask {
                HStack(spacing: 8) {
                    Button(action: model.onYes) { Text("Okay 🙌") }
                        .buttonStyle(PillStyle(primary: true))
                    Button(action: model.onNo) { Text("Not Now") }
                        .buttonStyle(PillStyle(primary: false))
                }
                .padding(.top, 14)
            }
        }
        .padding(16)
        .frame(width: 300, alignment: .leading)
        .background(
            Bubble(tailX: model.tailX)
                .fill(Color(nsColor: .windowBackgroundColor))
                .shadow(color: .black.opacity(0.28), radius: 14, y: 6)
        )
        .padding(.bottom, Bubble.tail)
        .scaleEffect(model.visible ? 1 : 0.55, anchor: UnitPoint(x: model.tailX / 300, y: 1))
        .opacity(model.visible ? 1 : 0)
        .animation(.spring(response: 0.38, dampingFraction: 0.72), value: model.visible)
        .animation(.easeInOut(duration: 0.2), value: model.mode)
        .padding(.leading, 10)                    // room for the shadow
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }
}

/// A thin rounded progress bar.
struct Meter: View {
    let progress: CGFloat
    let color: Color

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(color).frame(width: max(6, g.size.width * min(max(progress, 0), 1)))
            }
        }
        .frame(height: 6)
    }
}

/// Rounded card with a small tail pointing down at the buddy's head.
struct Bubble: Shape {
    static let tail: CGFloat = 12
    var tailX: CGFloat

    func path(in r: CGRect) -> Path {
        var p = Path(roundedRect: r, cornerRadius: 18)
        let x = min(max(tailX, 28), r.width - 28)
        // the tail overlaps the card by a few points so no seam shows where they meet; it runs right to left, the same
        // way round as the card's bottom edge, so the overlap fills instead of cancelling out
        p.move(to: CGPoint(x: x + 14, y: r.maxY - 6))
        p.addLine(to: CGPoint(x: x + 12, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: x, y: r.maxY + Bubble.tail), control: CGPoint(x: x + 3, y: r.maxY + 2))
        p.addQuadCurve(to: CGPoint(x: x - 12, y: r.maxY), control: CGPoint(x: x - 3, y: r.maxY + 2))
        p.addLine(to: CGPoint(x: x - 14, y: r.maxY - 6))
        p.closeSubpath()
        return p
    }
}

struct PillStyle: ButtonStyle {
    let primary: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .frame(maxWidth: .infinity, minHeight: 34)
            .foregroundStyle(primary ? Color.white : Color.primary)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(primary ? Color(red: 0.11, green: 0.44, blue: 1.0) : Color.primary.opacity(0.08))
            )
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .contentShape(Rectangle())
    }
}

/// Buttons in a non-activating panel must react to the first click.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
