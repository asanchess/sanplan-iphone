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
struct AccountDataSection: View {
    @EnvironmentObject private var authService: AuthService
    @EnvironmentObject private var alarmCoordinator: AlarmCoordinator
    var onDeleted: () -> Void

    @State private var exportURL: URL?
    @State private var busy = false
    @State private var error: String?
    @State private var askDelete = false
    @State private var word = ""

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Metrics.spacing12) {
            SectionHeader("Данные и аккаунт")
            Card {
                VStack(alignment: .leading, spacing: DS.Metrics.spacing12) {
                    Text("Файл JSON: планы в открытом виде, остальные разделы — зашифрованными, их откроет только ключ восстановления.")
                        .font(.footnote)
                        .foregroundColor(DS.Colors.textSecondary)
                    if let exportURL {
                        ShareLink(item: exportURL) {
                            Label("Сохранить или отправить файл", systemImage: "square.and.arrow.up")
                                .frame(minHeight: DS.Metrics.minHitTarget)
                        }
                    } else {
                        Button {
                            Task { await export() }
                        } label: {
                            Label(busy ? "Готовим файл…" : "Скачать мои данные", systemImage: "arrow.down.doc")
                                .frame(minHeight: DS.Metrics.minHitTarget)
                        }
                        .disabled(busy)
                    }
                    Divider()
                    Button(role: .destructive) {
                        word = ""
                        askDelete = true
                    } label: {
                        Label("Удалить аккаунт и данные", systemImage: "trash")
                            .frame(minHeight: DS.Metrics.minHitTarget)
                    }
                    .disabled(busy)
                    if let error {
                        Text(error)
                            .font(.footnote)
                            .foregroundColor(DS.Colors.destructive)
                            .accessibilityLabel("Ошибка: \(error)")
                    }
                }
            }
        }
        .alert("Удалить аккаунт?", isPresented: $askDelete) {
            TextField("Введите \(AccountDataAPI.confirmWord)", text: $word)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
            Button("Удалить", role: .destructive) {
                Task { await delete() }
            }
            .disabled(word.trimmingCharacters(in: .whitespaces) != AccountDataAPI.confirmWord)
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Сервер сотрёт планы, ключ и все записи аккаунта, отзовёт доступ Google и завершит вход. Это необратимо.")
        }
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
            authService.signedOutLocally()
            onDeleted()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
