import SwiftUI
import UIKit

public enum DS {
    /// Round-5 palette (soft plum, dark only). Names kept so every screen picks it up without edits.
    public enum Colors {
        static func hex(_ v: UInt32, _ a: Double = 1) -> Color {
            Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255, opacity: a)
        }
        public static let canvas = hex(0x17122A)
        public static let surface = hex(0x211A3A)
        public static let surfaceRaised = hex(0x2A2148)
        public static let hairline = hex(0x3A2F5E)
        public static let navBar = hex(0x1C1533)
        public static let textPrimary = hex(0xF1ECFF)
        public static let textSecondary = hex(0xB8AFD4)
        public static let textMuted = hex(0x8E84AE)
        /// The hard «ink» used for the round-5 border and offset shadow.
        public static let ink = hex(0x0B0816)
        public static let accent = hex(0x8B6CF0)
        public static let accentDeep = hex(0x6A48D7)
        public static let onAccent = Color.white
        public static let alarmTint = hex(0x6A48D7)
        public static let controlTint = hex(0x8B6CF0)
        public static let accentGradientStart = hex(0x8B6CF0)
        public static let accentGradientEnd = hex(0x6A48D7)
        public static let positive = hex(0x6FD6B0)
        public static let warning = hex(0xF2C879)
        public static let destructive = hex(0xFF8A7A)

        /// Section accents from the canvas.
        public static let today = hex(0xB9A4FF)
        public static let plans = hex(0x7FB2FF)
        public static let notes = hex(0xF2C879)
        public static let money = hex(0x6FD6B0)
        /// Softened coral (owner 18.11): dark ink text stays readable on it.
        public static let workout = hex(0xEE9A8C)

        public static let accentGradient = LinearGradient(
            colors: [accentGradientStart, accentGradientEnd],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// Dela Gothic One for titles and big numbers, Golos Text for everything else; both follow Dynamic Type.
    public enum Fonts {
        public static func display(_ size: CGFloat, relativeTo style: Font.TextStyle = .title) -> Font {
            .custom("DelaGothicOne-Regular", size: size, relativeTo: style)
        }
        public static func text(_ size: CGFloat = 17, _ weight: Font.Weight = .regular, relativeTo style: Font.TextStyle = .body) -> Font {
            .custom("Golos Text", size: size, relativeTo: style).weight(weight)
        }
        public static let title = display(28, relativeTo: .largeTitle)
        public static let body = text(17)
        public static let label = text(13, .bold, relativeTo: .caption)
    }

    public enum Metrics {
        public static let spacing4: CGFloat = 4
        public static let spacing8: CGFloat = 8
        public static let spacing12: CGFloat = 12
        public static let spacing16: CGFloat = 16
        public static let spacing24: CGFloat = 24
        public static let spacing32: CGFloat = 32

        public static let cardRadius: CGFloat = 20
        public static let innerRadius: CGFloat = 14
        public static let pillHeight: CGFloat = 50
        public static let screenGutter: CGFloat = 20
        public static let minHitTarget: CGFloat = 44
    }
}

public struct PillButton: View {
    public enum Style {
        case primary
        case secondary
        case destructive
    }

    private let title: String
    private let icon: String?
    private let style: Style
    private let isLoading: Bool
    private let isEnabled: Bool
    private let action: () -> Void
    /// Round 6: the primary pill takes the colour of the section it sits in (owner: «всё в цвет раздела»).
    @Environment(\.sectionAccent) private var accent

    public init(
        _ title: String,
        icon: String? = nil,
        style: Style = .primary,
        isLoading: Bool = false,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.icon = icon
        self.style = style
        self.isLoading = isLoading
        self.isEnabled = isEnabled
        self.action = action
    }

    public var body: some View {
        Button(action: {
            guard !isLoading && isEnabled else { return }
            action()
        }) {
            HStack(spacing: DS.Metrics.spacing8) {
                if isLoading {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: foregroundColor))
                } else {
                    if let icon = icon {
                        Image(systemName: icon)
                            .font(.system(size: 16, weight: .semibold))
                    }
                    Text(title)
                        .font(DS.Fonts.text(17, .bold))
                }
            }
            .foregroundColor(foregroundColor)
            .frame(maxWidth: .infinity)
            .frame(height: DS.Metrics.pillHeight)
            .background(backgroundColor)
            .clipShape(RoundedRectangle(cornerRadius: DS.Metrics.pillHeight / 2))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Metrics.pillHeight / 2)
                    .stroke(borderColor, lineWidth: 2)
            )
            .background(
                RoundedRectangle(cornerRadius: DS.Metrics.pillHeight / 2)
                    .fill(style == .primary ? DS.Colors.ink : .clear)
                    .offset(x: 4, y: 4)
            )
        }
        .buttonStyle(PressScaleStyle())
        .disabled(!isEnabled || isLoading)
        .opacity(isEnabled ? 1.0 : 0.45)
    }

    private var foregroundColor: Color {
        switch style {
        case .primary:
            return DS.Colors.ink
        case .secondary:
            return DS.Colors.textPrimary
        case .destructive:
            return DS.Colors.canvas
        }
    }

    private var backgroundColor: Color {
        switch style {
        case .primary:
            return accent
        case .secondary:
            return DS.Colors.surfaceRaised
        case .destructive:
            return DS.Colors.destructive
        }
    }

    private var borderColor: Color {
        switch style {
        case .primary:
            return DS.Colors.ink
        case .secondary:
            return Color.clear
        case .destructive:
            return Color.clear
        }
    }
}

public struct CircleIconButton: View {
    private let icon: String
    private let accessibilityLabelText: String
    private let action: () -> Void

    public init(
        icon: String,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) {
        self.icon = icon
        self.accessibilityLabelText = accessibilityLabel
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .regular))
                .foregroundColor(DS.Colors.textPrimary)
                .frame(width: DS.Metrics.minHitTarget, height: DS.Metrics.minHitTarget)
                .background(DS.Colors.surface)
                .clipShape(Circle())
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel(accessibilityLabelText)
    }
}

/// A round-ended header action that says what it does, for actions people must find without guessing.
public struct HeaderTextButton: View {
    private let title: String
    private let icon: String
    private let action: () -> Void

    public init(_ title: String, icon: String, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(DS.Fonts.text(15, .semibold, relativeTo: .subheadline))
                .foregroundColor(DS.Colors.textPrimary)
                .padding(.horizontal, DS.Metrics.spacing12)
                .frame(minHeight: DS.Metrics.minHitTarget)
                .background(DS.Colors.surface)
                .clipShape(Capsule())
        }
    }
}

public struct Card<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DS.Metrics.spacing12) {
            content
        }
        .padding(DS.Metrics.spacing16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Colors.surface)
        .clipShape(RoundedRectangle(cornerRadius: DS.Metrics.cardRadius))
    }
}

/// The one top bar every tab uses: a skewed accent tag over a Dela title, the screen's own actions,
/// then «Прогресс» and the hero avatar that opens «Профиль» (supplied by the root through the environment).
public struct ScreenHeader<Actions: View>: View {
    private let title: String
    private let kicker: String?
    private let actions: Actions
    @Environment(\.sectionAccent) private var accent
    @Environment(\.headerShortcuts) private var shortcuts

    public init(_ title: String, kicker: String? = nil, @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.kicker = kicker
        self.actions = actions()
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                if let kicker, !kicker.isEmpty {
                    SkewTag(kicker, color: accent)
                }
                Text(title)
                    .font(DS.Fonts.title)
                    .foregroundColor(DS.Colors.textPrimary)
                    .shadow(color: DS.Colors.ink, radius: 0, x: 3, y: 3)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .accessibilityAddTraits(.isHeader)
            }
            .tourTarget("header.title")
            Spacer(minLength: 0)
            actions
            if let shortcuts {
                if let help = shortcuts.openHelp {
                    SectionHelpButton(action: help)
                        .tourTarget("header.help")
                }
                CircleIconButton(icon: "chart.bar.xaxis", accessibilityLabel: "Прогресс", action: shortcuts.openProgress)
                    .tourTarget("header.progress")
                ProfileAvatarButton(accent: accent, action: shortcuts.openProfile)
                    .tourTarget("header.profile")
            }
        }
    }
}

/// The skewed accent label from the canvas: dark text on the section colour with a hard ink shadow.
public struct SkewTag: View {
    private let text: String
    private let color: Color

    public init(_ text: String, color: Color) {
        self.text = text
        self.color = color
    }

    public var body: some View {
        Text(text.uppercased())
            .font(DS.Fonts.text(12, .heavy, relativeTo: .caption))
            .tracking(0.5)
            .foregroundColor(DS.Colors.canvas)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 10)
            .padding(.vertical, 2)
            .background(color)
            .background(DS.Colors.ink.offset(x: 3, y: 3))
            .transformEffect(CGAffineTransform(a: 1, b: 0, c: -0.176, d: 1, tx: 3, ty: 0))
            .padding(.leading, 3)
    }
}

/// The hero's head in a ringed circle: the way into «Профиль и настройки».
public struct ProfileAvatarButton: View {
    let accent: Color
    let action: () -> Void

    public var body: some View {
        Button(action: action) {
            Image(MascotWardrobe.shared.heroImage(.think))
                .resizable()
                .scaledToFit()
                .frame(height: 76)
                .padding(.top, 2)
                .frame(width: 42, height: 42, alignment: .top)
                .clipped()
                .background(DS.Colors.surfaceRaised)
                .clipShape(Circle())
                .overlay(Circle().stroke(accent, lineWidth: 2))
                .background(Circle().fill(DS.Colors.ink).offset(x: 3, y: 3))
                .frame(width: 46, height: 46)
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel("Профиль и настройки")
    }
}

/// Root-supplied header buttons, so every tab shows the same «Прогресс» and avatar.
public struct HeaderShortcuts {
    public var openProfile: () -> Void
    public var openProgress: () -> Void
    /// The «?» that runs this section's tour.
    public var openHelp: (() -> Void)? = nil
}

private struct SectionAccentKey: EnvironmentKey { static let defaultValue: Color = DS.Colors.today }
private struct HeaderShortcutsKey: EnvironmentKey { static let defaultValue: HeaderShortcuts? = nil }

public extension EnvironmentValues {
    var sectionAccent: Color {
        get { self[SectionAccentKey.self] }
        set { self[SectionAccentKey.self] = newValue }
    }
    var headerShortcuts: HeaderShortcuts? {
        get { self[HeaderShortcutsKey.self] }
        set { self[HeaderShortcutsKey.self] = newValue }
    }
}

/// Small press-down scale used by every tappable surface; none under «Уменьшение движения».
public struct PressScaleStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

public extension View {
    /// The hard «ink» frame for the screen's main card and main buttons.
    func inked(cornerRadius: CGFloat = DS.Metrics.cardRadius, shadow: CGFloat = 6) -> some View {
        self
            .overlay(RoundedRectangle(cornerRadius: cornerRadius).stroke(DS.Colors.ink, lineWidth: 2))
            .background(RoundedRectangle(cornerRadius: cornerRadius).fill(DS.Colors.ink).offset(x: shadow, y: shadow))
    }
}

public struct SectionHeader: View {
    private let title: String

    public init(_ title: String) {
        self.title = title
    }

    public var body: some View {
        Text(title.uppercased())
            .font(DS.Fonts.label)
            .tracking(0.8)
            .foregroundColor(DS.Colors.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            // VoiceOver reads the words as written, not a shouted spelling.
            .accessibilityLabel(title)
            .accessibilityAddTraits(.isHeader)
    }
}

public struct EmptyState: View {
    private let title: String
    private let message: String?
    private let icon: String?

    public init(title: String, message: String? = nil, icon: String? = nil) {
        self.title = title
        self.message = message
        self.icon = icon
    }

    public var body: some View {
        VStack(spacing: DS.Metrics.spacing12) {
            if let icon = icon {
                Image(systemName: icon)
                    .font(.system(size: 38, weight: .light))
                    .foregroundColor(DS.Colors.textSecondary)
            }
            Text(title)
                .font(.headline.weight(.medium))
                .foregroundColor(DS.Colors.textPrimary)
                .multilineTextAlignment(.center)
            if let message = message {
                Text(message)
                    .font(.subheadline)
                    .foregroundColor(DS.Colors.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(DS.Metrics.spacing24)
        .frame(maxWidth: .infinity)
    }
}

public struct ErrorBanner: View {
    private let message: String
    private let dismissAction: (() -> Void)?

    public init(message: String, dismissAction: (() -> Void)? = nil) {
        self.message = message
        self.dismissAction = dismissAction
    }

    public var body: some View {
        HStack(alignment: .center, spacing: DS.Metrics.spacing12) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundColor(DS.Colors.destructive)
                .font(.system(size: 18, weight: .medium))

            Text(message)
                .font(.subheadline)
                .foregroundColor(DS.Colors.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let dismissAction = dismissAction {
                Button(action: dismissAction) {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(DS.Colors.textSecondary)
                        .frame(width: 32, height: 32)
                }
                .accessibilityLabel("Закрыть уведомление об ошибке")
            }
        }
        .padding(DS.Metrics.spacing12)
        .background(DS.Colors.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: DS.Metrics.innerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Metrics.innerRadius)
                .stroke(DS.Colors.destructive.opacity(0.3), lineWidth: 1)
        )
    }
}

/// Extra buttons a screen puts on the left of the keyboard bar (the notes editor: lists and heading),
/// plus what «Готово» should do besides hiding the keyboard. Compared by identity.
public final class KeyboardBarTools: Equatable {
    public struct Item: Identifiable {
        public let id: String
        public let icon: String
        public let label: String
        public let action: @MainActor () -> Void
        public init(id: String, icon: String, label: String, action: @escaping @MainActor () -> Void) {
            self.id = id; self.icon = icon; self.label = label; self.action = action
        }
    }
    public let items: [Item]
    public let onDone: @MainActor () -> Void
    public init(items: [Item], onDone: @escaping @MainActor () -> Void = {}) {
        self.items = items
        self.onDone = onDone
    }
    public static func == (a: KeyboardBarTools, b: KeyboardBarTools) -> Bool { a === b }
}

/// The keyboard bar's mailbox, handed down the environment (it reaches pushed screens, unlike preferences).
@MainActor
public final class KeyboardBarChannel: ObservableObject {
    @Published public var tools: KeyboardBarTools?
    public init() {}
}

private struct KeyboardBarChannelKey: EnvironmentKey {
    static let defaultValue: KeyboardBarChannel? = nil
}

public extension EnvironmentValues {
    var keyboardBarChannel: KeyboardBarChannel? {
        get { self[KeyboardBarChannelKey.self] }
        set { self[KeyboardBarChannelKey.self] = newValue }
    }
}

/// Gives any screen with text input a way to put the keyboard away: drag the content down,
/// or tap «Готово» on the bar that rides above the keyboard. Multi-line fields treat Return as a new line,
/// so without this the keyboard could not be closed. The bar takes the section's colour.
public struct KeyboardDismissBar: ViewModifier {
    @State private var isKeyboardVisible = false
    @StateObject private var channel = KeyboardBarChannel()
    @Environment(\.sectionAccent) private var accent

    private var tools: KeyboardBarTools? { channel.tools }

    public func body(content: Content) -> some View {
        content
            .environment(\.keyboardBarChannel, channel)
            .scrollDismissesKeyboard(.interactively)
            .onAppear { KeyboardTapDismisser.shared.install() }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if isKeyboardVisible {
                    HStack(spacing: 2) {
                        ForEach(tools?.items ?? []) { item in
                            Button { item.action() } label: {
                                Image(systemName: item.icon)
                                    .font(.system(size: 19, weight: .semibold))
                                    .foregroundColor(DS.Colors.textPrimary)
                                    .frame(width: DS.Metrics.minHitTarget, height: DS.Metrics.minHitTarget)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(PressScaleStyle())
                            .accessibilityLabel(item.label)
                            .accessibilityIdentifier("kbd-\(item.id)")
                        }
                        Spacer()
                        Button {
                            tools?.onDone()
                            hideKeyboard()
                        } label: {
                            Text("Готово")
                                .font(.body.weight(.bold))
                                .foregroundColor(DS.Colors.ink)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 6)
                                .background(accent, in: Capsule())
                        }
                        .padding(.trailing, DS.Metrics.spacing12)
                        .frame(minHeight: DS.Metrics.minHitTarget)
                        .accessibilityLabel("Готово")
                        .accessibilityHint("Сохраняет и прячет клавиатуру")
                        .accessibilityIdentifier("kbd-done")
                    }
                    .padding(.leading, 6)
                    .background(DS.Colors.surface)
                    .overlay(alignment: .top) { Rectangle().fill(DS.Colors.hairline).frame(height: 1) }
                    // Taps on the bar must not count as «tap outside the text» and close the keyboard.
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                        KeyboardTapDismisser.shared.keepRect = $0
                    }
                    .onDisappear { KeyboardTapDismisser.shared.keepRect = .null }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                isKeyboardVisible = true
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                isKeyboardVisible = false
            }
    }
}

/// One window-level tap recogniser: a tap outside any text field or text view ends editing.
/// It never cancels the tap, so buttons and rows under the finger still work.
@MainActor
final class KeyboardTapDismisser: NSObject, UIGestureRecognizerDelegate {
    static let shared = KeyboardTapDismisser()
    private weak var installedWindow: UIWindow?
    /// The keyboard bar's frame in window coordinates: taps there keep the keyboard.
    var keepRect: CGRect = .null

    func install() {
        let window = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first
        guard let window, window !== installedWindow else { return }
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        window.addGestureRecognizer(tap)
        installedWindow = window
    }

    @objc private func tapped() {
        hideKeyboard()
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if !keepRect.isNull, let window = installedWindow, keepRect.contains(touch.location(in: window)) { return false }
        var view = touch.view
        while let current = view {
            // Text inputs, and the edit menu (Вставить, Скопировать) that sits over them: a tap there must reach its action.
            if current is UITextField || current is UITextView { return false }
            let name = String(describing: type(of: current))
            if name.contains("Menu") || name.contains("Callout") { return false }
            view = current.superview
        }
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}

public func hideKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}

public extension View {
    func keyboardDismissBar() -> some View { modifier(KeyboardDismissBar()) }
}

// MARK: - Section switcher (canvas «seg»: skewed accent pill on a dark track)

/// Replaces the grey system segmented control for a screen's own sections.
public struct ArnaSegmented<Value: Hashable>: View {
    private let title: String
    @Binding private var selection: Value
    private let options: [(value: Value, label: String)]
    @Environment(\.sectionAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(_ title: String, selection: Binding<Value>, options: [(value: Value, label: String)]) {
        self.title = title
        self._selection = selection
        self.options = options
    }

    public var body: some View {
        HStack(spacing: 4) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                let isOn = option.value == selection
                Button {
                    withAnimation(.easeOut(duration: reduceMotion ? 0.12 : 0.2)) { selection = option.value }
                } label: {
                    Text(option.label)
                        .font(DS.Fonts.text(15, .bold, relativeTo: .subheadline))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .foregroundColor(isOn ? DS.Colors.canvas : DS.Colors.textSecondary)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background {
                            if isOn {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(accent)
                                    .background(
                                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                                            .fill(DS.Colors.ink)
                                            .offset(x: 3, y: 3)
                                    )
                                    .transformEffect(CGAffineTransform(a: 1, b: 0, c: -0.087, d: 1, tx: 2, ty: 0))
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isOn ? [.isSelected] : [])
            }
        }
        .padding(4)
        .background(DS.Colors.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}
