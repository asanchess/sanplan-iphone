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

/// The server's half in memory, with the same revision rules as cloud/vault.mjs.
final class MemoryVaultTransport: VaultTransport, @unchecked Sendable {
    private let lock = NSLock()
    var envelope: VaultCrypto.Envelope?
    var records: [String: VaultRemoteRecord] = [:]
    var failNext = false

    func fetchKey() async throws -> (envelope: VaultCrypto.Envelope?, revision: Int) {
        lock.withLock { (envelope, envelope == nil ? 0 : 1) }
    }

    func putKey(_ value: VaultCrypto.Envelope, revision: Int) async throws -> VaultKeyPutResult {
        lock.withLock {
            if let envelope { return .conflict(envelope: envelope, revision: 1) }
            envelope = value
            return .saved
        }
    }

    func list(_ collection: String) async throws -> [VaultRemoteRecord] {
        try lock.withLock {
            if failNext { failNext = false; throw APIError.transport("offline") }
            return Array(records.values)
        }
    }

    func put(_ collection: String, record: VaultRemoteRecord) async throws -> VaultPutResult {
        try lock.withLock {
            if failNext { failNext = false; throw APIError.transport("offline") }
            let current = records[record.id]
            guard (current?.revision ?? 0) == record.revision else { return .conflict(current: current) }
            records[record.id] = VaultRemoteRecord(id: record.id, revision: record.revision + 1, c: record.c)
            return .saved(revision: record.revision + 1)
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
    func testFirstDeviceSetsUpSecondDeviceRestores() async {
        let server = MemoryVaultTransport()
        let first = VaultKeySession(storage: MemoryVaultKeyStorage())
        first.attach(account: "a@example.com", transport: server)
        await first.check()
        XCTAssertEqual(first.phase, .needsSetup)
        first.beginSetup()
        let recovery = first.pendingRecoveryKey
        XCTAssertNotNil(recovery)
        XCTAssertNil(server.envelope, "Nothing is uploaded before the person confirms the key is saved")
        await first.confirmSetup()
        XCTAssertEqual(first.phase, .ready)
        XCTAssertNil(first.pendingRecoveryKey)

        let second = VaultKeySession(storage: MemoryVaultKeyStorage())
        second.attach(account: "a@example.com", transport: server)
        await second.check()
        XCTAssertEqual(second.phase, .needsRecovery)
        let wrong = await second.restore(recoveryText: "0000-0000-0000-0000-0000-0000-0000-0000")
        XCTAssertEqual(wrong, "Ключ восстановления не подошёл.")
        let ok = await second.restore(recoveryText: recovery!)
        XCTAssertNil(ok)
        XCTAssertEqual(second.phase, .ready)
        XCTAssertEqual(second.dataKey?.withUnsafeBytes { Data($0) }, first.dataKey?.withUnsafeBytes { Data($0) })
    }

    func testSetupRaceFallsBackToRecovery() async {
        let server = MemoryVaultTransport()
        let a = VaultKeySession(storage: MemoryVaultKeyStorage()), b = VaultKeySession(storage: MemoryVaultKeyStorage())
        a.attach(account: "a@example.com", transport: server)
        b.attach(account: "a@example.com", transport: server)
        await a.check(); await b.check()
        a.beginSetup(); b.beginSetup()
        await a.confirmSetup()
        await b.confirmSetup()
        XCTAssertEqual(a.phase, .ready)
        XCTAssertEqual(b.phase, .needsRecovery)
        XCTAssertNil(b.dataKey)
    }

    func testKeyStaysPerAccountOnThePhone() async {
        let storage = MemoryVaultKeyStorage(), server = MemoryVaultTransport()
        let session = VaultKeySession(storage: storage)
        session.attach(account: "a@example.com", transport: server)
        await session.check(); session.beginSetup(); await session.confirmSetup()
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
