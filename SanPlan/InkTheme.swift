import SwiftUI
import UIKit

// «Тушь»: токены дизайн-системы (docs/design/DESIGN-INK.md, разделы 2–4). Только внешний вид; логики здесь нет.
// Живут отдельно от DS.Colors и DS.Metrics и их не заменяют. Две темы по системной: «Бумага» и «Космос».
// Акцент один и означает «действие» или «сейчас».

extension DS {
    public enum Ink {
        public enum Colors {
            public static let bg = dynamic(light: 0xFBFAF5, dark: 0x0E0B16)
            public static let fg = dynamic(light: 0x121212, dark: 0xF3F0E6)
            public static let soft = dynamic(light: 0xECEBE4, dark: 0x1C1630)
            public static let muted = dynamic(light: 0x5A5A55, dark: 0xA9A3B8)
            public static let accent = dynamic(light: 0x4B2A8C, dark: 0x7C5CE6)
            public static let onAccent = dynamic(light: 0xFFFFFF, dark: 0xFFFFFF)
            /// Акцент как текст и тонкая линия: в «Космосе» светлее, чтобы держать контраст.
            public static let accentText = dynamic(light: 0x4B2A8C, dark: 0xB9A2F5)
            /// Только декор: звёздная пыль, блик, заливка звукоподражания. Смысла не несёт.
            public static let spark = dynamic(light: 0x8E6CF0, dark: 0xB9A2F5)

            static func dynamic(light: UInt32, dark: UInt32) -> Color {
                Color(UIColor { trait in
                    UIColor(hex: trait.userInterfaceStyle == .dark ? dark : light)
                })
            }
        }

        public enum Metrics {
            /// Рамка кадра и главной кнопки, ячейки и вторичной кнопки, разделитель строк.
            public static let frameLine: CGFloat = 3
            public static let cellLine: CGFloat = 2
            public static let ruleLine: CGFloat = 1.5
            /// «Поля» между кадрами, отступ внутри кадра, поля страницы, промежуток между группами.
            public static let gutter: CGFloat = 8
            public static let framePadding: CGFloat = 12
            public static let page: CGFloat = 16
            public static let stack: CGFloat = 16
            /// Жёсткая тень главной кнопки.
            public static let shadow: CGFloat = 4
            public static let primaryHeight: CGFloat = 52
            public static let secondaryHeight: CGFloat = 48
            public static let minHit: CGFloat = 44
            /// Одна колонка до 440 pt по центру.
            public static let maxWidth: CGFloat = 440
            /// Плакатные числа растут вместе с Dynamic Type не больше чем в 1,3 раза.
            public static let posterMaxScale: CGFloat = 1.3
            /// Не больше 40 звёздных точек на экране.
            public static let starCount = 40
        }

        public enum Font {
            public static let posterName = "DelaGothicOne-Regular"
            public static let textRegular = "GolosText-Regular"
            public static let textMedium = "GolosText-Medium"
            public static let textBold = "GolosText-Bold"

            /// Шрифт вшит в бандл и загрузился. Пока файлов нет, везде системный запасной.
            public static func available(_ name: String) -> Bool {
                UIFont(name: name, size: 12) != nil
            }

            /// Плакатный: Dela Gothic One; запасной — самый плотный системный.
            public static func poster(size: CGFloat) -> SwiftUI.Font {
                if available(posterName) { return .custom(posterName, fixedSize: size) }
                return .system(size: size, weight: .black, design: .default)
            }

            /// Обычный: Golos Text 400/500/700 и масштабирование по `style`; запасной — системный того же стиля и веса.
            public static func text(_ style: SwiftUI.Font.TextStyle, weight: SwiftUI.Font.Weight = .regular) -> SwiftUI.Font {
                let name = weight == .bold || weight == .heavy || weight == .black ? textBold : (weight == .medium || weight == .semibold ? textMedium : textRegular)
                if available(name) { return .custom(name, size: baseSize(style), relativeTo: style) }
                return .system(style).weight(weight)
            }

            /// Размеры токенов `ink.type.*` для обычного шрифта: caption 15, body 16, row 17.
            static func baseSize(_ style: SwiftUI.Font.TextStyle) -> CGFloat {
                switch style {
                case .caption, .caption2, .footnote, .subheadline: return 15
                case .body: return 16
                default: return 17
                }
            }
        }

        /// Размер плакатного текста при текущем Dynamic Type, не больше `posterMaxScale` от базового.
        public static func posterSize(base: CGFloat, scaled: CGFloat) -> CGFloat {
            min(max(scaled, base), base * Metrics.posterMaxScale)
        }
    }
}

/// Короткое имя: во всём коде пилота `Ink.Colors.bg` и т. д. — это `DS.Ink.*`.
typealias Ink = DS.Ink

private extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

/// Плакатный текст: числа, заголовки, главная кнопка. Не для абзацев.
struct InkPosterText: ViewModifier {
    let base: CGFloat
    @ScaledMetric private var scaled: CGFloat

    init(size: CGFloat, relativeTo style: Font.TextStyle) {
        base = size
        _scaled = ScaledMetric(wrappedValue: size, relativeTo: style)
    }

    func body(content: Content) -> some View {
        content
            .font(Ink.Font.poster(size: Ink.posterSize(base: base, scaled: scaled)).monospacedDigit())
            .fixedSize(horizontal: false, vertical: true)
    }
}

extension View {
    /// `size` — размер из таблицы (56 число экрана, 26 заголовок, 20 заголовок кадра, 17 кнопка, 15 плашка).
    func inkPoster(_ size: CGFloat, relativeTo style: Font.TextStyle = .title) -> some View {
        modifier(InkPosterText(size: size, relativeTo: style))
    }

    /// Обычный текст «Туши» (`ink.type.row`/`body`/`caption`/`num`): Golos Text или системный запасной.
    func inkText(_ style: Font.TextStyle = .body, weight: Font.Weight = .regular, numeric: Bool = false) -> some View {
        font(numeric ? Ink.Font.text(style, weight: weight).monospacedDigit() : Ink.Font.text(style, weight: weight))
    }
}

/// Состояние подхода в сетке: выполнен, идёт сейчас, впереди, пропущен. Цвет не единственный признак.
enum InkSetState: Equatable {
    case todo, done, now, skipped

    static func state(done: Bool, isCurrent: Bool) -> InkSetState {
        if done { return .done }
        return isCurrent ? .now : .todo
    }

    /// Подпись для экранного диктора и для ячейки «сейчас».
    var word: String {
        switch self {
        case .todo: return "впереди"
        case .done: return "сделан"
        case .now: return "сейчас"
        case .skipped: return "пропущен"
        }
    }
}

/// Раскладка плиток итога: в ряд, пока размер текста обычный; в столбец от `accessibility1`.
enum InkStatLayout {
    static func isStacked(_ size: DynamicTypeSize) -> Bool { size >= .accessibility1 }
}
