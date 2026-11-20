import SwiftUI

/// Small anime touches (K-1): speed lines on a completion, «ДОН!» on a win, a manga panel for saved day summaries.
enum AnimeWin {
    /// A win only when there is something and all of it is done.
    static func allDone(_ done: [Bool]) -> Bool { !done.isEmpty && !done.contains(false) }
}

extension View {
    /// Speed lines and a short flash (~0.5 s) when `on` turns true.
    func speedLines(on: Bool) -> some View { modifier(AnimeBurst(on: on, stamp: false)) }
    /// A tilted «ДОН!» stamp (~1.2 s) with a success haptic when `on` turns true.
    func donStamp(on: Bool) -> some View { modifier(AnimeBurst(on: on, stamp: true)) }
    /// Frames the view as a manga panel: thick border, halftone dots.
    func mangaPanel() -> some View { modifier(MangaPanel()) }
}

private struct BurstValue {
    var scale: Double = 1
    var opacity: Double = 0
}

/// Plays once per false → true change; a value that is already true on appear does not fire.
private struct AnimeBurst: ViewModifier {
    let on: Bool
    let stamp: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shots = 0

    func body(content: Content) -> some View {
        let calm = reduceMotion
        let total = stamp ? 1.2 : 0.5
        let peak = calm ? 0.4 : 1.0
        content
            .overlay {
                art
                    .keyframeAnimator(initialValue: BurstValue(), trigger: shots) { view, v in
                        view.scaleEffect(v.scale).opacity(v.opacity)
                    } keyframes: { _ in
                        KeyframeTrack(\.scale) {
                            LinearKeyframe(calm ? 1 : (stamp ? 0.3 : 0.7), duration: 0)
                            SpringKeyframe(calm ? 1 : (stamp ? 1 : 1.25), duration: stamp ? 0.35 : 0.5, spring: .bouncy)
                        }
                        KeyframeTrack(\.opacity) {
                            LinearKeyframe(0, duration: 0)
                            LinearKeyframe(peak, duration: 0.08)
                            LinearKeyframe(peak, duration: stamp ? 0.7 : 0.1)
                            LinearKeyframe(0, duration: total - (stamp ? 0.78 : 0.18))
                        }
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .onChange(of: on) { old, new in
                if new && !old { shots += 1 }
            }
            .sensoryFeedback(.success, trigger: stamp ? shots : 0)
    }

    @ViewBuilder
    private var art: some View {
        if stamp {
            Text("ДОН!")
                .font(DS.Fonts.display(64, relativeTo: .largeTitle))
                .foregroundColor(DS.Colors.accent)
                .shadow(color: DS.Colors.textPrimary, radius: 0, x: -2, y: -2)
                .shadow(color: DS.Colors.ink, radius: 0, x: 4, y: 4)
                .rotationEffect(.degrees(-12))
                .fixedSize()
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.white.opacity(0.16))
                if !reduceMotion { SpeedLinesShape() }
            }
        }
    }
}

/// Radial lines from the edges toward the centre.
private struct SpeedLinesShape: View {
    var body: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let outer = hypot(size.width, size.height) / 2
            for i in 0..<28 {
                let a = Double(i) / 28 * 2 * .pi
                let inner = outer * (i.isMultiple(of: 3) ? 0.5 : 0.65)
                var p = Path()
                p.move(to: CGPoint(x: c.x + cos(a) * inner, y: c.y + sin(a) * inner))
                p.addLine(to: CGPoint(x: c.x + cos(a) * outer, y: c.y + sin(a) * outer))
                ctx.stroke(p, with: .color(DS.Colors.accent), lineWidth: i.isMultiple(of: 2) ? 2 : 1)
            }
        }
    }
}

private struct MangaPanel: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                ZStack {
                    DS.Colors.surface
                    Halftone()
                }
            }
            .overlay(Rectangle().stroke(DS.Colors.textPrimary, lineWidth: 3))
            .background(Rectangle().fill(DS.Colors.ink).offset(x: 4, y: 4))
    }
}

/// Tilted caption box of a manga panel.
struct MangaCaption: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(DS.Fonts.text(15, .bold, relativeTo: .subheadline))
            .foregroundColor(DS.Colors.ink)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(DS.Colors.textPrimary)
            .overlay(Rectangle().stroke(DS.Colors.ink, lineWidth: 2))
            .rotationEffect(.degrees(-2))
    }
}

private struct Halftone: View {
    var body: some View {
        Canvas { ctx, size in
            let step: CGFloat = 8
            var y: CGFloat = 0
            var row = 0
            while y < size.height + step {
                var x: CGFloat = row.isMultiple(of: 2) ? 0 : step / 2
                // Dots grow toward the bottom-right, like a screentone gradient.
                while x < size.width + step {
                    let r = 0.6 + 1.6 * (x / max(size.width, 1) + y / max(size.height, 1)) / 2
                    ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                             with: .color(DS.Colors.textPrimary.opacity(0.07)))
                    x += step
                }
                y += step
                row += 1
            }
        }
        .accessibilityHidden(true)
    }
}
