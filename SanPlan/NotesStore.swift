import Foundation
import CryptoKit

/// Notes of the signed-in account. On disk only ciphertext is kept (the same records the server holds);
/// plaintext lives in memory. Edits save instantly on the phone and sync in the background (E2E-SYNC.md).
@MainActor
public final class NotesStore: ObservableObject {
    public static let collection = "notes"

    public enum SyncState: Equatable {
        case idle
        case syncing
        /// The last sync failed; the text stays saved on the phone and goes up on the next try.
        case offline(String)
    }

    struct CacheEntry: Codable, Equatable {
        var revision: Int
        var c: String
        var dirty: Bool
    }

    /// Every note including tombstones, by id.
    @Published private(set) var all: [String: Note] = [:]
    @Published public private(set) var syncState: SyncState = .idle
    /// The last deleted note, for «Отменить».
    @Published public private(set) var recentlyDeleted: Note?
    /// Records that did not decrypt with this key (left untouched).
    @Published public private(set) var unreadableCount = 0

    private var cache: [String: CacheEntry] = [:]
    private var key: SymmetricKey?
    private var transport: (any VaultTransport)?
    private var fileURL: URL?
    private var syncTask: Task<Void, Never>?
    private var isSyncing = false
    private var syncAgain = false
    /// Bumped on every account change, so a sync started for one account never writes into another.
    private var generation = 0
    private let fileManager: FileManager
    private let baseDirectory: URL
    private let now: () -> Int64
    public var onUnauthorized: (() -> Void)?
    /// Debounce before an edit goes to the server.
    public var syncDelay: Duration = .milliseconds(1200)

    public init(fileManager: FileManager = .default, baseDirectory: URL? = nil, now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.fileManager = fileManager
        self.baseDirectory = baseDirectory ?? (fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())).appendingPathComponent("ARNA", isDirectory: true)
        self.now = now
    }

    /// Visible notes: pinned first, then the most recently edited.
    public var notes: [Note] {
        all.values.filter { !$0.deleted }.sorted {
            $0.pinned != $1.pinned ? $0.pinned : ($0.updatedAt != $1.updatedAt ? $0.updatedAt > $1.updatedAt : $0.id < $1.id)
        }
    }

    public func note(_ id: String) -> Note? {
        all[id].flatMap { $0.deleted ? nil : $0 }
    }

    public var isAvailable: Bool { key != nil }

    // MARK: Account

    /// Opens this account's notes with its data key. `account` names the folder (hashed, like money).
    public func attach(account: String, key: SymmetricKey, transport: (any VaultTransport)?) {
        detach()
        self.key = key
        self.transport = transport
        let folder = baseDirectory.appendingPathComponent(FinanceStore.accountFolderName(account), isDirectory: true)
        try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        fileURL = folder.appendingPathComponent("notes_vault.json")
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
        recentlyDeleted = nil
        unreadableCount = 0
        syncState = .idle
        isSyncing = false
        syncAgain = false
    }

    // MARK: Editing

    @discardableResult
    public func create(text: String, pinned: Bool = false) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, key != nil else { return nil }
        let note = Note(text: trimmed, pinned: pinned, createdAt: now())
        store(note)
        return note.id
    }

    /// Saves edited text. Emptied text deletes the note.
    public func update(_ id: String, text: String) {
        guard var note = note(id), note.text != text else { return }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            delete(id)
            return
        }
        note.text = text
        note.updatedAt = max(now(), note.updatedAt + 1)
        store(note)
    }

    public func togglePin(_ id: String) {
        guard var note = note(id) else { return }
        note.pinned.toggle()
        note.updatedAt = max(now(), note.updatedAt + 1)
        store(note)
    }

    public func toggleChecklist(_ id: String, line: Int) {
        guard let note = note(id) else { return }
        update(id, text: NoteText.toggle(note.text, line: line))
    }

    public func delete(_ id: String) {
        guard var note = note(id) else { return }
        recentlyDeleted = note
        note.deleted = true
        note.updatedAt = max(now(), note.updatedAt + 1)
        store(note)
    }

    public func undoDelete() {
        guard var note = recentlyDeleted, all[note.id]?.deleted == true else { recentlyDeleted = nil; return }
        recentlyDeleted = nil
        note.deleted = false
        note.updatedAt = max(now(), (all[note.id]?.updatedAt ?? 0) + 1)
        store(note)
    }

    public func dismissUndo() { recentlyDeleted = nil }

    private func store(_ note: Note) {
        guard let key, let sealed = try? seal(note, key: key) else { return }
        all[note.id] = note
        cache[note.id] = CacheEntry(revision: cache[note.id]?.revision ?? 0, c: sealed, dirty: true)
        saveCache()
        scheduleSync(after: syncDelay)
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

    /// Sends local edits, then takes the server's newer records. Safe to call repeatedly.
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
        } catch APIError.unauthorized {
            guard generation == started else { return }
            syncState = .offline("Войдите снова, чтобы заметки синхронизировались.")
            onUnauthorized?()
        } catch {
            guard generation == started else { return }
            syncState = .offline("Нет связи. Заметки сохранены на телефоне и уйдут позже.")
        }
    }

    private func push(key: SymmetricKey, transport: any VaultTransport, generation started: Int) async throws {
        for (id, entry) in cache where entry.dirty {
            let result = try await transport.put(Self.collection, record: VaultRemoteRecord(id: id, revision: entry.revision, c: entry.c))
            guard generation == started else { return }
            guard var latest = cache[id] else { continue }
            switch result {
            case .saved(let revision):
                latest.revision = revision
                // Edited again while uploading: keep it dirty for the next round.
                if latest.c == entry.c { latest.dirty = false } else { syncAgain = true }
                cache[id] = latest
            case .conflict(let current):
                resolveConflict(id: id, local: all[id], current: current, key: key)
            }
            saveCache()
        }
    }

    /// The server's version wins under its id; a local edit with different text survives as a separate note.
    private func resolveConflict(id: String, local: Note?, current: VaultRemoteRecord?, key: SymmetricKey) {
        guard let current else {
            // Gone from the server: upload ours again as new.
            cache[id]?.revision = 0
            syncAgain = true
            return
        }
        let remote = try? open(current, key: key)
        cache[id] = CacheEntry(revision: current.revision, c: current.c, dirty: false)
        if let remote { all[id] = remote } else { all[id] = nil; unreadableCount += 1 }
        if let local, !local.deleted, remote == nil || remote!.deleted || remote!.text != local.text {
            var copy = Note(text: local.text, pinned: local.pinned, createdAt: local.createdAt, updatedAt: max(now(), local.updatedAt))
            copy.id = Note.newID()
            if let sealed = try? seal(copy, key: key) {
                all[copy.id] = copy
                cache[copy.id] = CacheEntry(revision: 0, c: sealed, dirty: true)
                syncAgain = true
            }
        }
    }

    private func pull(key: SymmetricKey, transport: any VaultTransport, generation started: Int) async throws {
        let remote = try await transport.list(Self.collection)
        guard generation == started else { return }
        var unreadable = 0
        for record in remote {
            let local = cache[record.id]
            if let local, local.dirty || local.revision >= record.revision { continue }
            guard let note = try? open(record, key: key) else { unreadable += 1; continue }
            cache[record.id] = CacheEntry(revision: record.revision, c: record.c, dirty: false)
            all[record.id] = note
        }
        unreadableCount = unreadable
        saveCache()
    }

    // MARK: Encryption and disk

    private func seal(_ note: Note, key: SymmetricKey) throws -> String {
        try VaultCrypto.seal(JSONEncoder().encode(NoteRecord(note)), key: key, collection: Self.collection, id: note.id)
    }

    private func open(_ record: VaultRemoteRecord, key: SymmetricKey) throws -> Note {
        try open(id: record.id, c: record.c, key: key)
    }

    private func open(id: String, c: String, key: SymmetricKey) throws -> Note {
        let plain = try VaultCrypto.open(c, key: key, collection: Self.collection, id: id)
        let record = try JSONDecoder().decode(NoteRecord.self, from: plain)
        guard record.v == 1 else { throw VaultCrypto.Failure.unknownFormat }
        return record.note(id: id)
    }

    private func loadCache() {
        guard let fileURL, let key else { return }
        guard let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode([String: CacheEntry].self, from: data) else { return }
        cache = stored
        var notes: [String: Note] = [:]
        for (id, entry) in stored {
            if let note = try? open(id: id, c: entry.c, key: key) { notes[id] = note }
        }
        all = notes
    }

    private func saveCache() {
        guard let fileURL, let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
