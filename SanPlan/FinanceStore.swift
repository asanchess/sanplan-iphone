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

    /// Where money is kept now: the phone's file, or the encrypted collection `finance` once it is attached and the
    /// move has been checked (docs/contracts/FINANCE-MIGRATION.md).
    public enum Storage: Equatable {
        case local
        case migrating
        case cloud
    }
    @Published public private(set) var storage: Storage = .local
    private var collection: VaultCollection<FinancePayload>?
    private var collectionObserver: AnyCancellable?
    private var isUnavailable = false
    private let fileManager: FileManager
    private let arnaDir: URL
    private var storageURL: URL
    private var corruptFolderURL: URL

    /// `baseDirectory` replaces Application Support (tests only).
    public init(fileManager: FileManager = .default, owner: Owner = .device, baseDirectory: URL? = nil) {
        self.fileManager = fileManager

        let appSupport = baseDirectory ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
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

    // MARK: - Encrypted collection

    /// Called by the coordinator after the data key is unlocked and `collection.attach` has run.
    /// Money from the phone's file moves into the collection once; after that the collection is the source.
    public func attach(collection: VaultCollection<FinancePayload>) {
        detach()
        self.collection = collection
        collectionObserver = collection.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.collectionChanged() }
        }
        Task { await self.moveToCollectionIfNeeded() }
    }

    /// Signed out or key locked: back to the local file; nothing of the collection stays in memory here.
    public func detach() {
        collectionObserver = nil
        collection = nil
        if storage != .local {
            storage = .local
            let current = owner
            switchOwner(to: current, force: true)
        }
    }

    private func collectionChanged() {
        guard storage == .cloud, let collection, collection.isAvailable else { return }
        let rebuilt = FinanceCloud.state(from: collection.items)
        let clean = (try? validateFinance(rebuilt)) ?? rebuilt
        if clean != state {
            state = clean
            refreshSummary(today: FinanceText.today())
        }
        // The website saves a record without its account fields; the statement gives them back.
        if collection.hasSynced, let restored = FinanceLedger.upkeep(state) {
            try? updateState(restored, today: FinanceText.today())
        }
        takeInBankFeed(today: FinanceText.today())
        Task { await takeInStatements(today: FinanceText.today()) }
    }

    // MARK: - Payments from Wallet

    /// Where the Shortcuts action leaves Apple Pay payments (BankFeed.swift); the same folder as `BankFeedInbox.standard()`.
    var bankFeedInbox: BankFeedInbox {
        BankFeedInbox(folder: arnaDir.appendingPathComponent("bank-feed-inbox", isDirectory: true), fileManager: fileManager)
    }

    /// Takes waiting Apple Pay payments into money. Only once the account's money lives in its encrypted collection
    /// (or in the test file), so a payment is never written to a phone file that a later move would replace.
    /// In the cloud, only after the collection's first sync, so a statement loaded on another device is seen first.
    /// Returns how many were added; repeats are dropped and payments a statement already has are kept with it.
    @discardableResult
    public func takeInBankFeed(today: String) -> Int {
        let ready = storage == .cloud ? collection?.hasSynced == true : owner == .device
        guard owner != .none, !isUnavailable, ready else { return 0 }
        let waiting = bankFeedInbox.pending()
        guard !waiting.isEmpty else { return 0 }
        var next = state
        var added = 0
        var changed = false
        var handled: [URL] = []
        for item in waiting {
            do {
                let result = try BankFeed.ingest(item.tap, into: next, today: today)
                next = result.state
                switch result.outcome {
                case .added: added += 1; changed = true
                case .inStatement: changed = true
                case .duplicate: break
                }
                handled.append(item.url)
            } catch is BankFeed.TapError {
                // A payment the action could not read never becomes readable.
                handled.append(item.url)
            } catch {
                return 0
            }
        }
        do {
            if changed { try updateState(next, today: today) }
        } catch {
            return 0
        }
        bankFeedInbox.remove(handled)
        return added
    }

    /// Signing out on purpose leaves no payment waiting for the next account. An expired session keeps them.
    public func discardBankFeed() {
        bankFeedInbox.clear()
        bankStatementInbox.clear()
    }

    // MARK: - Statements shared to A-san

    /// Where shared PDF statements wait (BankStatementInbox.swift); the same folder as `BankStatementInbox.standard()`.
    var bankStatementInbox: BankStatementInbox {
        BankStatementInbox(folder: arnaDir.appendingPathComponent("bank-statement-inbox", isDirectory: true), fileManager: fileManager)
    }

    /// The last statement that came through «Поделиться» and could not be loaded, for the «Деньги» screen to show.
    @Published public private(set) var sharedStatementProblem: String?
    private var takingStatements = false
    /// A statement arrived while others were being read: read again at the end.
    private var moreStatements = false

    /// Loads statements shared to A-san, the same way as the import in «Деньги» but without the preview: operations an
    /// earlier statement already has are left out, and Apple Pay payments and notifications give way to the lines.
    /// Each load can be undone. Ready under the same rule as `takeInBankFeed`. Returns how many statements were loaded.
    @discardableResult
    public func takeInStatements(today: String) async -> Int {
        if takingStatements {
            moreStatements = true
            return 0
        }
        takingStatements = true
        defer { takingStatements = false }
        var loaded: [String] = []
        repeat {
            moreStatements = false
            guard let more = await takeInStatementsOnce(today: today) else { break }
            loaded += more
        } while moreStatements
        if !loaded.isEmpty {
            let ids = loaded
            let message = ids.count == 1 ? "Выписка загружена" : "Загружено выписок: \(ids.count)"
            UndoCenter.shared.show(message) { [weak self] in
                guard let self else { return }
                var next = self.state
                for id in ids { next = (try? StatementImport.deleteImport(id, from: next)) ?? next }
                try? self.replaceState(with: next, today: today)
            }
        }
        return loaded.count
    }

    private var statementsReady: Bool {
        let ready = storage == .cloud ? collection?.hasSynced == true : owner == .device
        return owner != .none && !isUnavailable && ready
    }

    /// One pass over the inbox: the ids of the statements loaded, or nil when money cannot take them now.
    private func takeInStatementsOnce(today: String) async -> [String]? {
        guard statementsReady else { return nil }
        let files = bankStatementInbox.pending()
        guard !files.isEmpty else { return [] }
        let rules = state.merchantCategories
        let startedFor = owner
        let read: [SharedStatement] = await Task.detached(priority: .userInitiated) {
            files.map { url -> SharedStatement in
                let importId = "imp-" + String(UUID().uuidString.prefix(8)).lowercased()
                do {
                    let statement = try BankStatementParser.parse(try BankStatementParser.text(ofPDFAt: url))
                    let preview = StatementImport.preview(statement, importId: importId, rules: rules)
                    return SharedStatement(url: url, importId: importId, outcome: .success(preview))
                } catch {
                    return SharedStatement(url: url, importId: importId, outcome: .failure(error))
                }
            }
        }.value
        // The account may have changed while the files were read: they wait for the next look.
        guard owner == startedFor, statementsReady else { return nil }
        var loaded: [String] = []
        for item in read {
            switch item.outcome {
            case .success(let preview):
                let next: FinanceState
                do {
                    next = try StatementImport.apply(preview, to: state, importId: item.importId,
                                                     fileName: BankStatementInbox.originalName(item.url), today: today)
                } catch StatementError.alreadyImported {
                    // Shared twice: nothing new, nothing to say.
                    bankStatementInbox.remove(item.url)
                    continue
                } catch {
                    // It never fits (too many records, say): say why and let the next statement through.
                    sharedStatementProblem = error.localizedDescription
                    bankStatementInbox.remove(item.url)
                    continue
                }
                do {
                    try updateState(next, today: today)
                } catch {
                    // Money could not be saved now: the statement waits for the next time.
                    return loaded
                }
                loaded.append(item.importId)
                sharedStatementProblem = nil
            case .failure(let error):
                sharedStatementProblem = error.localizedDescription
            }
            bankStatementInbox.remove(item.url)
        }
        return loaded
    }

    /// Steps of the move: upload (idempotent), wait for the server, compare, and only then delete the file.
    func moveToCollectionIfNeeded() async {
        guard let collection, collection.isAvailable, storage == .local, owner != .none else { return }
        reloadIfUnavailable()
        if isUnavailable { return }
        let hasLocal = fileManager.fileExists(atPath: storageURL.path) && !isEmpty(state)
        if !hasLocal {
            if fileManager.fileExists(atPath: storageURL.path) { keepPreSyncBackup(); try? fileManager.removeItem(at: storageURL) }
            storage = .cloud
            collectionChanged()
            return
        }
        storage = .migrating
        // Edits made while the upload runs are saved to the phone's file as usual (the owner keeps working);
        // each round uploads what changed since the previous one, and the file goes only when nothing is left.
        var local = state
        let stamp = Int64(Date().timeIntervalSince1970 * 1000)
        _ = collection.importMany(FinanceCloud.entries(local, updatedAt: stamp))
        var rounds = 0
        while true {
            let synced = await collection.whenSynced()
            // Signed out or another account meanwhile: `detach` already put the store back on the phone's file.
            guard self.collection === collection, storage == .migrating else { return }
            guard synced else {
                storage = .local
                if case .offline = collection.syncState {
                    notice = "Финансы пока не выгружены в облако: нет связи. Данные сохранены на телефоне, выгрузка повторится позже."
                } else {
                    notice = "Выгрузка финансов в облако не завершилась (осталось записей: \(collection.pendingCount)). Данные на телефоне, выгрузка продолжится при следующем открытии."
                }
                return
            }
            if state == local { break }
            rounds += 1
            guard rounds < 4 else {
                storage = .local
                notice = nil
                return
            }
            local = state
            do { try writeToCollection(local, collection) } catch {
                storage = .local
                return
            }
        }
        let remote = FinanceCloud.state(from: collection.items)
        guard FinanceCloud.isVerified(local: local, remote: remote) else {
            storage = .local
            notice = "Не удалось сверить финансы с облаком. Данные остаются на телефоне, ничего не удалено."
            return
        }
        // Decision 4 (docs/ONE-APP-PLAN.md): the phone keeps a copy of the file it moved; only then is it removed.
        guard keepPreSyncBackup() else {
            storage = .local
            notice = "Не удалось сохранить резервную копию финансов. Данные остаются на телефоне, ничего не удалено."
            return
        }
        try? fileManager.removeItem(at: storageURL)
        storage = .cloud
        notice = nil
        collectionChanged()
    }

    /// The file as it was before the move, next to it: `finance_state.pre-sync-backup.json`. Never overwritten: a later
    /// move (after signing out and back in) keeps its own copy with a time stamp in the name.
    var preSyncBackupURL: URL { storageURL.deletingLastPathComponent().appendingPathComponent("finance_state.pre-sync-backup.json") }

    @discardableResult
    private func keepPreSyncBackup() -> Bool {
        var backup = preSyncBackupURL
        if fileManager.fileExists(atPath: backup.path) {
            let stamp = Int64(Date().timeIntervalSince1970 * 1000)
            backup = backup.deletingLastPathComponent().appendingPathComponent("finance_state.pre-sync-backup-\(stamp).json")
        }
        do { try fileManager.copyItem(at: storageURL, to: backup); return true } catch { return false }
    }

    private func isEmpty(_ s: FinanceState) -> Bool {
        s.records.isEmpty && (s.imports ?? []).isEmpty && s.budget == nil && (s.merchantCategories ?? [:]).isEmpty && s.ledger == nil
    }

    /// Writes the difference between the collection and `next`.
    private func writeToCollection(_ next: FinanceState, _ collection: VaultCollection<FinancePayload>) throws {
        let plan = FinanceCloud.plan(existing: FinanceCloud.existing(collection.items), state: next)
        try collection.batch {
            for entry in plan.puts {
                guard collection.put(entry.id, entry.data) != nil else {
                    throw FinanceError.invalidState("Не удалось сохранить в облачное хранилище.")
                }
            }
            for id in plan.removes { _ = collection.remove(id) }
        }
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

    /// «Очистить финансы»: only envelopes and category rules stay; waiting payments and statements go too.
    public func clearFinances(today: String) throws {
        try updateState(try FinanceLedger.cleared(state), today: today)
        discardBankFeed()
    }

    public func reset() {
        if storage == .cloud, let collection, collection.isAvailable {
            try? writeToCollection(emptyFinance(), collection)
        }
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
        // While the move runs, edits go to the phone's file below; the move uploads them before removing it.
        if storage == .cloud, let collection, collection.isAvailable {
            let clean = try validateFinance(newState)
            try writeToCollection(clean, collection)
            self.state = clean
            refreshSummary(today: today)
            self.notice = nil
            return
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
        if isUnavailable && owner != .none {
            loadInitialState()
            if collection != nil { Task { await self.moveToCollectionIfNeeded() } }
        }
    }

    /// The app is back in front: a move that stopped for lack of a connection tries again.
    public func retryMoveIfNeeded() {
        guard collection != nil, storage == .local, !isUnavailable else { return }
        Task { await self.moveToCollectionIfNeeded() }
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
            self.state = FinanceLedger.upkeep(clean) ?? clean
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

#if DEBUG
extension FinanceStore {
    /// Debug screenshots only (`--screenshot-demo-data`): made-up money in memory. The owner becomes .none,
    /// so every save path refuses and nothing reaches the disk, the vault or the cloud.
    func showScreenshotDemo(_ demo: FinanceState, today: String) {
        owner = .none
        state = demo
        refreshSummary(today: today)
    }
}
#endif

/// A statement shared to A-san, read off the main thread (FinanceStore.takeInStatements).
private struct SharedStatement {
    let url: URL
    let importId: String
    let outcome: Result<StatementImport.Preview, Error>
}
