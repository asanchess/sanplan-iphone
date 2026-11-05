import Foundation
import CommonCrypto
import CryptoKit

public enum FinanceVaultConstants {
    public static let vaultKey = "arna.finance.vault.v1"
    public static let format = "arna-finance-vault"
    public static let version = 1
    public static let kdf = "PBKDF2-SHA256"
    public static let iterations: UInt32 = 310_000
    public static let saltLength = 16
    public static let ivLength = 12
    public static let keyLength = 32
    public static let tagLength = 16
    public static let aadString = "ARNA|finance|v1|PBKDF2-SHA256|310000"
}

public enum FinanceVaultError: LocalizedError, Equatable {
    case invalidPassphrase(String)
    case invalidEnvelope(String)
    case decryptionFailed(String)
    case payloadTooLarge(String)

    public var errorDescription: String? {
        switch self {
        case .invalidPassphrase(let msg):
            return msg
        case .invalidEnvelope(let msg):
            return msg
        case .decryptionFailed(let msg):
            return msg
        case .payloadTooLarge(let msg):
            return msg
        }
    }
}

public struct FinanceVaultEnvelope: Codable, Equatable {
    public var format: String
    public var version: Int
    public var kdf: String
    public var iterations: UInt32
    public var salt: String
    public var iv: String
    public var ciphertext: String

    public init(
        format: String = FinanceVaultConstants.format,
        version: Int = FinanceVaultConstants.version,
        kdf: String = FinanceVaultConstants.kdf,
        iterations: UInt32 = FinanceVaultConstants.iterations,
        salt: String,
        iv: String,
        ciphertext: String
    ) {
        self.format = format
        self.version = version
        self.kdf = kdf
        self.iterations = iterations
        self.salt = salt
        self.iv = iv
        self.ciphertext = ciphertext
    }
}

public enum FinanceVault {
    private static var aadData: Data {
        Data(FinanceVaultConstants.aadString.utf8)
    }

    private static func validatePassword(_ password: String) throws {
        if password.utf16.count < 8 || password.utf16.count > 256 {
            throw FinanceVaultError.invalidPassphrase("Пароль должен содержать от 8 до 256 символов.")
        }
    }

    private static func deriveKey(password: String, salt: Data) throws -> SymmetricKey {
        try validatePassword(password)
        guard salt.count == FinanceVaultConstants.saltLength else {
            throw FinanceVaultError.invalidEnvelope("Некорректная резервная копия.")
        }

        let passwordData = Data(password.utf8)
        var derivedKey = [UInt8](repeating: 0, count: FinanceVaultConstants.keyLength)

        let status = passwordData.withUnsafeBytes { passBytes in
            salt.withUnsafeBytes { saltBytes in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passBytes.baseAddress?.assumingMemoryBound(to: Int8.self),
                    passwordData.count,
                    saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    FinanceVaultConstants.iterations,
                    &derivedKey,
                    FinanceVaultConstants.keyLength
                )
            }
        }

        guard status == kCCSuccess else {
            throw FinanceVaultError.decryptionFailed("Не удалось получить ключ шифрования.")
        }

        return SymmetricKey(data: Data(derivedKey))
    }

    public static func readVaultEnvelope(from jsonString: String) throws -> FinanceVaultEnvelope {
        if jsonString.count > 1_500_000 {
            throw FinanceVaultError.invalidEnvelope("Некорректный файл финансов.")
        }

        guard let data = jsonString.data(using: .utf8) else {
            throw FinanceVaultError.invalidEnvelope("Некорректный файл финансов.")
        }

        let envelope: FinanceVaultEnvelope
        do {
            envelope = try JSONDecoder().decode(FinanceVaultEnvelope.self, from: data)
        } catch {
            throw FinanceVaultError.invalidEnvelope("Некорректный файл финансов.")
        }

        if envelope.format != FinanceVaultConstants.format ||
            envelope.version != FinanceVaultConstants.version ||
            envelope.kdf != FinanceVaultConstants.kdf ||
            envelope.iterations != FinanceVaultConstants.iterations {
            throw FinanceVaultError.invalidEnvelope("Неподдерживаемый формат финансов.")
        }

        guard let saltData = Data(base64Encoded: envelope.salt),
              saltData.count == FinanceVaultConstants.saltLength else {
            throw FinanceVaultError.invalidEnvelope("Некорректный файл финансов.")
        }

        guard let ivData = Data(base64Encoded: envelope.iv),
              ivData.count == FinanceVaultConstants.ivLength else {
            throw FinanceVaultError.invalidEnvelope("Некорректный файл финансов.")
        }

        guard let cipherData = Data(base64Encoded: envelope.ciphertext),
              cipherData.count >= 17 && cipherData.count <= 1_000_016 else {
            throw FinanceVaultError.invalidEnvelope("Некорректный файл финансов.")
        }

        return envelope
    }

    public static func sealFinance(state: FinanceState, password: String) async throws -> FinanceVaultEnvelope {
        let clean = try validateFinance(state)
        let encoder = JSONEncoder()
        let jsonData = try encoder.encode(clean)

        if jsonData.count > 1_000_000 {
            throw FinanceVaultError.payloadTooLarge("Хранилище больше 1 МБ.")
        }

        var saltBytes = [UInt8](repeating: 0, count: FinanceVaultConstants.saltLength)
        guard SecRandomCopyBytes(kSecRandomDefault, FinanceVaultConstants.saltLength, &saltBytes) == errSecSuccess else {
            throw FinanceVaultError.decryptionFailed("Не удалось сгенерировать соль.")
        }
        let salt = Data(saltBytes)

        var ivBytes = [UInt8](repeating: 0, count: FinanceVaultConstants.ivLength)
        guard SecRandomCopyBytes(kSecRandomDefault, FinanceVaultConstants.ivLength, &ivBytes) == errSecSuccess else {
            throw FinanceVaultError.decryptionFailed("Не удалось сгенерировать вектор инициализации.")
        }
        let iv = Data(ivBytes)

        let symmetricKey = try deriveKey(password: password, salt: salt)
        let nonce = try AES.GCM.Nonce(data: iv)

        let sealedBox = try AES.GCM.seal(jsonData, using: symmetricKey, nonce: nonce, authenticating: aadData)

        // WebCrypto format: combined ciphertext + tag (16 bytes)
        var combinedCipher = Data()
        combinedCipher.append(sealedBox.ciphertext)
        combinedCipher.append(sealedBox.tag)

        return FinanceVaultEnvelope(
            salt: salt.base64EncodedString(),
            iv: iv.base64EncodedString(),
            ciphertext: combinedCipher.base64EncodedString()
        )
    }

    public static func openFinance(envelope: FinanceVaultEnvelope, password: String) async throws -> FinanceState {
        let validEnvelope: FinanceVaultEnvelope
        do {
            let data = try JSONEncoder().encode(envelope)
            guard let json = String(data: data, encoding: .utf8) else {
                throw FinanceVaultError.invalidEnvelope("Некорректный файл финансов.")
            }
            validEnvelope = try readVaultEnvelope(from: json)
        } catch let err as FinanceVaultError {
            throw err
        } catch {
            throw FinanceVaultError.invalidEnvelope("Некорректный файл финансов.")
        }

        guard let salt = Data(base64Encoded: validEnvelope.salt),
              let iv = Data(base64Encoded: validEnvelope.iv),
              let combinedCipher = Data(base64Encoded: validEnvelope.ciphertext),
              combinedCipher.count >= FinanceVaultConstants.tagLength else {
            throw FinanceVaultError.decryptionFailed("Не удалось открыть финансы. Проверь пароль и резервную копию.")
        }

        let symmetricKey: SymmetricKey
        do {
            symmetricKey = try deriveKey(password: password, salt: salt)
        } catch let err as FinanceVaultError {
            throw err
        } catch {
            throw FinanceVaultError.decryptionFailed("Не удалось открыть финансы. Проверь пароль и резервную копию.")
        }

        let cipherSplit = combinedCipher.count - FinanceVaultConstants.tagLength
        let ciphertext = combinedCipher.prefix(cipherSplit)
        let tag = combinedCipher.suffix(FinanceVaultConstants.tagLength)

        do {
            let nonce = try AES.GCM.Nonce(data: iv)
            let sealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
            let plaintext = try AES.GCM.open(sealedBox, using: symmetricKey, authenticating: aadData)
            let decoded = try JSONDecoder().decode(FinanceState.self, from: plaintext)
            return try validateFinance(decoded)
        } catch {
            throw FinanceVaultError.decryptionFailed("Не удалось открыть финансы. Проверь пароль и резервную копию.")
        }
    }
}
