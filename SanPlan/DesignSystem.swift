import SwiftUI
import UIKit

public enum DS {
    public enum Colors {
        public static let canvas = Color(UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 1.0)
                : UIColor(red: 245/255, green: 246/255, blue: 248/255, alpha: 1.0)
        })

        public static let surface = Color(UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(red: 14/255, green: 16/255, blue: 20/255, alpha: 1.0)
                : UIColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)
        })

        public static let surfaceRaised = Color(UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(red: 23/255, green: 26/255, blue: 32/255, alpha: 1.0)
                : UIColor(red: 238/255, green: 240/255, blue: 244/255, alpha: 1.0)
        })

        public static let hairline = Color(UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(white: 1.0, alpha: 0.12)
                : UIColor(white: 0.0, alpha: 0.10)
        })

        public static let textPrimary = Color(UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)
                : UIColor(red: 11/255, green: 13/255, blue: 18/255, alpha: 1.0)
        })

        public static let textSecondary = Color(UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(red: 167/255, green: 173/255, blue: 184/255, alpha: 1.0)
                : UIColor(red: 91/255, green: 98/255, blue: 112/255, alpha: 1.0)
        })

        /// The ARNA logo lilac (#C6B2F4) in dark; a deeper violet (#6B4FD8) in light so white text on it stays readable.
        public static let accent = Color(UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(red: 198/255, green: 178/255, blue: 244/255, alpha: 1.0)
                : UIColor(red: 107/255, green: 79/255, blue: 216/255, alpha: 1.0)
        })

        /// Text and icons placed on an accent fill: the logo's ink in dark, white in light.
        public static let onAccent = Color(UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(red: 27/255, green: 25/255, blue: 34/255, alpha: 1.0)
                : UIColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)
        })

        /// System alarm buttons draw white text on this tint, so it stays deep enough for 5.6:1.
        public static let alarmTint = Color(red: 107/255, green: 79/255, blue: 216/255)

        /// Tint for system controls that draw white over it (date pickers, prominent toolbar buttons):
        /// #7438DF in dark (6.2:1 with white), the light accent in light.
        public static let controlTint = Color(UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(red: 116/255, green: 56/255, blue: 223/255, alpha: 1.0)
                : UIColor(red: 107/255, green: 79/255, blue: 216/255, alpha: 1.0)
        })

        public static let accentGradientStart = Color(UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(red: 198/255, green: 178/255, blue: 244/255, alpha: 1.0)
                : UIColor(red: 142/255, green: 108/255, blue: 240/255, alpha: 1.0)
        })

        public static let accentGradientEnd = Color(UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(red: 142/255, green: 108/255, blue: 240/255, alpha: 1.0)
                : UIColor(red: 91/255, green: 63/255, blue: 200/255, alpha: 1.0)
        })

        public static let positive = Color(UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(red: 52/255, green: 199/255, blue: 123/255, alpha: 1.0)
                : UIColor(red: 18/255, green: 128/255, blue: 74/255, alpha: 1.0)
        })

        public static let warning = Color(UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(red: 255/255, green: 179/255, blue: 64/255, alpha: 1.0)
                : UIColor(red: 168/255, green: 100/255, blue: 0/255, alpha: 1.0)
        })

        public static let destructive = Color(UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(red: 255/255, green: 90/255, blue: 82/255, alpha: 1.0)
                : UIColor(red: 201/255, green: 48/255, blue: 42/255, alpha: 1.0)
        })

        public static let accentGradient = LinearGradient(
            colors: [accentGradientStart, accentGradientEnd],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    public enum Metrics {
        public static let spacing4: CGFloat = 4
        public static let spacing8: CGFloat = 8
        public static let spacing12: CGFloat = 12
        public static let spacing16: CGFloat = 16
        public static let spacing24: CGFloat = 24
        public static let spacing32: CGFloat = 32

        public static let cardRadius: CGFloat = 24
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
                        .font(.body.weight(.semibold))
                }
            }
            .foregroundColor(foregroundColor)
            .frame(maxWidth: .infinity)
            .frame(height: DS.Metrics.pillHeight)
            .background(backgroundColor)
            .overlay(
                RoundedRectangle(cornerRadius: DS.Metrics.pillHeight / 2)
                    .stroke(borderColor, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: DS.Metrics.pillHeight / 2))
        }
        .disabled(!isEnabled || isLoading)
        .opacity(isEnabled ? 1.0 : 0.45)
    }

    private var foregroundColor: Color {
        switch style {
        case .primary:
            return DS.Colors.onAccent
        case .secondary:
            return DS.Colors.textPrimary
        case .destructive:
            return Color.white
        }
    }

    private var backgroundColor: Color {
        switch style {
        case .primary:
            return DS.Colors.accent
        case .secondary:
            return DS.Colors.surfaceRaised
        case .destructive:
            return DS.Colors.destructive
        }
    }

    private var borderColor: Color {
        switch style {
        case .primary:
            return Color.clear
        case .secondary:
            return DS.Colors.hairline
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
                .background(DS.Colors.surfaceRaised)
                .clipShape(Circle())
                .overlay(
                    Circle()
                        .stroke(DS.Colors.hairline, lineWidth: 1)
                )
        }
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
                .font(.subheadline.weight(.medium))
                .foregroundColor(DS.Colors.textPrimary)
                .padding(.horizontal, DS.Metrics.spacing12)
                .frame(minHeight: DS.Metrics.minHitTarget)
                .background(DS.Colors.surfaceRaised)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(DS.Colors.hairline, lineWidth: 1))
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
        .overlay(
            RoundedRectangle(cornerRadius: DS.Metrics.cardRadius)
                .stroke(DS.Colors.hairline, lineWidth: 1)
        )
    }
}

/// The one top bar every tab uses: a light large title with round actions on the same line.
public struct ScreenHeader<Actions: View>: View {
    private let title: String
    private let actions: Actions

    public init(_ title: String, @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.actions = actions()
    }

    public var body: some View {
        HStack(spacing: DS.Metrics.spacing8) {
            Text(title)
                .font(.largeTitle.weight(.light))
                .foregroundColor(DS.Colors.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            actions
        }
    }
}

public struct SectionHeader: View {
    private let title: String

    public init(_ title: String) {
        self.title = title
    }

    public var body: some View {
        Text(title)
            .font(.title3.weight(.regular))
            .foregroundColor(DS.Colors.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
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

/// Gives any screen with text input a way to put the keyboard away: drag the content down,
/// or tap «Готово» on the bar that rides above the keyboard. Multi-line fields treat Return as a new line,
/// so without this the keyboard could not be closed.
public struct KeyboardDismissBar: ViewModifier {
    @State private var isKeyboardVisible = false

    public func body(content: Content) -> some View {
        content
            .scrollDismissesKeyboard(.interactively)
            .onAppear { KeyboardTapDismisser.shared.install() }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if isKeyboardVisible {
                    HStack {
                        Spacer()
                        Button("Готово") { hideKeyboard() }
                            .font(.body.weight(.semibold))
                            .foregroundColor(DS.Colors.accent)
                            .padding(.horizontal, DS.Metrics.spacing16)
                            .frame(minHeight: DS.Metrics.minHitTarget)
                            .accessibilityLabel("Скрыть клавиатуру")
                    }
                    .background(DS.Colors.surface)
                    .overlay(alignment: .top) { Rectangle().fill(DS.Colors.hairline).frame(height: 1) }
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
