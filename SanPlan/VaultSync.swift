import Foundation
import CryptoKit
import Security

// MARK: - Transport

public struct VaultRemoteRecord: Codable, Equatable, Sendable {
    public var id: String
    public var revision: Int
    public var c: String
    /// The server's change counter value for this write (live sync). Nil for rows written before counters existed.
    public var seq: Int?

    public init(id: String, revision: Int, c: String, seq: Int? = nil) {
        self.id = id
        self.revision = revision
        self.c = c
        self.seq = seq
    }
}

public enum VaultPutResult: Equatable, Sendable {
    case saved(revision: Int)
    /// Someone else saved first; `current` is what the server holds now (nil if it vanished).
    case conflict(current: VaultRemoteRecord?)
}

/// `GET /api/vault/key`: the account's data key, held by the server (docs/ONE-APP-PLAN.md, «Sync contract»).
public struct VaultAccountKey: Equatable, Sendable {
    /// 32 bytes; nil while the account only has a recovery-key envelope (`needsAdopt`).
    public var key: Data?
    public var needsAdopt: Bool
    public var envelope: VaultCrypto.Envelope?
    public var revision: Int

    public init(key: Data?, needsAdopt: Bool = false, envelope: VaultCrypto.Envelope? = nil, revision: Int = 0) {
        self.key = key
        self.needsAdopt = needsAdopt
        self.envelope = envelope
        self.revision = revision
    }
}

public enum VaultAdoptResult: Equatable, Sendable {
    /// The server now holds this key (the one sent, or the one it already had).
    case saved(Data)
    /// The account already has a different key; the payload is the current one.
    case conflict(Data?)
}

/// One page of a collection: its records and the collection's counter at the time.
public struct VaultListing: Equatable, Sendable {
    public var records: [VaultRemoteRecord]
    public var stamp: Int?

    public init(records: [VaultRemoteRecord], stamp: Int? = nil) {
        self.records = records
        self.stamp = stamp
    }
}

/// The server half of docs/personal-hub/E2E-SYNC.md. Tests use an in-memory twin.
public protocol VaultTransport: Sendable {
    func fetchAccountKey() async throws -> VaultAccountKey
    func adoptKey(_ key: Data) async throws -> VaultAdoptResult
    /// One counter per namespace (`plans`, `notes`, `finance`, …); a moved counter means something changed.
    func stamps() async throws -> [String: Int]
    /// `since` nil: everything. Otherwise only records written after that `seq`.
    func list(_ collection: String, since: Int?) async throws -> VaultListing
    func put(_ collection: String, record: VaultRemoteRecord) async throws -> VaultPutResult
}

public extension VaultTransport {
    func list(_ collection: String) async throws -> [VaultRemoteRecord] {
        try await list(collection, since: nil).records
    }
}

public struct HTTPVaultTransport: VaultTransport {
    let client: APIClient

    public init(client: APIClient) { self.client = client }

    private struct KeyResponse: Decodable {
        let key: String?
        let needsAdopt: Bool?
        let envelope: VaultCrypto.Envelope?
        let revision: Int?
    }
    private struct AdoptBody: Encodable { let key: String }
    private struct AdoptResponse: Decodable { let key: String? }
    private struct StampsResponse: Decodable { let stamps: [String: Int] }
    private struct ListResponse: Decodable { let records: [VaultRemoteRecord]; let stamp: Int? }
    private struct PutResponse: Decodable { let revision: Int }
    private struct ConflictResponse: Decodable { let current: VaultRemoteRecord? }

    private static func check(_ status: Int, _ data: Data) throws {
        guard (200...299).contains(status) else {
            let message = (try? JSONDecoder().decode(ServerErrorMessage.self, from: data))?.message
            throw APIError.server(status: status, message: message ?? "Сервер не ответил. Повтори позже.")
        }
    }

    /// A 32-byte key from base64; anything else is treated as no key.
    static func keyBytes(_ text: String?) -> Data? {
        guard let text, let data = Data(base64Encoded: text), data.count == 32 else { return nil }
        return data
    }

    public func fetchAccountKey() async throws -> VaultAccountKey {
        let (status, data) = try await client.send(method: "GET", path: "/api/vault/key")
        try Self.check(status, data)
        let value = try JSONDecoder().decode(KeyResponse.self, from: data)
        return VaultAccountKey(key: Self.keyBytes(value.key), needsAdopt: value.needsAdopt ?? false, envelope: value.envelope, revision: value.revision ?? 0)
    }

    public func adoptKey(_ key: Data) async throws -> VaultAdoptResult {
        let (status, data) = try await client.send(method: "POST", path: "/api/vault/key/adopt", body: AdoptBody(key: key.base64EncodedString()))
        if status == 409 {
            return .conflict(Self.keyBytes((try? JSONDecoder().decode(AdoptResponse.self, from: data))?.key))
        }
        try Self.check(status, data)
        return .saved(Self.keyBytes(try JSONDecoder().decode(AdoptResponse.self, from: data).key) ?? key)
    }

    public func stamps() async throws -> [String: Int] {
        let (status, data) = try await client.send(method: "GET", path: "/api/vault/stamps")
        try Self.check(status, data)
        return try JSONDecoder().decode(StampsResponse.self, from: data).stamps
    }

    public func list(_ collection: String, since: Int?) async throws -> VaultListing {
        let query = since.map { ["since": String($0)] }
        let (status, data) = try await client.send(method: "GET", path: "/api/vault/\(collection)", query: query)
        try Self.check(status, data)
        let value = try JSONDecoder().decode(ListResponse.self, from: data)
        return VaultListing(records: value.records, stamp: value.stamp)
    }

    public func put(_ collection: String, record: VaultRemoteRecord) async throws -> VaultPutResult {
        let (status, data) = try await client.send(method: "POST", path: "/api/vault/\(collection)/put", body: record)
        if status == 409 { return .conflict(current: try JSONDecoder().decode(ConflictResponse.self, from: data).current) }
        try Self.check(status, data)
        return .saved(revision: try JSONDecoder().decode(PutResponse.self, from: data).revision)
    }
}

// MARK: - Device key storage

/// Where the data key lives on this device. The real one is the Keychain; tests use memory.
public protocol VaultKeyStorage: AnyObject {
    func load(account: String) -> SymmetricKey?
    func save(_ key: SymmetricKey, account: String) throws
    func delete(account: String)
}

public final class KeychainVaultKeyStorage: VaultKeyStorage {
    private let service = "arna.vault.data-key.v1"

    public init() {}

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: FinanceStore.accountFolderName(account)]
    }

    public func load(account: String) -> SymmetricKey? {
        var request = query(account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, data.count == 32 else { return nil }
        return SymmetricKey(data: data)
    }

    public func save(_ key: SymmetricKey, account: String) throws {
        delete(account: account)
        var item = query(account)
        item[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
        // Available after the first unlock, so a sync can run in the background; restored only from encrypted backups.
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: "ARNA.Vault", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Не удалось сохранить ключ на телефоне."])
        }
    }

    public func delete(account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }
}

public final class MemoryVaultKeyStorage: VaultKeyStorage {
    private var keys: [String: SymmetricKey] = [:]
    public init() {}
    public func load(account: String) -> SymmetricKey? { keys[account] }
    public func save(_ key: SymmetricKey, account: String) throws { keys[account] = key }
    public func delete(account: String) { keys[account] = nil }
}

// MARK: - Key session

/// Whether this device holds the account's data key. The server holds it per account, so signing in is enough.
/// The only question ever asked of the person is the one-time transfer of an older recovery key (`needsTransfer`).
@MainActor
public final class VaultKeySession: ObservableObject {
    public enum Phase: Equatable {
        /// Signed out, or not checked yet.
        case idle
        case checking
        /// The account has data under an older recovery key and this device does not hold the key:
        /// enter the recovery key once («Перенос данных в аккаунт»).
        case needsTransfer
        case ready
        case failed(String)
    }

    @Published public private(set) var phase: Phase = .idle
    /// Bumped whenever the key in use changes (the first key, or the server's key replacing the cached one).
    @Published public private(set) var keyVersion = 0

    public private(set) var dataKey: SymmetricKey?
    public private(set) var account: String?
    private var transferEnvelope: VaultCrypto.Envelope?
    private var transport: (any VaultTransport)?
    private let storage: VaultKeyStorage
    private var checkTask: Task<Void, Never>?
    private var generation = 0
    /// Called once the key is available and again whenever it changes, so stores load and sync under the right key.
    public var onReady: (() -> Void)?

    public init(storage: VaultKeyStorage = KeychainVaultKeyStorage()) {
        self.storage = storage
    }

    public func attach(account: String, transport: any VaultTransport) {
        guard self.account != account else { return }
        reset()
        self.account = account
        self.transport = transport
        if let key = storage.load(account: account) {
            dataKey = key
            phase = .ready
            onReady?()
        }
    }

    /// Signed out: forget the key in memory. It stays in this account's Keychain item for the next sign-in.
    public func reset() {
        generation += 1
        checkTask?.cancel()
        checkTask = nil
        account = nil
        transport = nil
        dataKey = nil
        transferEnvelope = nil
        phase = .idle
    }

    /// Asks the server for the account's key. Runs on every start: a cached key keeps the app open offline,
    /// and a different key from the server replaces it. One check at a time.
    public func check() async {
        if let running = checkTask { await running.value; return }
        guard transport != nil, account != nil else { return }
        let started = generation
        let task = Task { await self.runCheck(generation: started) }
        checkTask = task
        await task.value
    }

    private func runCheck(generation started: Int) async {
        defer { if generation == started { checkTask = nil } }
        guard let transport, let account else { return }
        if dataKey == nil { phase = .checking }
        do {
            let info = try await transport.fetchAccountKey()
            guard generation == started else { return }
            try await apply(info, transport: transport, account: account, generation: started)
        } catch {
            // With a cached key the app stays open (offline); without one there is nothing to show but the error.
            guard generation == started, dataKey == nil else { return }
            phase = .failed((error as? LocalizedError)?.errorDescription ?? "Не удалось связаться с сервером. Проверьте соединение и повторите.")
        }
    }

    private func apply(_ info: VaultAccountKey, transport: any VaultTransport, account: String, generation started: Int) async throws {
        if let raw = info.key {
            use(SymmetricKey(data: raw), account: account)
            return
        }
        // An account from before the server held keys.
        if let cached = dataKey {
            // This device has the key: hand it to the account silently.
            let result = try await transport.adoptKey(Self.bytes(cached))
            guard generation == started else { return }
            switch result {
            case .saved(let raw): use(SymmetricKey(data: raw), account: account)
            case .conflict(let raw?): use(SymmetricKey(data: raw), account: account)
            case .conflict(nil): phase = .failed("Не удалось перенести ключ в аккаунт. Повторите позже.")
            }
            return
        }
        guard let envelope = info.envelope else {
            phase = .failed("Не удалось получить ключ аккаунта. Повторите позже.")
            return
        }
        transferEnvelope = envelope
        phase = .needsTransfer
    }

    private static func bytes(_ key: SymmetricKey) -> Data { key.withUnsafeBytes { Data($0) } }

    /// Makes `key` the key in use. Stores react through `onReady` only when something changed.
    private func use(_ key: SymmetricKey, account: String) {
        let changed = dataKey.map { Self.bytes($0) != Self.bytes(key) } ?? true
        if changed {
            try? storage.save(key, account: account)
            dataKey = key
            keyVersion += 1
        }
        transferEnvelope = nil
        let wasReady = phase == .ready
        phase = .ready
        if changed || !wasReady { onReady?() }
    }

    /// The one-time transfer: opens the old recovery key and hands the data key to the account.
    /// Returns an error text to show next to the field, or nil when the data moved.
    public func restore(recoveryText: String) async -> String? {
        guard let transport, let account, let envelope = transferEnvelope else { return "Войдите снова." }
        let started = generation
        do {
            let key = try VaultCrypto.unwrap(envelope, recoveryText: recoveryText)
            let result = try await transport.adoptKey(Self.bytes(key))
            guard generation == started else { return nil }
            switch result {
            case .saved(let raw): use(SymmetricKey(data: raw), account: account)
            case .conflict(let raw?): use(SymmetricKey(data: raw), account: account)
            case .conflict(nil): return "Не удалось перенести данные. Повторите позже."
            }
            return nil
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? "Не удалось перенести данные. Проверьте соединение и повторите."
        }
    }

    #if DEBUG
    /// Debug screenshots run without a server: a throwaway key held only in memory.
    public func useEphemeralKeyForScreenshots() {
        account = "screenshots"
        dataKey = SymmetricKey(size: .bits256)
        phase = .ready
    }
    #endif
}
