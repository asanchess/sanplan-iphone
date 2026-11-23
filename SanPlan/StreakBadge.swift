import SwiftUI

/// How hot a streak looks: grey → lavender → purple → coral → gold.
enum StreakTier: Equatable {
    case none, warm, purple, hot, gold

    static func of(_ count: Int) -> StreakTier {
        switch count {
        case ..<1: return .none
        case 1...2: return .warm
        case 3...6: return .purple
        case 7...29: return .hot
        default: return .gold
        }
    }

    var color: Color {
        switch self {
        case .none: return DS.Colors.textMuted
        case .warm: return DS.Colors.today
        case .purple: return DS.Colors.accent
        case .hot: return DS.Colors.workout
        case .gold: return DS.Colors.warning
        }
    }
}

/// A hand-drawn manga spark: one tall flame tongue with a curled tip.
struct StreakSpark: Shape {
    func path(in r: CGRect) -> Path {
        let w = r.width, h = r.height
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x * w, y: r.minY + y * h) }
        var path = Path()
        path.move(to: p(0.5, 1))
        path.addCurve(to: p(0.08, 0.58), control1: p(0.22, 1), control2: p(0.04, 0.82))
        path.addCurve(to: p(0.32, 0.22), control1: p(0.12, 0.42), control2: p(0.28, 0.36))
        path.addCurve(to: p(0.44, 0.42), control1: p(0.36, 0.3), control2: p(0.4, 0.36))
        path.addCurve(to: p(0.62, 0), control1: p(0.5, 0.26), control2: p(0.48, 0.08))
        path.addCurve(to: p(0.94, 0.62), control1: p(0.86, 0.18), control2: p(0.98, 0.42))
        path.addCurve(to: p(0.5, 1), control1: p(0.92, 0.84), control2: p(0.76, 1))
        path.closeSubpath()
        return path
    }
}

/// Streak badge: ink-outlined spark with an offset ink shadow and the number in Dela.
struct StreakBadge: View {
    let count: Int
    var unit: HabitStreak.Unit = .days
    /// The streak grew today: a gentle pulse (off with Reduce Motion).
    var extendedToday = false
    var size: CGFloat = 22

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Hidden tabs stay mounted: the endless pulse would keep redrawing them, so it rests until the tab is shown.
    @Environment(\.tabIsActive) private var tabIsActive
    @State private var pulse = false

    private var tier: StreakTier { StreakTier.of(count) }

    var body: some View {
        HStack(spacing: 4) {
            ZStack {
                StreakSpark().fill(DS.Colors.drop).offset(y: 2)
                StreakSpark().fill(tier.color)
                StreakSpark().stroke(DS.Colors.edge, lineWidth: 1)
            }
            .frame(width: size * 0.8, height: size)
            .shadow(color: tier == .gold ? tier.color.opacity(0.8) : .clear, radius: 6)
            Text("\(count)")
                .font(DS.Fonts.display(size * 0.8, relativeTo: .headline))
                .monospacedDigit()
                .foregroundColor(tier.color)
        }
        .scaleEffect(pulse ? 1.06 : 1)
        .onAppear { startPulse() }
        .onChange(of: tabIsActive) { _, _ in startPulse() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(unit == .days ? "Серия \(count) дней" : "Серия \(count) недель")
    }

    private func startPulse() {
        guard extendedToday, !reduceMotion, tabIsActive else {
            var still = Transaction()
            still.disablesAnimations = true
            withTransaction(still) { pulse = false }
            return
        }
        withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
    }
}
