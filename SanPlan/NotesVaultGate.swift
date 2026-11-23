import SwiftUI

/// «Заметки» until this device holds the account's data key, drawn like the notes canvas.
/// The server holds the key, so signing in is enough; the only thing ever asked is the one-time transfer
/// of an older recovery key («Перенос данных в аккаунт»).
struct NotesVaultGateView: View {
    @ObservedObject var vault: VaultKeySession

    @State private var recoveryText = ""
    @State private var recoveryError: String?
    @State private var isWorking = false
    @FocusState private var fieldFocused: Bool
    @Environment(\.sectionAccent) private var accent

    var body: some View {
        ZStack(alignment: .top) {
            DS.Colors.canvas.ignoresSafeArea()
            NotesBackdrop()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ScreenHeader("Заметки", kicker: "Зашифрованы") {
                    }
                    content
                }
                .padding(.horizontal, DS.Metrics.screenGutter)
                .padding(.top, 18)
                .padding(.bottom, DS.Metrics.spacing24)
                .frame(maxWidth: 560, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .shellRoot()
    }

    @ViewBuilder
    private var content: some View {
        switch vault.phase {
        case .idle, .checking, .ready:
            HStack(spacing: DS.Metrics.spacing12) {
                ProgressView().tint(accent)
                Text("Открываем данные аккаунта…")
                    .font(DS.Fonts.text(15, .medium, relativeTo: .subheadline))
                    .foregroundColor(DS.Colors.textSecondary)
            }
            .padding(.top, DS.Metrics.spacing8)
        case .needsTransfer:
            transfer
        case .failed(let message):
            ErrorBanner(message: message)
            PillButton("Повторить", style: .secondary) { Task { await vault.check() } }
        }
    }

    private var transfer: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(DS.Colors.ink)
                    .frame(width: 40, height: 40)
                    .background(accent, in: Circle())
                    .overlay(Circle().stroke(DS.Colors.edge, lineWidth: 1))
                    .accessibilityHidden(true)
                Text("Перенос данных в аккаунт")
                    .font(DS.Fonts.text(19, .heavy, relativeTo: .headline))
                    .foregroundColor(DS.Colors.textPrimary)
                    .accessibilityAddTraits(.isHeader)
            }
            Text("Данные этого аккаунта были зашифрованы ключом восстановления. Введите его один раз — дальше они открываются входом через Google на любом устройстве.")
                .font(DS.Fonts.text(15, .medium, relativeTo: .subheadline))
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("XXXX XXXX XXXX XXXX XXXX XXXX XXXX XXXX", text: $recoveryText, axis: .vertical)
                .font(.system(.body, design: .monospaced))
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .textContentType(.password)
                .foregroundColor(DS.Colors.textPrimary)
                .focused($fieldFocused)
                .padding(14)
                .background(DS.Colors.surfaceRaised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(fieldStroke, lineWidth: recoveryError != nil || fieldFocused ? 2 : 1)
                )
                .accessibilityLabel("Ключ восстановления")
            if let recoveryError {
                Text(recoveryError)
                    .font(DS.Fonts.text(13, .bold, relativeTo: .footnote))
                    .foregroundColor(DS.Colors.destructive)
            }
            PillButton("Перенести данные", isLoading: isWorking, isEnabled: !recoveryText.trimmingCharacters(in: .whitespaces).isEmpty) {
                isWorking = true
                Task {
                    recoveryError = await vault.restore(recoveryText: recoveryText)
                    if recoveryError == nil { recoveryText = "" }
                    isWorking = false
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Colors.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .inked(cornerRadius: 22, shadow: 6)
    }

    private var fieldStroke: Color {
        if recoveryError != nil { return DS.Colors.destructive }
        return fieldFocused ? accent : DS.Colors.hairline
    }
}
