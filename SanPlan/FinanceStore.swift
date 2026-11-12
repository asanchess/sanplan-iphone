import Foundation
import Combine
import CryptoKit

@MainActor
public final class FinanceStore: ObservableObject {
    @Published public private(set) var state: FinanceState = emptyFinance()
    @Published public private(set) var summary: FinanceSummary? = nil
    @Published public var notice: String? = nil
    @Published public var isBusy: Bool = false

    /// Whose money is loaded. Each signed-in account keeps its own file; nothing is loaded while signed out.
    public enum Owner: Equatable {
        /// Signed out: nothing loaded, nothing saved.
        case none
        /// The phone's shared file, for tests and debug screenshots.
        case device
        /// The account signed in with this email.
        case account(String)
    }

    public private(set) var owner: Owner
    private var isUnavailable = false
    private let fileManager: FileManager
    private let arnaDir: URL
    private var storageURL: URL
    private var corruptFolderURL: URL

    public init(fileManager: FileManager = .default, owner: Owner = .device) {
        self.fileManager = fileManager

        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let arnaDir = appSupport.appendingPathComponent("ARNA", isDirectory: true)
        self.arnaDir = arnaDir

        try? fileManager.createDirectory(at: arnaDir, withIntermediateDirectories: true, attributes: nil)

        self.owner = owner
        self.storageURL = arnaDir.appendingPathComponent("finance_state.json")
        self.corruptFolderURL = arnaDir.appendingPathComponent("corrupt", isDirectory: true)

        switchOwner(to: owner, force: true)
    }

    /// The phone's shared file from before money was kept per account.
    private var sharedURL: URL { arnaDir.appendingPathComponent("finance_state.json") }

    /// A folder per account, named by a hash of the email so the address itself is not written to disk.
    nonisolated static func accountFolderName(_ email: String) -> String {
        let normalized = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// Loads the money of whoever is signed in now. The same owner again changes nothing, so open work stays.
    /// The first account to sign in after the update takes over the phone's earlier shared file.
    public func switchOwner(to next: Owner, force: Bool = false) {
        guard force || next != owner else { return }
        owner = next
        summary = nil
        notice = nil
        isBusy = false
        switch next {
        case .none:
            state = emptyFinance()
            isUnavailable = false
            return
        case .device:
            storageURL = sharedURL
            corruptFolderURL = arnaDir.appendingPathComponent("corrupt", isDirectory: true)
        case .account(let email):
            let folder = arnaDir.appendingPathComponent("accounts", isDirectory: true)
                .appendingPathComponent(Self.accountFolderName(email), isDirectory: true)
            try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: nil)
            storageURL = folder.appendingPathComponent("finance_state.json")
            corruptFolderURL = folder.appendingPathComponent("corrupt", isDirectory: true)
            if !fileManager.fileExists(atPath: storageURL.path), fileManager.fileExists(atPath: sharedURL.path) {
                // A move, not a copy: the next account to sign in starts empty instead of seeing this money.
                try? fileManager.moveItem(at: sharedURL, to: storageURL)
            }
        }
        loadInitialState()
    }

    // MARK: - State Management

    public func refreshSummary(today: String, horizonDays: Int = 30) {
        do {
            let s = try financeSummary(state, today: today, horizonDays: horizonDays)
            self.summary = s
        } catch {
            self.summary = nil
        }
    }

    public func commit(drafts: [FinanceDraft], today: String, batchId: String = UUID().uuidString) throws {
        let next = try commitFinance(state: state, drafts: drafts, batchId: batchId, nowDate: today)
        try updateState(next, today: today)
    }

    public func remove(recordId: String, today: String) throws {
        let next = try removeFinanceRecord(state: state, id: recordId)
        try updateState(next, today: today)
    }

    public func replaceState(with newState: FinanceState, today: String) throws {
        let clean = try validateFinance(newState)
        try updateState(clean, today: today)
    }

    public func reset() {
        self.state = emptyFinance()
        self.summary = nil
        self.notice = nil
        if owner != .none { try? fileManager.removeItem(at: storageURL) }
        isUnavailable = false
    }

    // MARK: - Persistence

    private func updateState(_ newState: FinanceState, today: String) throws {
        guard owner != .none else { throw FinanceError.invalidState("Войдите в аккаунт, чтобы сохранять финансы.") }
        reloadIfUnavailable()
        if isUnavailable {
            throw FinanceVaultError.decryptionFailed("Финансы недоступны, пока телефон заблокирован.")
        }
        let clean = try validateFinance(newState)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        let data = try encoder.encode(clean)

        let writeOptions: Data.WritingOptions = [.atomic, .completeFileProtection]
        try data.write(to: storageURL, options: writeOptions)

        self.state = clean
        refreshSummary(today: today)
        self.notice = nil
    }

    /// Call when the app becomes active, in case the first load happened while the phone was locked.
    public func reloadIfUnavailable() {
        if isUnavailable && owner != .none { loadInitialState() }
    }

    private func loadInitialState() {
        guard owner != .none, fileManager.fileExists(atPath: storageURL.path) else {
            self.state = emptyFinance()
            isUnavailable = false
            return
        }

        // A protected file cannot be read while the phone is locked. That is not corruption,
        // so the file stays where it is and writes wait until it can be read.
        let data: Data
        do {
            data = try Data(contentsOf: storageURL)
            isUnavailable = false
        } catch {
            isUnavailable = true
            self.state = emptyFinance()
            self.notice = "Финансы недоступны, пока телефон заблокирован."
            return
        }

        do {
            let decoded = try JSONDecoder().decode(FinanceState.self, from: data)
            let clean = try validateFinance(decoded)
            self.state = clean
            self.notice = nil
        } catch {
            preserveCorruptFile()
            self.state = emptyFinance()
            self.notice = "Не удалось прочитать сохранённый файл финансов. Повреждённые данные сохранены в копию, запущен чистый профиль."
        }
    }

    private func preserveCorruptFile() {
        try? fileManager.createDirectory(at: corruptFolderURL, withIntermediateDirectories: true, attributes: nil)
        let timestamp = Int(Date().timeIntervalSince1970)
        let destination = corruptFolderURL.appendingPathComponent("finance_state_corrupt_\(timestamp).json")
        try? fileManager.moveItem(at: storageURL, to: destination)
    }
}

// MARK: - Reading a phrase through the server

struct FinanceParseRequest: Encodable {
    let text: String
    let today: String
    let kindHint: String?
}

struct FinanceParseResponse: Decodable {
    let drafts: [FinanceDraft]?
    let source: String?
}

/// Sends only the typed or dictated phrase and today's date to ARNA's server, which asks Gemini to read it.
/// Balances, history and other records never leave the phone; the server does not keep the phrase.
public enum FinanceAPI {
    public static func parse(client: APIClient, text: String, today: String, kindHint: String?) async throws -> [FinanceDraft] {
        let body = FinanceParseRequest(text: text, today: today, kindHint: kindHint)
        let response: FinanceParseResponse = try await client.post(path: "/api/finance/parse", body: body)
        return response.drafts ?? []
    }
}
