import SwiftUI
import UIKit

/// Shown in place of encrypted sections until this device holds the account's data key.
struct VaultGateView: View {
    @ObservedObject var vault: VaultKeySession
    @Binding var showSettings: Bool

    @State private var recoveryText = ""
    @State private var recoveryError: String?
    @State private var isWorking = false
    @State private var savedConfirmed = false
    @State private var copied = false

    var body: some View {
        ZStack {
            DS.Colors.canvas.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Metrics.spacing16) {
                    ScreenHeader("Заметки") {
                        CircleIconButton(icon: "person.crop.circle", accessibilityLabel: "Настройки") { showSettings = true }
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
                Text("Проверяем ключ шифрования…").foregroundColor(DS.Colors.textSecondary)
            }
            .padding(.top, DS.Metrics.spacing24)
        case .needsSetup:
            if let key = vault.pendingRecoveryKey {
                showKey(key)
            } else {
                setupIntro
            }
        case .needsRecovery:
            recovery
        case .failed(let message):
            ErrorBanner(message: message)
            PillButton("Повторить", style: .secondary) { Task { await vault.check() } }
        }
    }

    private var setupIntro: some View {
        Card {
            SectionHeader("Шифрование заметок")
            Text("Заметки шифруются на этом телефоне. Сервер хранит только зашифрованный текст и не может его прочитать.")
                .foregroundColor(DS.Colors.textPrimary)
            Text("Для входа на другом устройстве понадобится ключ восстановления. Он появится на следующем шаге.")
                .font(.subheadline)
                .foregroundColor(DS.Colors.textSecondary)
            PillButton("Создать ключ", icon: "key") { vault.beginSetup() }
        }
    }

    private func showKey(_ key: String) -> some View {
        Card {
            SectionHeader("Ключ восстановления")
            Text("Сохраните его в менеджере паролей или запишите. Без ключа заметки не открыть на новом устройстве — даже нам.")
                .font(.subheadline)
                .foregroundColor(DS.Colors.textSecondary)
            Text(key.replacingOccurrences(of: "-", with: " "))
                .font(.system(.title3, design: .monospaced).weight(.medium))
                .foregroundColor(DS.Colors.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(DS.Metrics.spacing16)
                .background(DS.Colors.surfaceRaised)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityLabel("Ключ восстановления: \(key.map { String($0) }.joined(separator: " "))")
            PillButton(copied ? "Скопировано" : "Скопировать", icon: copied ? "checkmark" : "doc.on.doc", style: .secondary) {
                // Local only and short-lived, so the key does not travel to other devices or stay on the clipboard.
                UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: key]], options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(120)])
                copied = true
            }
            Toggle(isOn: $savedConfirmed) {
                Text("Я сохранил ключ").foregroundColor(DS.Colors.textPrimary)
            }
            .tint(DS.Colors.accent)
            .frame(minHeight: DS.Metrics.minHitTarget)
            PillButton("Готово", isLoading: isWorking, isEnabled: savedConfirmed) {
                isWorking = true
                Task {
                    await vault.confirmSetup()
                    isWorking = false
                }
            }
        }
    }

    private var recovery: some View {
        Card {
            SectionHeader("Введите ключ восстановления")
            Text("Заметки этого аккаунта зашифрованы. Ключ показывался при первой настройке на другом устройстве: 32 знака, буквы и цифры.")
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
            PillButton("Открыть заметки", isLoading: isWorking, isEnabled: !recoveryText.trimmingCharacters(in: .whitespaces).isEmpty) {
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
    let onMakePlan: (String) -> Void
    let onMakeExpense: (String) -> Void
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
                        placeholder: "Мысль, список, план или трата",
                        text: Binding(get: { inputs.notes }, set: { inputs.edit($0, for: .notes) }),
                        isListening: dictation.isListening(to: .notes),
                        level: dictation.level,
                        parseTitle: "Сохранить заметку",
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
                    if !notes.isAvailable {
                        Text("Заметки откроются после настройки шифрования во вкладке «Заметки». Запись можно сделать планом или тратой.")
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
                if hints.looksLikePlan || hints.looksLikeExpense {
                    Text("Похоже на").font(.footnote).foregroundColor(DS.Colors.textSecondary)
                }
                HStack(spacing: DS.Metrics.spacing8) {
                    HeaderTextButton("Сделать планом", icon: "calendar.badge.plus") { handOff(onMakePlan) }
                        .opacity(hints.looksLikePlan ? 1 : 0.7)
                    HeaderTextButton("Записать трату", icon: "creditcard") { handOff(onMakeExpense) }
                        .opacity(hints.looksLikeExpense ? 1 : 0.7)
                }
            }
        }
    }

    private func save() {
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
