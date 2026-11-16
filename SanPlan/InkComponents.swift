import SwiftUI

// «Тушь»: кадр, декор (растр, линии скорости, звёзды), разделители и кнопки (DESIGN-INK, 5 и 7.1–7.2).
// Декор скрыт от VoiceOver и отключается при «Увеличении контраста». Формы, шкалы и плитки — в InkControls.swift.

// MARK: - Кадр

enum InkPanelStyle: Equatable {
    case plain
    /// Растр в углу, не под текстом.
    case tone
    /// Фон `fg`, текст `bg`: плашка «от автора», состояние «сделано».
    case inverse
    /// Фон `accent`, текст `onAccent`: «сейчас».
    case now
}

/// Кадр вместо карточки: прямоугольник с рамкой, без скруглений и размытых теней.
struct InkPanel<Content: View>: View {
    let style: InkPanelStyle
    let line: CGFloat
    let border: Color?
    let dashed: Bool
    let halftoneCorner: Alignment
    let halftoneSize: CGSize
    let content: Content
    @Environment(\.colorSchemeContrast) private var contrast

    init(
        _ style: InkPanelStyle = .plain,
        line: CGFloat = Ink.Metrics.frameLine,
        border: Color? = nil,
        dashed: Bool = false,
        halftoneCorner: Alignment = .bottomTrailing,
        halftoneSize: CGSize = CGSize(width: 88, height: 64),
        @ViewBuilder content: () -> Content
    ) {
        self.style = style
        self.line = line
        self.border = border
        self.dashed = dashed
        self.halftoneCorner = halftoneCorner
        self.halftoneSize = halftoneSize
        self.content = content()
    }

    private var fill: Color {
        switch style {
        case .plain, .tone: return Ink.Colors.bg
        case .inverse: return Ink.Colors.fg
        case .now: return Ink.Colors.accent
        }
    }

    private var stroke: Color {
        border ?? Ink.Colors.fg
    }

    private var width: CGFloat { contrast == .increased ? line + 1 : line }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) { content }
            .padding(Ink.Metrics.framePadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(fill)
            .background(alignment: halftoneCorner) {
                if style == .tone && contrast != .increased {
                    InkHalftone(corner: halftoneCorner)
                        .frame(width: halftoneSize.width, height: halftoneSize.height)
                        .accessibilityHidden(true)
                        .allowsHitTesting(false)
                }
            }
            .clipShape(Rectangle())
            .overlay(
                Rectangle()
                    .strokeBorder(stroke, style: StrokeStyle(lineWidth: width, dash: dashed ? [8, 5] : []))
            )
    }
}

/// Точки `fg` 2 pt шагом 5 pt, до 30 %, затухают от угла.
struct InkHalftone: View {
    var corner: Alignment = .bottomTrailing

    var body: some View {
        Canvas { context, size in
            let step: CGFloat = 5
            var y: CGFloat = 1
            while y < size.height {
                var x: CGFloat = 1
                while x < size.width {
                    context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 2, height: 2)), with: .color(Ink.Colors.fg))
                    x += step
                }
                y += step
            }
        }
        .opacity(0.3)
        .mask(LinearGradient(colors: [.clear, .black], startPoint: fadeStart, endPoint: fadeEnd))
    }

    private var fadeStart: UnitPoint { corner == .topTrailing ? .bottomLeading : .topLeading }
    private var fadeEnd: UnitPoint { corner == .topTrailing ? .topTrailing : .bottomTrailing }
}

/// Радиальные линии скорости вокруг одного главного числа: центр чистый, до 30 %. Статичные.
struct InkSpeedLines: View {
    var count = 40
    @Environment(\.colorSchemeContrast) private var contrast

    init(count: Int = 40) { self.count = count }

    var body: some View {
        if contrast != .increased {
            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let reach = hypot(size.width, size.height) / 2
                for index in 0..<count {
                    let angle = Double(index) / Double(count) * 2 * .pi
                    let inner = reach * (index.isMultiple(of: 2) ? 0.66 : 0.76)
                    var path = Path()
                    path.move(to: CGPoint(x: center.x + cos(angle) * inner, y: center.y + sin(angle) * inner))
                    path.addLine(to: CGPoint(x: center.x + cos(angle) * reach, y: center.y + sin(angle) * reach))
                    context.stroke(path, with: .color(Ink.Colors.fg), lineWidth: 1.2)
                }
            }
            .opacity(0.3)
            .accessibilityHidden(true)
            .allowsHitTesting(false)
        }
    }
}

/// Редкие звёздные точки «Космоса»: статичный фон `bg` (2.3). Не больше 40 точек, до 35 %, при «Увеличении контраста» нет.
/// Положения считаются из индекса, поэтому фон не мерцает при перерисовке. Кадры непрозрачные: точки видны только в «полях».
struct InkStarBackground: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        ZStack {
            Ink.Colors.bg
            if scheme == .dark && contrast != .increased {
                Canvas { context, size in
                    for index in 0..<Ink.Metrics.starCount {
                        let x = Self.unit(index, 12.9898) * size.width
                        let y = Self.unit(index, 78.233) * size.height
                        let diameter: CGFloat = index.isMultiple(of: 3) ? 2 : 1
                        context.fill(
                            Path(ellipseIn: CGRect(x: x, y: y, width: diameter, height: diameter)),
                            with: .color(Ink.Colors.spark.opacity(0.35))
                        )
                    }
                }
                .accessibilityHidden(true)
                .allowsHitTesting(false)
            }
        }
        .ignoresSafeArea()
    }

    /// Детерминированное число из [0, 1) для индекса точки.
    static func unit(_ index: Int, _ seed: Double) -> CGFloat {
        let value = sin(Double(index + 1) * seed) * 43758.5453
        return CGFloat(value - value.rounded(.down))
    }
}

// MARK: - Разделители и фолио

/// Фолио и надпись на полях: только декор, дублирует видимое, скрыто от VoiceOver.
struct InkFolio: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .bold))
            .textCase(.uppercase)
            .tracking(0.72)
            .foregroundColor(Ink.Colors.muted)
            .accessibilityHidden(true)
    }
}

struct InkRule: View {
    var color: Color = Ink.Colors.fg

    var body: some View {
        Rectangle().fill(color).frame(height: Ink.Metrics.ruleLine)
    }
}

// MARK: - Кнопки

/// Главная кнопка: заливка акцентом, рамка 3 pt, жёсткая тень 4×4; нажатие сдвигает кнопку в тень (80 мс туда, 120 мс обратно).
struct InkPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let shift: CGFloat = configuration.isPressed ? Ink.Metrics.shadow : 0
        ZStack {
            if isEnabled {
                Rectangle().fill(Ink.Colors.fg).offset(x: Ink.Metrics.shadow, y: Ink.Metrics.shadow)
                    .opacity(configuration.isPressed ? 0 : 1)
            }
            configuration.label
                .inkPoster(17, relativeTo: .headline)
                .multilineTextAlignment(.center)
                .foregroundColor(isEnabled ? Ink.Colors.onAccent : Ink.Colors.muted)
                .padding(.vertical, 8)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, minHeight: Ink.Metrics.primaryHeight)
                .background(isEnabled ? Ink.Colors.accent : Ink.Colors.bg)
                .overlay(Rectangle().strokeBorder(isEnabled ? Ink.Colors.fg : Ink.Colors.muted, lineWidth: Ink.Metrics.frameLine))
                .offset(x: shift, y: shift)
        }
        .padding(.trailing, Ink.Metrics.shadow)
        .padding(.bottom, Ink.Metrics.shadow)
        .animation(reduceMotion ? nil : .easeOut(duration: configuration.isPressed ? 0.08 : 0.12), value: configuration.isPressed)
    }
}

/// Вторичное действие: рамка 2 pt без заливки, текст обычным 700 17 pt, высота 48 pt.
struct InkSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .inkText(.headline, weight: .bold)
            .foregroundColor(isEnabled ? Ink.Colors.fg : Ink.Colors.muted)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: Ink.Metrics.secondaryHeight)
            .background(configuration.isPressed ? Ink.Colors.soft : Ink.Colors.bg)
            .overlay(Rectangle().strokeBorder(isEnabled ? Ink.Colors.fg : Ink.Colors.muted, lineWidth: Ink.Metrics.cellLine))
    }
}

/// Текстовая кнопка: без рамки, подчёркивание 1.5 pt, зона нажатия не меньше 44 pt.
struct InkTextButtonStyle: ButtonStyle {
    var color: Color = Ink.Colors.accentText
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .inkText(.body, weight: .bold)
            .foregroundColor(isEnabled ? color : Ink.Colors.muted)
            .padding(.bottom, 2)
            .overlay(alignment: .bottom) {
                Rectangle().fill(isEnabled ? color : Ink.Colors.muted).frame(height: Ink.Metrics.ruleLine)
            }
            .frame(minWidth: Ink.Metrics.minHit, minHeight: Ink.Metrics.minHit)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

/// Кнопка с подписью по §7.2: `primary` — одна на экран; `secondary`, `destructive` — второстепенные; `text` — без рамки.
struct InkButton: View {
    enum Kind { case primary, secondary, destructive, text }

    let title: String
    var icon: String? = nil
    var kind: Kind = .primary
    var textColor: Color = Ink.Colors.accentText
    let action: () -> Void

    init(title: String, icon: String? = nil, kind: Kind = .primary, textColor: Color = Ink.Colors.accentText, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.kind = kind
        self.textColor = textColor
        self.action = action
    }

    var body: some View {
        switch kind {
        case .primary:
            Button(action: action) { label(icon) }.buttonStyle(InkPrimaryButtonStyle())
        case .secondary:
            Button(action: action) { label(icon) }.buttonStyle(InkSecondaryButtonStyle())
        case .destructive:
            Button(action: action) { label(icon ?? "trash") }.buttonStyle(InkSecondaryButtonStyle())
        case .text:
            Button(action: action) { label(icon) }.buttonStyle(InkTextButtonStyle(color: textColor))
        }
    }

    @ViewBuilder
    private func label(_ symbol: String?) -> some View {
        if let symbol {
            Label { Text(title) } icon: { Image(systemName: symbol).font(.system(size: 17, weight: .bold)) }
        } else {
            Text(title)
        }
    }
}

/// Квадратная кнопка со значком, не меньше 44×44: пауза, +30 с, настройки.
struct InkIconButton: View {
    let icon: String
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .bold))
                .frame(maxWidth: .infinity, minHeight: Ink.Metrics.minHit)
        }
        .buttonStyle(InkSecondaryButtonStyle())
        .accessibilityLabel(accessibilityLabel)
    }
}

// MARK: - Звёздная пыль

/// 8–14 точек `spark` 2–4 pt разлетаются на 24–40 pt и гаснут за 600 мс. Только на событии; без движения и при «Увеличении контраста» её нет.
struct InkStardust: View {
    var count = 12
    @State private var progress: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        ZStack {
            if !reduceMotion && contrast != .increased {
                ForEach(0..<count, id: \.self) { index in
                    let angle = Double(index) / Double(count) * 2 * .pi
                    let distance = 24 + 16 * InkStarBackground.unit(index, 37.719)
                    Circle()
                        .fill(Ink.Colors.spark)
                        .frame(width: index.isMultiple(of: 3) ? 4 : 2.5, height: index.isMultiple(of: 3) ? 4 : 2.5)
                        .offset(x: cos(angle) * distance * progress, y: sin(angle) * distance * progress)
                        .opacity(1 - progress)
                }
            }
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
        .onAppear { withAnimation(.easeOut(duration: 0.6)) { progress = 1 } }
    }
}
