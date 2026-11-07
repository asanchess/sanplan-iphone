import SwiftUI

/// One input for Plans and Money: a growing text field with the mic inside it.
/// Live speech streams into the same text, which stays editable; «Разобрать» parses exactly what is in the field.
struct ComposerField: View {
    let placeholder: String
    @Binding var text: String
    let isListening: Bool
    let level: Float
    var isBusy: Bool = false
    var parseTitle: String = "Разобрать"
    let onMic: () -> Void
    let onParse: () -> Void
    let onClear: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var hasText: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: DS.Metrics.spacing12) {
            HStack(alignment: .bottom, spacing: DS.Metrics.spacing8) {
                TextField(placeholder, text: $text, axis: .vertical)
                    .lineLimit(1...6)
                    .font(.body)
                    .foregroundColor(DS.Colors.textPrimary)
                    .padding(.vertical, 10)
                    .padding(.leading, DS.Metrics.spacing12)
                    .accessibilityLabel(placeholder)

                micButton
                    .padding(.trailing, 4)
                    .padding(.bottom, 4)
            }
            .background(DS.Colors.surfaceRaised)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(isListening ? DS.Colors.accent : DS.Colors.hairline, lineWidth: isListening ? 1.5 : 1)
            )

            if hasText || isListening {
                HStack(spacing: DS.Metrics.spacing12) {
                    PillButton("Очистить", style: .secondary) { onClear() }
                        .frame(maxWidth: 150)
                    PillButton(parseTitle, icon: "sparkles", style: .primary, isLoading: isBusy, isEnabled: hasText) {
                        onParse()
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.85), value: hasText || isListening)
    }

    private var micButton: some View {
        Button(action: onMic) {
            ZStack {
                Circle()
                    .fill(isListening ? DS.Colors.accent : DS.Colors.accent.opacity(0.14))
                if isListening && !reduceMotion {
                    Circle()
                        .stroke(DS.Colors.accent.opacity(0.45), lineWidth: 2)
                        .scaleEffect(1 + CGFloat(level) * 0.5)
                        .animation(.linear(duration: 0.1), value: level)
                }
                Image(systemName: isListening ? "stop.fill" : "mic.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(isListening ? DS.Colors.onAccent : DS.Colors.accent)
            }
            .frame(width: 36, height: 36)
            .frame(width: DS.Metrics.minHitTarget, height: DS.Metrics.minHitTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isListening ? "Остановить диктовку" : "Диктовать")
        .sensoryFeedback(.impact(weight: .light), trigger: isListening)
    }
}
