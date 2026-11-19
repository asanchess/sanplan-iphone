import SwiftUI

/// The one bottom field of «Планы» (canvas: a 56 pt pill «Что запланировать?» and the «Разобрать» button).
/// The mic sits inside the field; live speech streams into the same text, which stays editable.
/// What «Разобрать» does depends on the tab: a plan (AI parse), a habit or a goal. Nothing is saved before «Понял так».
struct PlansComposerBar: View {
    let placeholder: String
    @Binding var text: String
    let isListening: Bool
    let level: Float
    let isBusy: Bool
    let onMic: () -> Void
    let onParse: () -> Void
    let onClear: () -> Void

    @Environment(\.sectionAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool

    private var hasText: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            HStack(alignment: .bottom, spacing: 2) {
                TextField(text: $text, prompt: Text(placeholder).foregroundColor(DS.Colors.textMuted), axis: .vertical) {
                    Text(placeholder)
                }
                .lineLimit(1...5)
                .font(DS.Fonts.text(17, .medium))
                .foregroundColor(DS.Colors.textPrimary)
                .tint(accent)
                .focused($focused)
                .padding(.vertical, 16)
                .accessibilityLabel(placeholder)

                if hasText && !isListening {
                    Button(action: onClear) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 17))
                            .foregroundColor(DS.Colors.textMuted)
                            .frame(width: 36, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 6)
                    .accessibilityLabel("Очистить")
                }

                micButton
                    .padding(.bottom, 6)
            }
            .padding(.leading, 18)
            .padding(.trailing, 6)
            .frame(minHeight: 56)
            .background(DS.Colors.surfaceRaised, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .strokeBorder(focused || isListening ? accent : Color.clear, lineWidth: 2)
            )
            .tourTarget("plans.composer")

            Button(action: onParse) {
                ZStack {
                    Text("Разобрать").opacity(isBusy ? 0 : 1)
                    if isBusy {
                        ProgressView().tint(DS.Colors.canvas)
                    }
                }
                .font(DS.Fonts.text(15, .heavy, relativeTo: .subheadline))
                .foregroundColor(DS.Colors.canvas)
                .padding(.horizontal, 18)
                .frame(height: 56)
                .background(accent, in: Capsule())
            }
            .buttonStyle(PressScaleStyle())
            .disabled(!hasText || isBusy)
            .opacity(hasText || isBusy ? 1 : 0.55)
            .accessibilityLabel(isBusy ? "Разбираю" : "Разобрать")
        }
        .padding(.horizontal, DS.Metrics.screenGutter)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private var micButton: some View {
        Button(action: onMic) {
            ZStack {
                Circle().fill(isListening ? accent : accent.opacity(0.16))
                if isListening && !reduceMotion {
                    Circle()
                        .stroke(accent.opacity(0.45), lineWidth: 2)
                        .scaleEffect(1 + CGFloat(level) * 0.5)
                        .animation(.linear(duration: 0.1), value: level)
                }
                Image(systemName: isListening ? "stop.fill" : "mic.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(isListening ? DS.Colors.canvas : accent)
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
