import Foundation
import CryptoKit
import Security

// MARK: - Transport

public struct VaultRemoteRecord: Codable, Equatable, Sendable {
    public var id: String
    public var revision: Int
    public var c: String
}

public enum VaultPutResult: Equatable, Sendable {
    case saved(revision: Int)
    /// Someone else saved first; `current` is what the server holds now (nil if it vanished).
    case conflict(current: VaultRemoteRecord?)
}

public enum VaultKeyPutResult: Equatable, Sendable {
    case saved
    case conflict(envelope: VaultCrypto.Envelope?, revision: Int)
}

/// The server half of docs/personal-hub/E2E-SYNC.md. Tests use an in-memory twin.
public protocol VaultTransport: Sendable {
    func fetchKey() async throws -> (envelope: VaultCrypto.Envelope?, revision: Int)
    func putKey(_ envelope: VaultCrypto.Envelope, revision: Int) async throws -> VaultKeyPutResult
    func list(_ collection: String) async throws -> [VaultRemoteRecord]
    func put(_ collection: String, record: VaultRemoteRecord) async throws -> VaultPutResult
}

public struct HTTPVaultTransport: VaultTransport {
    let client: APIClient

    public init(client: APIClient) { self.client = client }

    private struct KeyResponse: Decodable { let envelope: VaultCrypto.Envelope?; let revision: Int }
    private struct KeyBody: Encodable { let revision: Int; let envelope: VaultCrypto.Envelope }
    private struct ListResponse: Decodable { let records: [VaultRemoteRecord] }
    private struct PutResponse: Decodable { let revision: Int }
    private struct ConflictResponse: Decodable { let current: VaultRemoteRecord? }

    private static func check(_ status: Int, _ data: Data) throws {
        guard (200...299).contains(status) else {
            let message = (try? JSONDecoder().decode(ServerErrorMessage.self, from: data))?.message
            throw APIError.server(status: status, message: message ?? "Сервер не ответил. Повтори позже.")
        }
    }

    public func fetchKey() async throws -> (envelope: VaultCrypto.Envelope?, revision: Int) {
        let (status, data) = try await client.send(method: "GET", path: "/api/vault/key")
        try Self.check(status, data)
        let value = try JSONDecoder().decode(KeyResponse.self, from: data)
        return (value.envelope, value.revision)
    }

    public func putKey(_ envelope: VaultCrypto.Envelope, revision: Int) async throws -> VaultKeyPutResult {
        let (status, data) = try await client.send(method: "POST", path: "/api/vault/key", body: KeyBody(revision: revision, envelope: envelope))
        if status == 409 {
            let value = try JSONDecoder().decode(KeyResponse.self, from: data)
            return .conflict(envelope: value.envelope, revision: value.revision)
        }
        try Self.check(status, data)
        return .saved
    }

    public func list(_ collection: String) async throws -> [VaultRemoteRecord] {
        let (status, data) = try await client.send(method: "GET", path: "/api/vault/\(collection)")
        try Self.check(status, data)
        return try JSONDecoder().decode(ListResponse.self, from: data).records
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

/// Whether this device holds the account's data key, and the steps to get it.
@MainActor
public final class VaultKeySession: ObservableObject {
    public enum Phase: Equatable {
        /// Signed out, or not checked yet.
        case idle
        case checking
        /// No key on the server yet: this is the account's first device.
        case needsSetup
        /// The server has a key, this device does not: enter the recovery key.
        case needsRecovery
        case ready
        case failed(String)
    }

    @Published public private(set) var phase: Phase = .idle
    /// Shown once while setting up, until the person confirms they saved it.
    @Published public private(set) var pendingRecoveryKey: String?

    public private(set) var dataKey: SymmetricKey?
    public private(set) var account: String?
    private var pendingKey: VaultCrypto.NewKey?
    private var transport: (any VaultTransport)?
    private let storage: VaultKeyStorage
    /// Called once the key is available, so stores can load and sync.
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
        account = nil
        transport = nil
        dataKey = nil
        pendingKey = nil
        pendingRecoveryKey = nil
        phase = .idle
    }

    /// Asks the server whether the account already has a key.
    public func check() async {
        guard let transport, account != nil, phase != .ready else { return }
        phase = .checking
        do {
            let (envelope, _) = try await transport.fetchKey()
            guard phase == .checking else { return }
            phase = envelope == nil ? .needsSetup : .needsRecovery
        } catch {
            phase = .failed((error as? LocalizedError)?.errorDescription ?? "Не удалось связаться с сервером.")
        }
    }

    /// Makes a key and shows its recovery key. Nothing is uploaded until the person confirms they saved it.
    public func beginSetup() {
        guard phase == .needsSetup else { return }
        do {
            let key = try VaultCrypto.createKey()
            pendingKey = key
            pendingRecoveryKey = key.recoveryKey
        } catch {
            phase = .failed("Не удалось создать ключ.")
        }
    }

    /// The person saved the recovery key: store the envelope on the server and the key on the phone.
    public func confirmSetup() async {
        guard let transport, let account, let key = pendingKey else { return }
        do {
            switch try await transport.putKey(key.envelope, revision: 0) {
            case .saved:
                try storage.save(key.dataKey, account: account)
                pendingKey = nil
                pendingRecoveryKey = nil
                dataKey = key.dataKey
                phase = .ready
                onReady?()
            case .conflict:
                // Another device set up the account first: its key wins, enter that recovery key.
                pendingKey = nil
                pendingRecoveryKey = nil
                phase = .needsRecovery
            }
        } catch {
            phase = .failed((error as? LocalizedError)?.errorDescription ?? "Не удалось сохранить ключ.")
        }
    }

    /// Returns an error text to show next to the field, or nil when the key opened.
    public func restore(recoveryText: String) async -> String? {
        guard let transport, let account else { return "Войдите снова." }
        do {
            guard let envelope = try await transport.fetchKey().envelope else {
                phase = .needsSetup
                return nil
            }
            let key = try VaultCrypto.unwrap(envelope, recoveryText: recoveryText)
            try storage.save(key, account: account)
            dataKey = key
            phase = .ready
            onReady?()
            return nil
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? "Ключ восстановления не подошёл."
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
