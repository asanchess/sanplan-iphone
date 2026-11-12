import Foundation
import CryptoKit

/// End-to-end encryption shared by every synced module. The web twin is src/vault-crypto.mjs; both read each
/// other's output (native/reference/e2e-fixture.json). Spec: docs/personal-hub/E2E-SYNC.md.
public enum VaultCrypto {
    public static let recoveryByteCount = 20
    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    private static let keyAAD = Data("ARNA|vault-key|v1".utf8)
    private static let hkdfInfo = Data("ARNA vault recovery v1".utf8)

    public enum Failure: LocalizedError, Equatable {
        case recoveryFormat, recoveryMismatch, damaged, unknownFormat

        public var errorDescription: String? {
            switch self {
            case .recoveryFormat: return "Ключ восстановления — 32 знака: буквы и цифры."
            case .recoveryMismatch: return "Ключ восстановления не подошёл."
            case .damaged: return "Запись не расшифровалась."
            case .unknownFormat: return "Неизвестный формат записи."
            }
        }
    }

    public struct Envelope: Codable, Equatable, Sendable {
        public var v: Int
        public var salt: String
        public var wrapped: String
    }

    // MARK: Recovery key

    /// 20 bytes as 32 Crockford base32 characters in groups of four.
    public static func formatRecoveryKey(_ bytes: Data) -> String {
        precondition(bytes.count == recoveryByteCount)
        var bits = 0, value = 0, out: [Character] = []
        for byte in bytes {
            value = (value << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                out.append(alphabet[(value >> (bits - 5)) & 31])
                bits -= 5
            }
            value &= (1 << bits) - 1
        }
        return stride(from: 0, to: out.count, by: 4).map { String(out[$0..<min($0 + 4, out.count)]) }.joined(separator: "-")
    }

    /// Accepts any case, spaces and dashes; O reads as 0, I and L as 1.
    public static func parseRecoveryKey(_ text: String) throws -> Data {
        let clean = text.uppercased()
            .filter { !$0.isWhitespace && $0 != "-" }
            .map { $0 == "O" ? "0" : ($0 == "I" || $0 == "L") ? "1" : $0 }
        guard clean.count == 32 else { throw Failure.recoveryFormat }
        var bytes = Data(), bits = 0, value = 0
        for c in clean {
            guard let index = alphabet.firstIndex(of: c) else { throw Failure.recoveryFormat }
            value = (value << 5) | index
            bits += 5
            if bits >= 8 {
                bytes.append(UInt8((value >> (bits - 8)) & 255))
                bits -= 8
            }
            value &= (1 << bits) - 1
        }
        return bytes
    }

    // MARK: Data key

    public struct NewKey {
        public let dataKey: SymmetricKey
        public let recoveryKey: String
        public let envelope: Envelope
    }

    public static func createKey() throws -> NewKey {
        let dataKey = SymmetricKey(size: .bits256)
        let recovery = randomBytes(recoveryByteCount)
        return NewKey(dataKey: dataKey, recoveryKey: formatRecoveryKey(recovery), envelope: try wrap(dataKey, recovery: recovery))
    }

    public static func wrap(_ dataKey: SymmetricKey, recovery: Data, salt: Data = randomBytes(16), nonce: AES.GCM.Nonce = AES.GCM.Nonce()) throws -> Envelope {
        let kek = recoveryKEK(recovery, salt: salt)
        let raw = dataKey.withUnsafeBytes { Data($0) }
        let sealed = try AES.GCM.seal(raw, using: kek, nonce: nonce, authenticating: keyAAD)
        guard let combined = sealed.combined else { throw Failure.damaged }
        return Envelope(v: 1, salt: salt.base64EncodedString(), wrapped: combined.base64EncodedString())
    }

    public static func unwrap(_ envelope: Envelope, recoveryText: String) throws -> SymmetricKey {
        guard envelope.v == 1 else { throw Failure.unknownFormat }
        let recovery = try parseRecoveryKey(recoveryText)
        guard let salt = Data(base64Encoded: envelope.salt), let wrapped = Data(base64Encoded: envelope.wrapped) else { throw Failure.damaged }
        do {
            let box = try AES.GCM.SealedBox(combined: wrapped)
            let raw = try AES.GCM.open(box, using: recoveryKEK(recovery, salt: salt), authenticating: keyAAD)
            guard raw.count == 32 else { throw Failure.recoveryMismatch }
            return SymmetricKey(data: raw)
        } catch {
            throw Failure.recoveryMismatch
        }
    }

    private static func recoveryKEK(_ recovery: Data, salt: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: recovery), salt: salt, info: hkdfInfo, outputByteCount: 32)
    }

    // MARK: Records

    private static func recordAAD(_ collection: String, _ id: String) -> Data {
        Data("ARNA|\(collection)|\(id)|v1".utf8)
    }

    /// Plaintext JSON → base64(nonce ‖ ciphertext ‖ tag), bound to its collection and id.
    public static func seal(_ plaintext: Data, key: SymmetricKey, collection: String, id: String) throws -> String {
        let sealed = try AES.GCM.seal(plaintext, using: key, authenticating: recordAAD(collection, id))
        guard let combined = sealed.combined else { throw Failure.damaged }
        return combined.base64EncodedString()
    }

    public static func open(_ c: String, key: SymmetricKey, collection: String, id: String) throws -> Data {
        guard let combined = Data(base64Encoded: c), combined.count >= 28 else { throw Failure.damaged }
        do {
            return try AES.GCM.open(try AES.GCM.SealedBox(combined: combined), using: key, authenticating: recordAAD(collection, id))
        } catch {
            throw Failure.damaged
        }
    }

    public static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        var generator = SystemRandomNumberGenerator()
        for i in bytes.indices { bytes[i] = generator.next() }
        return Data(bytes)
    }
}
