import SwiftUI
import UIKit

/// Shown in place of encrypted sections until this device holds the account's data key. The server holds the key,
/// so signing in is enough; the only thing ever asked is the one-time transfer of an older recovery key.
struct VaultGateView: View {
    @ObservedObject var vault: VaultKeySession
    @Binding var showSettings: Bool

    @State private var recoveryText = ""
    @State private var recoveryError: String?
    @State private var isWorking = false

    var body: some View {
        ZStack {
            DS.Colors.canvas.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Metrics.spacing16) {
                    ScreenHeader("Заметки") {
                    }
                    content
                }
                .padding(.horizontal, DS.Metrics.screenGutter)
                .padding(.vertical, DS.Metrics.spacing16)
                .frame(maxWidth: 560, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch vault.phase {
        case .idle, .checking, .ready:
            HStack(spacing: DS.Metrics.spacing12) {
                ProgressView().tint(DS.Colors.accent)
                Text("Открываем данные аккаунта…").foregroundColor(DS.Colors.textSecondary)
            }
            .padding(.top, DS.Metrics.spacing24)
        case .needsTransfer:
            transfer
        case .failed(let message):
            ErrorBanner(message: message)
            PillButton("Повторить", style: .secondary) { Task { await vault.check() } }
        }
    }

    private var transfer: some View {
        Card {
            SectionHeader("Перенос данных в аккаунт")
            Text("Данные этого аккаунта были зашифрованы ключом восстановления. Введите его один раз — дальше они открываются входом через Google на любом устройстве.")
                .font(.subheadline)
                .foregroundColor(DS.Colors.textSecondary)
            TextField("XXXX XXXX XXXX XXXX XXXX XXXX XXXX XXXX", text: $recoveryText, axis: .vertical)
                .font(.system(.body, design: .monospaced))
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .textContentType(.password)
                .foregroundColor(DS.Colors.textPrimary)
                .padding(DS.Metrics.spacing12)
                .background(DS.Colors.surfaceRaised)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(recoveryError == nil ? DS.Colors.hairline : DS.Colors.destructive, lineWidth: 1))
                .accessibilityLabel("Ключ восстановления")
            if let recoveryError {
                Text(recoveryError).font(.footnote).foregroundColor(DS.Colors.destructive)
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
    }
}

/// The «+» composer: one field for anything. It saves as a note; a time or a sum only adds an offer.
struct CaptureSheet: View {
    @ObservedObject var inputs: InputDrafts
    @ObservedObject var dictation: SpeechDictation
    @ObservedObject var notes: NotesStore
    /// nil while «Планы» / «Деньги» is turned off: that hand-off is not offered.
    let onMakePlan: ((String) -> Void)?
    let onMakeExpense: ((String) -> Void)?
    /// False while «Заметки» is turned off: the record goes to a plan or a spending instead of a note.
    var notesOn: Bool = true
    let onSaved: () -> Void
    /// Answers questions typed into «+» from the other sections' data (nil: no answers offered).
    var askData: (() -> AskData)? = nil

    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    private var text: String { inputs.notes }
    private var hasText: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        NavigationStack {
            ZStack {
                DS.Colors.canvas.ignoresSafeArea()
                VStack(alignment: .leading, spacing: DS.Metrics.spacing16) {
                    ComposerField(
                        placeholder: placeholder,
                        text: Binding(get: { inputs.notes }, set: { inputs.edit($0, for: .notes) }),
                        isListening: dictation.isListening(to: .notes),
                        level: dictation.level,
                        parseTitle: primaryTitle,
                        onMic: {
                            if dictation.isListening(to: .notes) { dictation.stop() }
                            else { Task { await dictation.start(into: .notes) } }
                        },
                        onParse: save,
                        onClear: {
                            dictation.stop()
                            inputs.clear(.notes)
                        }
                    )
                    .focused($focused)

                    if let error = dictation.errorMessage {
                        Text(error).font(.footnote).foregroundColor(DS.Colors.destructive)
                    }
                    if notesOn, !notes.isAvailable, onMakePlan != nil || onMakeExpense != nil {
                        Text("Заметки откроются после входа в аккаунт. Запись можно отправить в другой раздел.")
                            .font(.footnote)
                            .foregroundColor(DS.Colors.textSecondary)
                    }
                    offers
                    Spacer()
                }
                .padding(DS.Metrics.screenGutter)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Записать")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") {
                        // The draft stays: closing is not discarding.
                        if dictation.isListening(to: .notes) { dictation.stop() }
                        dismiss()
                    }
                }
            }
        }
        .onAppear { focused = true }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private var offers: some View {
        if hasText {
            let hints = NoteText.hints(text)
            VStack(alignment: .leading, spacing: DS.Metrics.spacing8) {
                if let askData { AskOffer(text: text, data: askData) }
                if (hints.looksLikePlan && offersPlan) || (hints.looksLikeExpense && offersExpense) {
                    Text("Похоже на").font(.footnote).foregroundColor(DS.Colors.textSecondary)
                }
                HStack(spacing: DS.Metrics.spacing8) {
                    if offersPlan, let onMakePlan {
                        HeaderTextButton("Сделать планом", icon: "calendar.badge.plus") { handOff(onMakePlan) }
                            .opacity(hints.looksLikePlan ? 1 : 0.7)
                    }
                    if offersExpense, let onMakeExpense {
                        HeaderTextButton("Записать трату", icon: "creditcard") { handOff(onMakeExpense) }
                            .opacity(hints.looksLikeExpense ? 1 : 0.7)
                    }
                }
            }
        }
    }

    // Without «Заметки» the main button sends the record to «Планы» (else «Деньги»), and the offer below
    // keeps only the other section, so no button repeats the main one.
    private var primaryIsPlan: Bool { !notesOn && onMakePlan != nil }
    private var primaryIsExpense: Bool { !notesOn && onMakePlan == nil && onMakeExpense != nil }
    private var offersPlan: Bool { onMakePlan != nil && !primaryIsPlan }
    private var offersExpense: Bool { onMakeExpense != nil && !primaryIsExpense }

    private var primaryTitle: String {
        primaryIsPlan ? "Сделать планом" : primaryIsExpense ? "Записать трату" : "Сохранить заметку"
    }

    private var placeholder: String {
        var kinds: [String] = []
        if notesOn { kinds.append("Мысль, список") }
        if onMakePlan != nil { kinds.append("план") }
        if onMakeExpense != nil { kinds.append("трата") }
        guard let last = kinds.last else { return "Запись" }
        let line = kinds.count == 1 ? last : kinds.dropLast().joined(separator: ", ") + " или " + last
        return line.prefix(1).uppercased() + line.dropFirst()
    }

    private func save() {
        if primaryIsPlan, let onMakePlan { handOff(onMakePlan); return }
        if primaryIsExpense, let onMakeExpense { handOff(onMakeExpense); return }
        guard notes.isAvailable else { return }
        if dictation.isListening(to: .notes) { dictation.stop() }
        let value = inputs.take(.notes)
        guard notes.create(text: value) != nil else { inputs.edit(value, for: .notes); return }
        onSaved()
        dismiss()
    }

    private func handOff(_ action: (String) -> Void) {
        if dictation.isListening(to: .notes) { dictation.stop() }
        let value = inputs.take(.notes)
        guard !value.isEmpty else { return }
        dismiss()
        action(value)
    }
}
