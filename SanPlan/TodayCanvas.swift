import SwiftUI

// Pieces of «Сегодня» and «Итоги» drawn 1:1 from docs/design/canvas-r5/Main.html and Summary.html.
// Sizes, radii and shadows are the canvas numbers; colours come from the section accent unless noted.

/// Canvas colours of the Today hero that are not section tokens: the hero keeps the canvas violet gradient (Main.html).
enum TodayPalette {
    static let heroStart = DS.Colors.hex(0x6A48D7)
    static let heroEnd = DS.Colors.hex(0x8B6CF0)
    static let heroButtonText = DS.Colors.hex(0x4A2BB0)
    static let ringTrack = DS.Colors.dyn(0xE9E2F6, 0x33295A)
    static let boxBorder = DS.Colors.dyn(0xCFC3EA, 0x5A4A8A)
}

enum TodayFormat {
    /// «6 500», «1,2 млн»: whole tenge for a ring that has room for a few characters.
    static func short(_ tenge: Int64) -> String {
        if abs(tenge) >= 1_000_000 {
            let millions = Double(tenge) / 1_000_000
            let text = String(format: "%.1f", millions).replacingOccurrences(of: ".", with: ",")
            return (text.hasSuffix(",0") ? String(text.dropLast(2)) : text) + " млн"
        }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: tenge)) ?? "\(tenge)"
    }

    /// «11:00» from minutes after midnight.
    static func clock(_ minutes: Int) -> String {
        String(format: "%02d:%02d", (minutes / 60) % 24, minutes % 60)
    }

    /// CSS `skewX(-deg)` around the centre of a view of this height.
    static func skew(_ degrees: Double, height: CGFloat) -> CGAffineTransform {
        let t = CGFloat(tan(degrees * .pi / 180))
        return CGAffineTransform(a: 1, b: 0, c: -t, d: 1, tx: t * height / 2, ty: 0)
    }
}

/// The glow and the dot pattern in the top right corner of every canvas screen, in the section colour.
struct TodayBackdrop: View {
    @Environment(\.sectionAccent) private var accent

    var body: some View {
        let tint = accent
        ZStack(alignment: .topTrailing) {
            Circle()
                .fill(RadialGradient(colors: [tint.opacity(0.22), tint.opacity(0)], center: .center, startRadius: 0, endRadius: 154))
                .frame(width: 320, height: 320)
                .offset(x: 90, y: -110)
            Canvas { context, size in
                let cx = size.width * 0.72, cy = size.height * 0.28
                let reach: CGFloat = 159
                var y: CGFloat = 5.5
                while y < size.height {
                    var x: CGFloat = 5.5
                    while x < size.width {
                        let dx = x - cx, dy = y - cy
                        let fade = max(0, 1 - (dx * dx + dy * dy).squareRoot() / reach)
                        if fade > 0 {
                            context.fill(Path(ellipseIn: CGRect(x: x - 1.9, y: y - 1.9, width: 3.8, height: 3.8)),
                                         with: .color(tint.opacity(Double(fade) * 0.3)))
                        }
                        x += 11
                    }
                    y += 11
                }
            }
            .frame(width: 230, height: 230)
            .offset(x: 30, y: -30)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// «ГЛАВНОЕ СЕЙЧАС»: the inked violet card with two light stripes and the skewed white chip.
/// The card opens the place; the chip does the main action («Начать» starts the workout).
struct TodayHeroCard: View {
    let hero: TodayHero
    let open: () -> Void
    let primary: () -> Void

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 14) {
                Text(hero.kicker.uppercased())
                    .font(DS.Fonts.text(13, .bold, relativeTo: .caption))
                    .tracking(0.8)
                    .opacity(0.85)
                    .lineLimit(1)
                Text(hero.title)
                    .font(DS.Fonts.display(24, relativeTo: .title2))
                    .shadow(color: DS.Colors.drop, radius: 3, y: 2)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(alignment: .center, spacing: 12) {
                    Text(hero.detail)
                        .font(DS.Fonts.text(15, .semibold, relativeTo: .subheadline))
                        .opacity(0.9)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    chip.hidden()
                }
            }
            .foregroundColor(.white)
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(stripes)
            .background(LinearGradient(colors: [TodayPalette.heroStart, TodayPalette.heroEnd], startPoint: .topLeading, endPoint: .bottomTrailing))
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .inked(cornerRadius: 24, shadow: 6)
            .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel([hero.kicker, hero.title, hero.detail].filter { !$0.isEmpty }.joined(separator: ". "))
        .accessibilityHint("Открыть")
        .overlay(alignment: .bottomTrailing) {
            Button(action: primary) { chip }
                .buttonStyle(PressScaleStyle())
                .padding(18)
                .accessibilityLabel("\(hero.action): \(hero.title)")
        }
        .padding(.trailing, 6)
    }

    private var chip: some View {
        Text(hero.action)
            .font(DS.Fonts.text(15, .heavy, relativeTo: .subheadline))
            .foregroundColor(TodayPalette.heroButtonText)
            .lineLimit(1)
            .padding(.horizontal, 18)
            .frame(height: 44)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(DS.Colors.edge, lineWidth: 1))
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(DS.Colors.drop).offset(y: 2))
            .transformEffect(TodayFormat.skew(8, height: 44))
    }

    private var stripes: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Color.white.opacity(0.10))
                    .frame(width: 54, height: 400)
                    .rotationEffect(.degrees(24))
                    .position(x: proxy.size.width - 34 - 27, y: 160)
                Rectangle().fill(Color.white.opacity(0.10))
                    .frame(width: 18, height: 400)
                    .rotationEffect(.degrees(24))
                    .position(x: proxy.size.width + 6 - 9, y: 160)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// One of the three rings: a 66 pt ring with the value inside and the name under it.
struct TodayRing: View {
    let name: String
    let value: String
    /// 0…1.
    let fraction: Double
    let color: Color
    let spoken: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    // Dashboard rings (owner 19.11, D-A): the first thing on «Сегодня», so larger.
                    Circle().stroke(TodayPalette.ringTrack, lineWidth: 11)
                    Circle()
                        .trim(from: 0, to: min(max(fraction, 0), 1))
                        .stroke(color, style: StrokeStyle(lineWidth: 11, lineCap: .butt))
                        .rotationEffect(.degrees(-90))
                    Text(value)
                        .font(DS.Fonts.text(19, .heavy, relativeTo: .headline))
                        .monospacedDigit()
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .frame(width: 56)
                }
                .frame(width: 80, height: 80)
                .padding(4)
                Text(name)
                    .font(DS.Fonts.text(13, .bold, relativeTo: .caption))
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity)
            .background(DS.Colors.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel(spoken)
        .accessibilityHint("Открыть")
    }
}

/// A row of «Дальше сегодня» (and of habits): the 28 pt box, the title and a time on the right.
/// The whole row toggles; a row that cannot be ticked (an event) opens its section instead.
struct TodayCheckRow: View {
    let title: String
    let trailing: String
    let done: Bool
    let checkable: Bool
    var busy: Bool = false
    var caption: String = ""
    let action: () -> Void
    @Environment(\.sectionAccent) private var accent

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                box
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(DS.Fonts.text(17, .semibold))
                        .foregroundColor(done ? DS.Colors.textMuted : DS.Colors.textPrimary)
                        .strikethrough(done, color: DS.Colors.textMuted)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if !caption.isEmpty {
                        Text(caption)
                            .font(DS.Fonts.text(14, .medium, relativeTo: .footnote))
                            .foregroundColor(DS.Colors.textSecondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if !trailing.isEmpty {
                    Text(trailing)
                        .font(DS.Fonts.text(15, .bold, relativeTo: .subheadline))
                        .monospacedDigit()
                        .foregroundColor(DS.Colors.textSecondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
            .background(DS.Colors.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(PressScaleStyle())
        .disabled(busy)
        .sensoryFeedback(.selection, trigger: done)
        .speedLines(on: done)
        .accessibilityLabel([title, trailing, caption].filter { !$0.isEmpty }.joined(separator: ", "))
        .accessibilityValue(checkable ? (done ? "выполнено" : "не выполнено") : "")
        .accessibilityHint(checkable ? "Отметить" : "Открыть")
    }

    @ViewBuilder
    private var box: some View {
        if checkable {
            ZStack {
                if done {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(accent)
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .heavy))
                        .foregroundColor(DS.Colors.ink)
                        .transition(.scale.combined(with: .opacity))
                } else {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(TodayPalette.boxBorder, lineWidth: 2)
                }
                if busy { ProgressView().controlSize(.mini).tint(DS.Colors.textPrimary) }
            }
            .frame(width: 28, height: 28)
            .animation(.spring(response: 0.28, dampingFraction: 0.6), value: done)
        } else {
            Image(systemName: "calendar")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(DS.Colors.textSecondary)
                .frame(width: 28, height: 28)
                .background(DS.Colors.surfaceRaised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}

/// The small uppercase section label with an optional accent link on the right («Все планы»).
struct TodaySectionTitle: View {
    let title: String
    var link: String? = nil
    var linkAction: (() -> Void)? = nil
    /// A small icon button before the link, e.g. the alarms bell next to «Все планы».
    var icon: (name: String, label: String, action: () -> Void)? = nil
    @Environment(\.sectionAccent) private var accent

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            SectionHeader(title)
            if let icon {
                Button(action: icon.action) {
                    Image(systemName: icon.name)
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: DS.Metrics.minHitTarget, height: DS.Metrics.minHitTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundColor(DS.Colors.textSecondary)
                .accessibilityLabel(icon.label)
            }
            if let link, let linkAction {
                Button(link, action: linkAction)
                    .font(DS.Fonts.text(15, .bold, relativeTo: .subheadline))
                    .foregroundColor(accent)
                    .buttonStyle(.plain)
                    .frame(minHeight: DS.Metrics.minHitTarget)
                    .contentShape(Rectangle())
            }
        }
    }
}

/// The seven days of «Прогресс недели»: a filled cell for a day with any action, an outlined one for today.
struct TodayWeekStrip: View {
    enum Mark { case active, today, todayActive, idle }
    let marks: [Mark]
    @Environment(\.sectionAccent) private var accent
    private static let letters = ["П", "В", "С", "Ч", "П", "С", "В"]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(marks.prefix(7).enumerated()), id: \.offset) { index, mark in
                Text(Self.letters[index])
                    .font(DS.Fonts.text(13, .heavy, relativeTo: .caption))
                    .foregroundColor(textColor(mark))
                    .frame(maxWidth: .infinity)
                    .frame(height: 36)
                    .background(cell(mark))
            }
        }
        .accessibilityHidden(true)
    }

    private func textColor(_ mark: Mark) -> Color {
        switch mark {
        case .active, .todayActive: return DS.Colors.canvas
        case .today: return DS.Colors.textPrimary
        case .idle: return DS.Colors.textMuted
        }
    }

    @ViewBuilder
    private func cell(_ mark: Mark) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        switch mark {
        case .active: shape.fill(accent)
        case .todayActive: shape.fill(accent).overlay(shape.strokeBorder(DS.Colors.textPrimary, lineWidth: 2))
        case .today: shape.strokeBorder(accent, lineWidth: 2)
        case .idle: shape.fill(DS.Colors.surfaceRaised)
        }
    }
}

/// A list row in the canvas style for goals and pinned notes: title, a grey line and an optional accent bar.
struct TodayInfoRow: View {
    let title: String
    var caption: String = ""
    var fraction: Double? = nil
    var icon: String? = nil
    var iconColor: Color = DS.Colors.textSecondary
    let hint: String
    let action: () -> Void
    @Environment(\.sectionAccent) private var accent

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(iconColor)
                        .frame(width: 28, height: 28)
                        .background(DS.Colors.surfaceRaised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(DS.Fonts.text(17, .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if !caption.isEmpty {
                        Text(caption)
                            .font(DS.Fonts.text(14, .medium, relativeTo: .footnote))
                            .foregroundColor(DS.Colors.textSecondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    if let fraction {
                        GeometryReader { proxy in
                            ZStack(alignment: .leading) {
                                Capsule().fill(TodayPalette.ringTrack)
                                Capsule().fill(accent).frame(width: proxy.size.width * min(max(fraction, 0), 1))
                            }
                        }
                        .frame(height: 6)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
            .background(DS.Colors.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel([title, caption].filter { !$0.isEmpty }.joined(separator: ". "))
        .accessibilityHint(hint)
    }
}

/// «ещё 2» under a list.
struct TodayMoreLine: View {
    let count: Int
    var body: some View {
        if count > 0 {
            Text(TodaySummary.moreText(count))
                .font(DS.Fonts.text(14, .medium, relativeTo: .footnote))
                .foregroundColor(DS.Colors.textSecondary)
                .padding(.leading, 4)
        }
    }
}
