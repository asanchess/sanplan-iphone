import XCTest
import CryptoKit
@testable import SanPlan

/// Values from native/reference/e2e-fixture.json, sealed by src/vault-crypto.mjs (invented data).
private enum Fixture {
    static let recoveryKey = "QPS7-0XHT-Q60N-A46V-B5H4-02QM-B8XA-N24T"
    static let dataKey = "kT+mbrsKvcl4oneEDmvMt1WMrBzwHm69tfRUWhi/Zfk="
    static let envelope = VaultCrypto.Envelope(v: 1, salt: "S7YelK4H2LCftyqI8sahlQ==", wrapped: "MiJc6mxjA+/sx7WmwAVXWnefNga9sSXxd87uxc6KSKtBQ8XskE/4Tq2VB9Nx4fRXWAoL9iq7Z93jjINP")
    static let id = "fixture-note-0001"
    static let c = "lrDHZmLmJvW3Yi9hk//9yE1kjIJT42fdwXZ6fax/S94Yt0A2kHnVWepruEIXKCdHj0U9/yfWG3RIET76fLYmjo0t22sH6AzPggj+RYzNTtP++4I8AmmwJ35Ruzi/heX69VOU23plFbbi1VnFBODRmZUTCiHKe44AVxuirl3dgra7aHLCdhAz7DmkQdmcuM9hs1gYsguWPzgsPiWgFBd8TES274jN"
}

/// The server's half in memory, with the same revision rules as cloud/vault.mjs: a server-held key per account
/// (`GET /api/vault/key`, adopt), `seq` numbers and one counter per collection (`stamps`, `?since=`).
final class MemoryVaultTransport: VaultTransport, @unchecked Sendable {
    private let lock = NSLock()
    /// The account's data key; nil with an `envelope` is an account from before server keys (needsAdopt).
    var serverKey: Data?
    var envelope: VaultCrypto.Envelope?
    var records: [String: VaultRemoteRecord] = [:]
    var failNext = false
    var failKeyFetch = false
    private(set) var keyFetches = 0
    private(set) var adoptions = 0
    /// The `since` of every list call, in order.
    private(set) var listedSince: [Int?] = []
    private(set) var counters: [String: Int] = [:]
    private var counter = 0

    func fetchAccountKey() async throws -> VaultAccountKey {
        try lock.withLock {
            keyFetches += 1
            if failKeyFetch { throw APIError.transport("offline") }
            if serverKey == nil && envelope == nil { serverKey = VaultCrypto.randomBytes(32) }
            return VaultAccountKey(key: serverKey, needsAdopt: serverKey == nil && envelope != nil, envelope: envelope, revision: envelope == nil ? 0 : 1)
        }
    }

    func adoptKey(_ key: Data) async throws -> VaultAdoptResult {
        lock.withLock {
            adoptions += 1
            if let serverKey { return serverKey == key ? .saved(key) : .conflict(serverKey) }
            serverKey = key
            return .saved(key)
        }
    }

    func stamps() async throws -> [String: Int] {
        try lock.withLock {
            if failNext { failNext = false; throw APIError.transport("offline") }
            return counters
        }
    }

    func list(_ collection: String, since: Int?) async throws -> VaultListing {
        try lock.withLock {
            if failNext { failNext = false; throw APIError.transport("offline") }
            listedSince.append(since)
            let all = Array(records.values)
            let page = since.map { floor in all.filter { ($0.seq ?? 0) > floor } } ?? all
            return VaultListing(records: page, stamp: counters[collection] ?? 0)
        }
    }

    func put(_ collection: String, record: VaultRemoteRecord) async throws -> VaultPutResult {
        try lock.withLock {
            if failNext { failNext = false; throw APIError.transport("offline") }
            let current = records[record.id]
            guard (current?.revision ?? 0) == record.revision else { return .conflict(current: current) }
            counter += 1
            counters[collection] = counter
            records[record.id] = VaultRemoteRecord(id: record.id, revision: record.revision + 1, c: record.c, seq: counter)
            return .saved(revision: record.revision + 1)
        }
    }

    /// A write that moved the counter but never produced a record (it lost its conflict on the server).
    func bumpCounterWithoutRecord(_ collection: String) {
        lock.withLock {
            counter += 1
            counters[collection] = counter
        }
    }
}

final class VaultCryptoTests: XCTestCase {
    func testOpensWhatTheWebSealed() throws {
        let key = try VaultCrypto.unwrap(Fixture.envelope, recoveryText: Fixture.recoveryKey)
        XCTAssertEqual(key.withUnsafeBytes { Data($0) }.base64EncodedString(), Fixture.dataKey)
        let plain = try VaultCrypto.open(Fixture.c, key: key, collection: "notes", id: Fixture.id)
        let note = try JSONDecoder().decode(NoteRecord.self, from: plain).note(id: Fixture.id)
        XCTAssertEqual(note.text, "Пример заметки\n- [ ] пункт")
        XCTAssertTrue(note.pinned)
        XCTAssertEqual(note.updatedAt, 1762934400000)
        XCTAssertEqual(note.createdAt, 1762930800000)
    }

    func testWrapReproducesTheWebEnvelope() throws {
        let key = SymmetricKey(data: Data(base64Encoded: Fixture.dataKey)!)
        let wrapped = Data(base64Encoded: Fixture.envelope.wrapped)!
        let again = try VaultCrypto.wrap(key, recovery: VaultCrypto.parseRecoveryKey(Fixture.recoveryKey),
                                         salt: Data(base64Encoded: Fixture.envelope.salt)!,
                                         nonce: AES.GCM.Nonce(data: wrapped.prefix(12)))
        XCTAssertEqual(again, Fixture.envelope)
    }

    func testRecoveryKeyFormatAndTolerantInput() throws {
        let bytes = Data((0..<20).map { UInt8(($0 * 13) & 255) })
        let text = VaultCrypto.formatRecoveryKey(bytes)
        XCTAssertEqual(text.count, 39)
        XCTAssertEqual(try VaultCrypto.parseRecoveryKey(text), bytes)
        XCTAssertEqual(try VaultCrypto.parseRecoveryKey(text.lowercased().replacingOccurrences(of: "-", with: " ")), bytes)
        XCTAssertThrowsError(try VaultCrypto.parseRecoveryKey("ABC"))
        XCTAssertThrowsError(try VaultCrypto.parseRecoveryKey(String(repeating: "U", count: 32)))
    }

    func testWrongRecoveryKeyAndSwappedRecordFail() throws {
        let made = try VaultCrypto.createKey()
        XCTAssertThrowsError(try VaultCrypto.unwrap(made.envelope, recoveryText: try VaultCrypto.createKey().recoveryKey))
        let c = try VaultCrypto.seal(Data("x".utf8), key: made.dataKey, collection: "notes", id: "note-aaaa")
        XCTAssertThrowsError(try VaultCrypto.open(c, key: made.dataKey, collection: "notes", id: "note-bbbb"))
        XCTAssertEqual(try VaultCrypto.open(c, key: made.dataKey, collection: "notes", id: "note-aaaa"), Data("x".utf8))
    }
}

@MainActor
final class VaultKeySessionTests: XCTestCase {
    private func raw(_ key: SymmetricKey?) -> Data? { key?.withUnsafeBytes { Data($0) } }

    /// A new account gets its key from the server on the first call: no screen, nothing to save.
    func testNewAccountGetsTheServerKeyWithoutAskingAnything() async {
        let server = MemoryVaultTransport(), storage = MemoryVaultKeyStorage()
        let session = VaultKeySession(storage: storage)
        var ready = 0
        session.onReady = { ready += 1 }
        session.attach(account: "a@example.com", transport: server)
        XCTAssertEqual(session.phase, .idle)
        await session.check()
        XCTAssertEqual(session.phase, .ready)
        XCTAssertEqual(raw(session.dataKey), server.serverKey)
        XCTAssertEqual(raw(storage.load(account: "a@example.com")), server.serverKey, "The key is cached in the Keychain for offline starts")
        XCTAssertEqual(ready, 1)
        XCTAssertEqual(session.keyVersion, 1)
    }

    func testSecondDeviceOpensBySigningIn() async {
        let server = MemoryVaultTransport()
        let first = VaultKeySession(storage: MemoryVaultKeyStorage()), second = VaultKeySession(storage: MemoryVaultKeyStorage())
        first.attach(account: "a@example.com", transport: server)
        second.attach(account: "a@example.com", transport: server)
        await first.check()
        await second.check()
        XCTAssertEqual(second.phase, .ready)
        XCTAssertEqual(raw(second.dataKey), raw(first.dataKey))
    }

    func testCachedKeyKeepsTheAppOpenOffline() async {
        let server = MemoryVaultTransport(), storage = MemoryVaultKeyStorage()
        let cached = SymmetricKey(size: .bits256)
        try? storage.save(cached, account: "a@example.com")
        server.failKeyFetch = true
        let session = VaultKeySession(storage: storage)
        session.attach(account: "a@example.com", transport: server)
        XCTAssertEqual(session.phase, .ready, "A cached key opens at once, before the server answers")
        await session.check()
        XCTAssertEqual(session.phase, .ready)
        XCTAssertEqual(raw(session.dataKey), raw(cached))
    }

    func testNoKeyAndNoServerIsAnErrorNotAScreen() async {
        let server = MemoryVaultTransport()
        server.failKeyFetch = true
        let session = VaultKeySession(storage: MemoryVaultKeyStorage())
        session.attach(account: "a@example.com", transport: server)
        await session.check()
        guard case .failed(let message) = session.phase else { return XCTFail("Expected failed, got \(session.phase)") }
        XCTAssertFalse(message.isEmpty)
        XCTAssertNil(session.dataKey)
    }

    /// The server's key wins: the cached one is replaced, stores are told, the Keychain follows.
    func testServerKeyReplacesADifferentCachedKey() async {
        let server = MemoryVaultTransport(), storage = MemoryVaultKeyStorage()
        server.serverKey = VaultCrypto.randomBytes(32)
        try? storage.save(SymmetricKey(size: .bits256), account: "a@example.com")
        let session = VaultKeySession(storage: storage)
        var ready = 0
        session.onReady = { ready += 1 }
        session.attach(account: "a@example.com", transport: server)
        XCTAssertEqual(ready, 1)
        let before = session.keyVersion
        await session.check()
        XCTAssertEqual(raw(session.dataKey), server.serverKey)
        XCTAssertEqual(raw(storage.load(account: "a@example.com")), server.serverKey)
        XCTAssertEqual(session.keyVersion, before + 1)
        XCTAssertEqual(ready, 2, "Stores reopen under the new key")
        await session.check()
        XCTAssertEqual(ready, 2, "The same key again changes nothing")
    }

    /// An account from before server keys, on a device that still has the key: handed over silently.
    func testOlderAccountWithACachedKeyAdoptsSilently() async throws {
        let server = MemoryVaultTransport(), storage = MemoryVaultKeyStorage()
        let made = try VaultCrypto.createKey()
        server.envelope = made.envelope
        try storage.save(made.dataKey, account: "a@example.com")
        let session = VaultKeySession(storage: storage)
        session.attach(account: "a@example.com", transport: server)
        await session.check()
        XCTAssertEqual(session.phase, .ready)
        XCTAssertEqual(server.serverKey, raw(made.dataKey))
        XCTAssertEqual(server.adoptions, 1)
    }

    /// A device without the key asks once for the recovery key; afterwards every device opens by signing in.
    func testOlderAccountWithoutAKeyAsksForTheRecoveryKeyOnce() async throws {
        let server = MemoryVaultTransport()
        let made = try VaultCrypto.createKey()
        server.envelope = made.envelope
        let session = VaultKeySession(storage: MemoryVaultKeyStorage())
        session.attach(account: "a@example.com", transport: server)
        await session.check()
        XCTAssertEqual(session.phase, .needsTransfer)
        XCTAssertNil(session.dataKey)
        let wrong = await session.restore(recoveryText: "0000-0000-0000-0000-0000-0000-0000-0000")
        XCTAssertEqual(wrong, "Ключ восстановления не подошёл.")
        XCTAssertEqual(server.adoptions, 0, "A wrong key never reaches the server")
        let ok = await session.restore(recoveryText: made.recoveryKey)
        XCTAssertNil(ok)
        XCTAssertEqual(session.phase, .ready)
        XCTAssertEqual(raw(session.dataKey), raw(made.dataKey))
        XCTAssertEqual(server.serverKey, raw(made.dataKey))

        let other = VaultKeySession(storage: MemoryVaultKeyStorage())
        other.attach(account: "a@example.com", transport: server)
        await other.check()
        XCTAssertEqual(other.phase, .ready, "The next device needs no recovery key")
    }

    func testTwoChecksAtOnceAskTheServerOnce() async {
        let server = MemoryVaultTransport()
        let session = VaultKeySession(storage: MemoryVaultKeyStorage())
        session.attach(account: "a@example.com", transport: server)
        async let a: Void = session.check()
        async let b: Void = session.check()
        _ = await (a, b)
        XCTAssertEqual(server.keyFetches, 1)
        XCTAssertEqual(session.phase, .ready)
    }

    func testKeyStaysPerAccountOnThePhone() async {
        let storage = MemoryVaultKeyStorage(), server = MemoryVaultTransport()
        let session = VaultKeySession(storage: storage)
        session.attach(account: "a@example.com", transport: server)
        await session.check()
        session.reset()
        session.attach(account: "b@example.com", transport: MemoryVaultTransport())
        XCTAssertNotEqual(session.phase, .ready)
        session.reset()
        session.attach(account: "a@example.com", transport: server)
        XCTAssertEqual(session.phase, .ready)
    }
}

@MainActor
final class NotesStoreTests: XCTestCase {
    private var dirs: [URL] = []

    override func tearDown() {
        for dir in dirs { try? FileManager.default.removeItem(at: dir) }
        super.tearDown()
    }

    private func makeStore(clock: @escaping () -> Int64 = { 1_000 }) -> NotesStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        dirs.append(dir)
        let store = NotesStore(baseDirectory: dir, now: clock)
        store.syncDelay = .seconds(3600)
        return store
    }

    func testEditsSyncEncryptedAndReachAnotherDevice() async throws {
        let key = SymmetricKey(size: .bits256), server = MemoryVaultTransport()
        let phone = makeStore(), pc = makeStore()
        phone.attach(account: "a@example.com", key: key, transport: server)
        let id = try XCTUnwrap(phone.create(text: "Купить молоко\n- [ ] хлеб"))
        await phone.sync()
        XCTAssertEqual(phone.syncState, .idle)
        let stored = try XCTUnwrap(server.records[id])
        XCTAssertFalse(Data(base64Encoded: stored.c)!.contains(Data("молоко".utf8)), "The server holds ciphertext only")

        pc.attach(account: "a@example.com", key: key, transport: server)
        await pc.sync()
        XCTAssertEqual(pc.notes.map(\.text), ["Купить молоко\n- [ ] хлеб"])
        XCTAssertEqual(pc.notes.first?.checklistProgress?.total, 1)
    }

    func testConflictKeepsBothTexts() async throws {
        let key = SymmetricKey(size: .bits256), server = MemoryVaultTransport()
        let phone = makeStore(), pc = makeStore()
        phone.attach(account: "a@example.com", key: key, transport: server)
        let id = try XCTUnwrap(phone.create(text: "Идея"))
        await phone.sync()
        pc.attach(account: "a@example.com", key: key, transport: server)
        await pc.sync()

        phone.update(id, text: "Идея — с телефона")
        pc.update(id, text: "Идея — с ноутбука")
        await phone.sync()
        await pc.sync()
        await phone.sync()

        XCTAssertEqual(Set(pc.notes.map(\.text)), ["Идея — с телефона", "Идея — с ноутбука"])
        XCTAssertEqual(Set(phone.notes.map(\.text)), Set(pc.notes.map(\.text)))
    }

    func testDeleteReachesOtherDevicesAndUndoWorks() async throws {
        let key = SymmetricKey(size: .bits256), server = MemoryVaultTransport()
        let phone = makeStore(), pc = makeStore()
        phone.attach(account: "a@example.com", key: key, transport: server)
        let id = try XCTUnwrap(phone.create(text: "Удалить меня"))
        await phone.sync()
        pc.attach(account: "a@example.com", key: key, transport: server)
        await pc.sync()

        phone.delete(id)
        XCTAssertTrue(phone.notes.isEmpty)
        phone.undoDelete()
        XCTAssertEqual(phone.notes.count, 1)
        phone.delete(id)
        await phone.sync()
        await pc.sync()
        XCTAssertTrue(pc.notes.isEmpty)
    }

    func testOfflineEditStaysAndUploadsLater() async throws {
        let key = SymmetricKey(size: .bits256), server = MemoryVaultTransport()
        let phone = makeStore()
        phone.attach(account: "a@example.com", key: key, transport: server)
        server.failNext = true
        let id = try XCTUnwrap(phone.create(text: "Без связи"))
        await phone.sync()
        if case .offline = phone.syncState {} else { XCTFail("Expected offline state") }
        XCTAssertNil(server.records[id])
        await phone.sync()
        XCTAssertNotNil(server.records[id])
    }

    func testCacheReopensAfterRestartAndSignOutClearsMemory() throws {
        let key = SymmetricKey(size: .bits256)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        dirs.append(dir)
        let first = NotesStore(baseDirectory: dir)
        first.attach(account: "a@example.com", key: key, transport: nil)
        first.create(text: "Сохранится")
        first.detach()
        XCTAssertTrue(first.notes.isEmpty)

        let files = try FileManager.default.subpathsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".json") }
        let raw = try Data(contentsOf: dir.appendingPathComponent(files[0]))
        XCTAssertFalse(raw.contains(Data("Сохранится".utf8)), "The phone keeps ciphertext only")

        let second = NotesStore(baseDirectory: dir)
        second.attach(account: "a@example.com", key: key, transport: nil)
        XCTAssertEqual(second.notes.map(\.text), ["Сохранится"])
        let other = NotesStore(baseDirectory: dir)
        other.attach(account: "b@example.com", key: key, transport: nil)
        XCTAssertTrue(other.notes.isEmpty)
    }

    func testOrderingPinChecklistAndEmptyTextDeletes() throws {
        var clock: Int64 = 1_000
        let store = makeStore(clock: { clock })
        store.attach(account: "a@example.com", key: SymmetricKey(size: .bits256), transport: nil)
        let old = try XCTUnwrap(store.create(text: "Старая"))
        clock = 2_000
        let new = try XCTUnwrap(store.create(text: "Список\n- [ ] один\n- [x] два"))
        XCTAssertEqual(store.notes.map(\.id), [new, old])
        store.togglePin(old)
        XCTAssertEqual(store.notes.map(\.id), [old, new])
        store.toggleChecklist(new, line: 1)
        XCTAssertEqual(store.note(new)?.text, "Список\n- [x] один\n- [x] два")
        XCTAssertEqual(store.note(new)?.title, "Список")
        XCTAssertEqual(store.note(new)?.preview, "один")
        store.update(old, text: "  ")
        XCTAssertNil(store.note(old))
    }

    func testHints() {
        XCTAssertTrue(NoteText.hints("Завтра в 15:00 стоматолог").looksLikePlan)
        XCTAssertTrue(NoteText.hints("Потратил 3500 на такси").looksLikeExpense)
        XCTAssertTrue(NoteText.hints("кофе 1200 тг").looksLikeExpense)
        let plain = NoteText.hints("Книга «Атомные привычки» — посоветовал друг")
        XCTAssertFalse(plain.looksLikePlan)
        XCTAssertFalse(plain.looksLikeExpense)
    }
}
