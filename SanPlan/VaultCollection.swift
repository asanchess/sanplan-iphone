import Foundation
import CryptoKit

/// One record of an encrypted collection. `data` is the domain's own Codable payload.
public struct VaultItem<Payload: Codable & Equatable & Sendable>: Equatable, Sendable {
    public var id: String
    public var updatedAt: Int64
    public var deleted: Bool
    public var data: Payload?

    public init(id: String, updatedAt: Int64, deleted: Bool = false, data: Payload?) {
        self.id = id
        self.updatedAt = updatedAt
        self.deleted = deleted
        self.data = data
    }
}

/// What a device keeps when the server already has another revision of a record.
public enum VaultConflictPolicy: Sendable {
    /// The later edit wins; ties go to the server. Right for structured records (money, sets, habits).
    case newest
    /// The server's version stays; a differing local edit survives as a new record. Right for free text.
    case copy
}

/// One encrypted collection for any domain (finance, training, habits, goals, reviews) — the same record format
/// as the web (`src/vault-collection.mjs`, docs/personal-hub/E2E-SYNC.md): `{v:1, updatedAt, deleted?, data}`
/// sealed with AAD `ARNA|<collection>|<id>|v1`. On disk only ciphertext is kept, in the account's hashed folder.
@MainActor
public final class VaultCollection<Payload: Codable & Equatable & Sendable>: ObservableObject {
    public enum SyncState: Equatable {
        case idle
        case syncing
        case offline(String)
    }

    struct CacheEntry: Codable, Equatable {
        var revision: Int
        var c: String
        var dirty: Bool
    }

    private struct Record: Codable {
        var v: Int
        var updatedAt: Int64
        var deleted: Bool?
        var data: Payload?
    }

    /// The server's id rule (cloud/vault.mjs). Migrations derive ids from local ones, e.g. "t-<localId>".
    public static func isValidID(_ id: String) -> Bool {
        (8...64).contains(id.count) && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }

    public let collection: String
    public let policy: VaultConflictPolicy
    private let idPrefix: String

    @Published public private(set) var all: [String: VaultItem<Payload>] = [:]
    @Published public private(set) var syncState: SyncState = .idle
    @Published public private(set) var unreadableCount = 0

    private var cache: [String: CacheEntry] = [:]
    private var key: SymmetricKey?
    private var transport: (any VaultTransport)?
    private var fileURL: URL?
    private var syncTask: Task<Void, Never>?
    private var isSyncing = false
    private var syncAgain = false
    private var generation = 0
    private var waiters: [CheckedContinuation<Bool, Never>] = []
    private let fileManager: FileManager
    private let baseDirectory: URL
    private let now: () -> Int64
    public var onUnauthorized: (() -> Void)?
    public var syncDelay: Duration = .milliseconds(1200)
    public var offlineMessage = "Нет связи. Данные сохранены на телефоне и уйдут позже."
    public var unauthorizedMessage = "Войдите снова, чтобы данные синхронизировались."

    public init(collection: String, policy: VaultConflictPolicy = .newest, idPrefix: String = "r",
                fileManager: FileManager = .default, baseDirectory: URL? = nil,
                now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.collection = collection
        self.policy = policy
        self.idPrefix = idPrefix
        self.fileManager = fileManager
        self.baseDirectory = baseDirectory ?? (fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())).appendingPathComponent("ARNA", isDirectory: true)
        self.now = now
    }

    /// Random id: prefix + 20 characters of a-z0-9 (as on the web).
    public func newID() -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        return idPrefix + String((0..<20).map { _ in alphabet[Int.random(in: 0..<alphabet.count)] })
    }

    // MARK: Reading

    public var isAvailable: Bool { key != nil }
    /// Records not deleted, newest first.
    public var items: [VaultItem<Payload>] {
        all.values.filter { !$0.deleted }.sorted { $0.updatedAt != $1.updatedAt ? $0.updatedAt > $1.updatedAt : $0.id < $1.id }
    }
    public func item(_ id: String) -> VaultItem<Payload>? { all[id].flatMap { $0.deleted ? nil : $0 } }
    /// Local edits not yet confirmed by the server.
    public var pendingCount: Int { cache.values.filter(\.dirty).count }

    // MARK: Account

    public func attach(account: String, key: SymmetricKey, transport: (any VaultTransport)?) {
        detach()
        self.key = key
        self.transport = transport
        let folder = baseDirectory.appendingPathComponent(FinanceStore.accountFolderName(account), isDirectory: true)
        try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        fileURL = folder.appendingPathComponent("\(collection)_vault.json")
        loadCache()
        scheduleSync(after: .zero)
    }

    /// Signed out: nothing of the previous account stays in memory. The encrypted file stays for its next sign-in.
    public func detach() {
        generation += 1
        syncTask?.cancel()
        syncTask = nil
        key = nil
        transport = nil
        fileURL = nil
        cache = [:]
        all = [:]
        unreadableCount = 0
        syncState = .idle
        isSyncing = false
        syncAgain = false
        let pending = waiters
        waiters = []
        pending.forEach { $0.resume(returning: false) }
    }

    // MARK: Editing

    /// Creates or replaces a record. Returns its id, or nil when locked or the id is invalid.
    @discardableResult
    public func put(_ id: String? = nil, _ data: Payload, updatedAt: Int64? = nil) -> String? {
        guard key != nil else { return nil }
        let id = id ?? newID()
        guard Self.isValidID(id) else { assertionFailure("Bad record id \(id)"); return nil }
        let old = all[id]
        if let old, !old.deleted, old.data == data { return id }
        let time = max(updatedAt ?? now(), (old?.updatedAt ?? -1) + 1)
        return write(VaultItem(id: id, updatedAt: time, deleted: false, data: data)) ? id : nil
    }

    /// Tombstone: other devices learn about the deletion. Returns the removed record for undo.
    @discardableResult
    public func remove(_ id: String) -> VaultItem<Payload>? {
        guard var old = item(id) else { return nil }
        let removed = old
        old.deleted = true
        old.updatedAt = max(now(), old.updatedAt + 1)
        return write(old) ? removed : nil
    }

    /// Brings back a removed record (undo).
    @discardableResult
    public func restore(_ item: VaultItem<Payload>) -> Bool {
        guard let current = all[item.id], current.deleted else { return false }
        var back = item
        back.deleted = false
        back.updatedAt = max(now(), current.updatedAt + 1)
        return write(back)
    }

    /// Migration import: idempotent by id; a record already present with the same data is skipped.
    public func importMany(_ entries: [(id: String, data: Payload, updatedAt: Int64)]) -> (written: Int, skipped: Int) {
        var written = 0, skipped = 0
        for entry in entries {
            if let old = all[entry.id], !old.deleted, old.data == entry.data { skipped += 1; continue }
            if put(entry.id, entry.data, updatedAt: entry.updatedAt) != nil { written += 1 }
        }
        return (written, skipped)
    }

    /// True once every local edit is on the server; false if the account changes first.
    /// Local copies of migrated data may be deleted only after this returns true.
    public func whenSynced() async -> Bool {
        guard key != nil else { return false }
        if pendingCount == 0 { return true }
        scheduleSync(after: .zero)
        return await withCheckedContinuation { waiters.append($0) }
    }

    private func write(_ item: VaultItem<Payload>) -> Bool {
        guard let key, let sealed = try? seal(item, key: key) else { return false }
        all[item.id] = item
        cache[item.id] = CacheEntry(revision: cache[item.id]?.revision ?? 0, c: sealed, dirty: true)
        saveCache()
        scheduleSync(after: syncDelay)
        return true
    }

    // MARK: Sync

    public func syncNow() { scheduleSync(after: .zero) }

    private func scheduleSync(after delay: Duration) {
        guard transport != nil else { return }
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            await self?.sync()
        }
    }

    public func sync() async {
        guard let key, let transport else { return }
        if isSyncing { syncAgain = true; return }
        let started = generation
        isSyncing = true
        syncState = .syncing
        defer { if generation == started { isSyncing = false } }
        do {
            repeat {
                syncAgain = false
                try await push(key: key, transport: transport, generation: started)
                try await pull(key: key, transport: transport, generation: started)
            } while syncAgain && generation == started
            guard generation == started else { return }
            syncState = .idle
            if pendingCount == 0 {
                let done = waiters
                waiters = []
                done.forEach { $0.resume(returning: true) }
            }
        } catch APIError.unauthorized {
            guard generation == started else { return }
            syncState = .offline(unauthorizedMessage)
            onUnauthorized?()
        } catch {
            guard generation == started else { return }
            syncState = .offline(offlineMessage)
        }
    }

    private func push(key: SymmetricKey, transport: any VaultTransport, generation started: Int) async throws {
        for (id, entry) in cache where entry.dirty {
            let result = try await transport.put(collection, record: VaultRemoteRecord(id: id, revision: entry.revision, c: entry.c))
            guard generation == started else { return }
            guard var latest = cache[id] else { continue }
            switch result {
            case .saved(let revision):
                latest.revision = revision
                if latest.c == entry.c { latest.dirty = false } else { syncAgain = true }
                cache[id] = latest
            case .conflict(let current):
                resolveConflict(id: id, current: current, key: key)
            }
            saveCache()
        }
    }

    private func resolveConflict(id: String, current: VaultRemoteRecord?, key: SymmetricKey) {
        let local = all[id]
        var remote: VaultItem<Payload>?
        var readable = true
        if let current {
            do { remote = try open(id: id, c: current.c, key: key) } catch { readable = false }
        }
        let keepLocal: Bool
        var copyLocal = false
        switch policy {
        case .newest:
            keepLocal = readable && local != nil && (remote == nil || local!.updatedAt > remote!.updatedAt)
        case .copy:
            keepLocal = readable && local != nil && current == nil
            if readable, let local, !local.deleted, let remote, remote.deleted || remote.data != local.data { copyLocal = true }
        }
        if keepLocal {
            // Re-send this device's version on top of the server's revision.
            cache[id]?.revision = current?.revision ?? 0
            cache[id]?.dirty = true
            syncAgain = true
        } else {
            if let current { cache[id] = CacheEntry(revision: current.revision, c: current.c, dirty: false) } else { cache[id] = nil }
            if let remote { all[id] = remote } else { all[id] = nil; if !readable { unreadableCount += 1 } }
        }
        if copyLocal, let local {
            let copy = VaultItem(id: newID(), updatedAt: max(now(), local.updatedAt), deleted: false, data: local.data)
            if let sealed = try? seal(copy, key: key) {
                all[copy.id] = copy
                cache[copy.id] = CacheEntry(revision: 0, c: sealed, dirty: true)
                syncAgain = true
            }
        }
    }

    private func pull(key: SymmetricKey, transport: any VaultTransport, generation started: Int) async throws {
        let remote = try await transport.list(collection)
        guard generation == started else { return }
        var unreadable = 0
        for record in remote {
            if let local = cache[record.id], local.dirty || local.revision >= record.revision { continue }
            guard let item = try? open(id: record.id, c: record.c, key: key) else { unreadable += 1; continue }
            cache[record.id] = CacheEntry(revision: record.revision, c: record.c, dirty: false)
            all[record.id] = item
        }
        unreadableCount = unreadable
        saveCache()
    }

    // MARK: Encryption and disk

    private func seal(_ item: VaultItem<Payload>, key: SymmetricKey) throws -> String {
        let record = Record(v: 1, updatedAt: item.updatedAt, deleted: item.deleted ? true : nil, data: item.data)
        return try VaultCrypto.seal(JSONEncoder().encode(record), key: key, collection: collection, id: item.id)
    }

    private func open(id: String, c: String, key: SymmetricKey) throws -> VaultItem<Payload> {
        let plain = try VaultCrypto.open(c, key: key, collection: collection, id: id)
        let record = try JSONDecoder().decode(Record.self, from: plain)
        guard record.v == 1 else { throw VaultCrypto.Failure.unknownFormat }
        return VaultItem(id: id, updatedAt: record.updatedAt, deleted: record.deleted ?? false, data: record.data)
    }

    private func loadCache() {
        guard let fileURL, let key else { return }
        guard let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode([String: CacheEntry].self, from: data) else { return }
        cache = stored
        var items: [String: VaultItem<Payload>] = [:]
        for (id, entry) in stored {
            if let item = try? open(id: id, c: entry.c, key: key) { items[id] = item }
        }
        all = items
    }

    private func saveCache() {
        guard let fileURL, let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
