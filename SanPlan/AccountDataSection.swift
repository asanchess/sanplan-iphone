import SwiftUI

/// Server calls for «Скачать мои данные» and «Удалить аккаунт и данные» (privacy policy, «Срок хранения, экспорт и удаление»).
enum AccountDataAPI {
    static let confirmWord = "УДАЛИТЬ"

    struct DeleteBody: Encodable { let confirm: String }
    struct Failure: Decodable { let message: String? }

    /// The export JSON saved to a temporary file, ready for the share sheet.
    static func export(client: APIClient) async throws -> URL {
        let (status, data) = try await client.send(method: "GET", path: "/api/account/export")
        guard status == 200 else { throw APIError.server(status: status, message: message(data) ?? "Не удалось скачать данные.") }
        let day = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("arna-export-\(day).json")
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }

    static func delete(client: APIClient) async throws {
        let (status, data) = try await client.send(method: "POST", path: "/api/account/delete", body: DeleteBody(confirm: confirmWord))
        guard status == 200 else { throw APIError.server(status: status, message: message(data) ?? "Не удалось удалить аккаунт.") }
    }

    private static func message(_ data: Data) -> String? {
        (try? JSONDecoder().decode(Failure.self, from: data))?.message
    }
}

/// Settings block «Данные и аккаунт».
/// «Профиль → Аккаунт»: email, export, delete and sign-out, in canvas rows.
struct AccountDataSection: View {
    @EnvironmentObject private var authService: AuthService
    @EnvironmentObject private var alarmCoordinator: AlarmCoordinator
    let email: String
    var onDeleted: () -> Void
    var onSignedOut: () -> Void

    @State private var exportURL: URL?
    @State private var busy = false
    @State private var error: String?
    @State private var askDelete = false
    @State private var askSignOut = false
    @State private var word = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProfileGroup("Аккаунт") {
                ProfileNameRow(email: email)
                ProfileRow("Электронная почта") { ProfileValue(email) }
                if let exportURL {
                    ShareLink(item: exportURL) {
                        ProfileRow("Сохранить или отправить файл", note: "Файл готов") {
                            Image(systemName: "square.and.arrow.up").foregroundColor(DS.Colors.today).accessibilityHidden(true)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(ProfileRowButtonStyle())
                } else {
                    Button {
                        Task { await export() }
                    } label: {
                        ProfileRow(busy ? "Готовим файл…" : "Скачать мои данные",
                                   note: "JSON: планы в открытом виде, остальное — зашифрованным ключом данных аккаунта") {
                            Image(systemName: "arrow.down.doc").foregroundColor(DS.Colors.today).accessibilityHidden(true)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(ProfileRowButtonStyle())
                    .disabled(busy)
                }
                Button {
                    askSignOut = true
                } label: {
                    ProfileRow("Выйти из аккаунта", nameColor: DS.Colors.destructive) {
                        if authService.isAuthenticating { ProgressView().tint(DS.Colors.destructive) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(ProfileRowButtonStyle())
                .disabled(busy || authService.isAuthenticating)
                Button {
                    word = ""
                    askDelete = true
                } label: {
                    ProfileRow("Удалить аккаунт и данные", note: "Необратимо", nameColor: DS.Colors.destructive).contentShape(Rectangle())
                }
                .buttonStyle(ProfileRowButtonStyle())
                .disabled(busy)
            }
            if let error {
                Text(error)
                    .font(DS.Fonts.text(14, .medium, relativeTo: .footnote))
                    .foregroundColor(DS.Colors.destructive)
                    .accessibilityLabel("Ошибка: \(error)")
            }
        }
        .confirmationDialog("Вы уверены, что хотите выйти?", isPresented: $askSignOut, titleVisibility: .visible) {
            Button("Выйти", role: .destructive) {
                Task { await signOut() }
            }
            Button("Отмена", role: .cancel) {}
        }
        .sheet(isPresented: $askDelete) {
            DeleteAccountSheet(word: $word) {
                askDelete = false
                Task { await delete() }
            }
            .presentationDetents([.medium, .large])
        }
    }

    private func signOut() async {
        await authService.signOut()
        // Plan titles must not keep ringing after the owner signed out on purpose.
        // A session that merely expired keeps its alarms: a missed alarm is the worse failure.
        if authService.phase == .signedOut {
            await alarmCoordinator.deleteAllOwnAlarms()
            // Apple Pay payments, notifications and shared statements not yet taken in must not go to the next
            // account; an expired session keeps them.
            BankFeedInbox.standard().clear()
            BankNotificationReview.standard().clear()
            BankStatementInbox.standard().clear()
        }
        onSignedOut()
    }

    private func export() async {
        busy = true
        error = nil
        defer { busy = false }
        do {
            exportURL = try await AccountDataAPI.export(client: authService.client)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func delete() async {
        guard word.trimmingCharacters(in: .whitespaces) == AccountDataAPI.confirmWord else { return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            try await AccountDataAPI.delete(client: authService.client)
            await alarmCoordinator.deleteAllOwnAlarms()
            // Payments, notifications and statements waiting on the phone belonged to the deleted account.
            BankFeedInbox.standard().clear()
            BankNotificationReview.standard().clear()
            BankStatementInbox.standard().clear()
            authService.signedOutLocally()
            onDeleted()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// «Удалить аккаунт»: a warning, the confirm word, and a «Удалить» that wakes up only after 5 seconds.
struct DeleteAccountSheet: View {
    @Binding var word: String
    let onDelete: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var secondsLeft = 5

    private var wordOK: Bool { word.trimmingCharacters(in: .whitespaces) == AccountDataAPI.confirmWord }
    private var canDelete: Bool { wordOK && secondsLeft == 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 34, weight: .bold))
                .foregroundColor(DS.Colors.destructive)
                .accessibilityHidden(true)
            Text("Удалить аккаунт навсегда?")
                .font(DS.Fonts.text(24, .heavy, relativeTo: .title2))
                .foregroundColor(DS.Colors.textPrimary)
            Text("Сотрутся планы, заметки, деньги, тренировки и ключ аккаунта. Вернуть их будет нельзя.")
                .font(DS.Fonts.text(16, .medium, relativeTo: .body))
                .foregroundColor(DS.Colors.textMuted)
            TextField("Введите \(AccountDataAPI.confirmWord)", text: $word)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 14).fill(DS.Colors.surface))
                .accessibilityIdentifier("delete-account-word")
            HStack(spacing: 12) {
                Button("Отмена") { dismiss() }
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(RoundedRectangle(cornerRadius: 16).fill(DS.Colors.surface))
                    .foregroundColor(DS.Colors.textPrimary)
                Button {
                    onDelete()
                } label: {
                    Text(secondsLeft > 0 ? "Удалить (\(secondsLeft))" : "Удалить")
                        .font(DS.Fonts.text(17, .heavy, relativeTo: .body))
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(RoundedRectangle(cornerRadius: 16).fill(DS.Colors.destructive.opacity(canDelete ? 1 : 0.35)))
                        .foregroundColor(DS.Colors.ink)
                }
                .disabled(!canDelete)
                .accessibilityIdentifier("delete-account-confirm")
            }
        }
        .padding(24)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(DS.Colors.canvas.ignoresSafeArea())
        .task {
            secondsLeft = 5
            while secondsLeft > 0 {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                secondsLeft -= 1
            }
        }
    }
}
