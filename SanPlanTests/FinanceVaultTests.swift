import XCTest
import CryptoKit
@testable import SanPlan

final class FinanceVaultTests: XCTestCase {

    private let fixtureJson = """
    {
      "passphrase": "fixture-passphrase-only",
      "value": {
        "version": 1,
        "records": [],
        "committedBatches": []
      },
      "envelope": {
        "format": "arna-finance-vault",
        "version": 1,
        "kdf": "PBKDF2-SHA256",
        "iterations": 310000,
        "salt": "3cTP1uxpkwm9j0w9rrU5wg==",
        "iv": "qNcSkPHWKTspoHKe",
        "ciphertext": "C6gdeIQEXYdDXC+2R8c8G6uX6Kxq1AFful2WLW0SRDdf5wbTiUk2UuLKX1c3SPOjcLCBHR5bCULNOMA8j8kTHg=="
      }
    }
    """

    func testOpenFixtureFromJS() async throws {
        struct FixtureData: Decodable {
            let passphrase: String
            let value: FinanceState
            let envelope: FinanceVaultEnvelope
        }

        guard let data = fixtureJson.data(using: .utf8) else {
            XCTFail("Failed to read fixture data")
            return
        }

        let fixture = try JSONDecoder().decode(FixtureData.self, from: data)

        let openedState = try await FinanceVault.openFinance(
            envelope: fixture.envelope,
            password: fixture.passphrase
        )

        XCTAssertEqual(openedState.version, fixture.value.version)
        XCTAssertEqual(openedState.records, fixture.value.records)
        XCTAssertEqual(openedState.committedBatches, fixture.value.committedBatches)
    }

    func testRoundTripSealAndOpen() async throws {
        var state = emptyFinance()
        state.records.append(FinanceRecord(
            id: "rec1",
            kind: "balance",
            title: "Остаток",
            amountMinor: 5000000,
            date: "2026-05-01"
        ))
        state.records.append(FinanceRecord(
            id: "rec2",
            kind: "expense",
            title: "Обед",
            amountMinor: 250000,
            date: "2026-05-01",
            category: "Кафе и рестораны"
        ))

        let password = "my-secret-passphrase-123"

        let envelope = try await FinanceVault.sealFinance(state: state, password: password)

        XCTAssertEqual(envelope.format, "arna-finance-vault")
        XCTAssertEqual(envelope.version, 1)
        XCTAssertEqual(envelope.kdf, "PBKDF2-SHA256")
        XCTAssertEqual(envelope.iterations, 310000)

        let opened = try await FinanceVault.openFinance(envelope: envelope, password: password)
        XCTAssertEqual(opened, state)
    }

    func testWrongPassphraseFails() async throws {
        let state = emptyFinance()
        let envelope = try await FinanceVault.sealFinance(state: state, password: "correct-passphrase-8")

        do {
            _ = try await FinanceVault.openFinance(envelope: envelope, password: "wrong-passphrase-8")
            XCTFail("Opening with wrong password must throw")
        } catch let err as FinanceVaultError {
            XCTAssertEqual(err, .decryptionFailed("Не удалось открыть финансы. Проверь пароль и резервную копию."))
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testTamperedCiphertextFails() async throws {
        let state = emptyFinance()
        var envelope = try await FinanceVault.sealFinance(state: state, password: "correct-passphrase-8")

        // Tamper base64 ciphertext
        guard var cipherData = Data(base64Encoded: envelope.ciphertext) else {
            XCTFail("Ciphertext is not valid base64")
            return
        }
        cipherData[0] ^= 0xFF
        envelope.ciphertext = cipherData.base64EncodedString()

        do {
            _ = try await FinanceVault.openFinance(envelope: envelope, password: "correct-passphrase-8")
            XCTFail("Tampered ciphertext must fail decryption")
        } catch let err as FinanceVaultError {
            XCTAssertEqual(err, .decryptionFailed("Не удалось открыть финансы. Проверь пароль и резервную копию."))
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // MARK: - Backup under the account key

    private func sampleState() -> FinanceState {
        var state = emptyFinance()
        state.records.append(FinanceRecord(
            id: "test-record-marker",
            kind: "expense",
            title: "Test lunch",
            amountMinor: 250000,
            date: "2026-05-01",
            category: "Кафе и рестораны"
        ))
        return state
    }

    private func json(_ backup: FinanceAccountBackup) throws -> String {
        String(decoding: try JSONEncoder().encode(backup), as: UTF8.self)
    }

    func testAccountBackupRoundTrip() throws {
        let key = SymmetricKey(size: .bits256)
        let state = sampleState()

        let backup = try FinanceVault.sealAccountBackup(state: state, accountKey: key)
        XCTAssertEqual(backup.format, "asan-finance-backup")
        XCTAssertEqual(backup.version, 2)
        XCTAssertEqual(backup.kind, "account-key")
        XCTAssertEqual(backup.kdf, "HKDF-SHA256")

        let text = try json(backup)
        XCTAssertFalse(text.contains("test-record-marker"), "The file must not carry plaintext records")
        XCTAssertFalse(text.contains("Test lunch"), "The file must not carry plaintext records")
        XCTAssertEqual(try FinanceVault.backupKind(of: text), .accountKey)

        let read = try FinanceVault.readAccountBackup(from: text)
        let opened = try FinanceVault.openAccountBackup(read, accountKey: key)
        XCTAssertEqual(opened, state)
    }

    func testAccountBackupUsesFreshSaltAndNonce() throws {
        let key = SymmetricKey(size: .bits256)
        let first = try FinanceVault.sealAccountBackup(state: sampleState(), accountKey: key)
        let second = try FinanceVault.sealAccountBackup(state: sampleState(), accountKey: key)
        XCTAssertNotEqual(first.salt, second.salt)
        XCTAssertNotEqual(first.box, second.box)
    }

    func testAccountBackupWithOtherAccountKeyFails() throws {
        let backup = try FinanceVault.sealAccountBackup(state: sampleState(), accountKey: SymmetricKey(size: .bits256))
        do {
            _ = try FinanceVault.openAccountBackup(backup, accountKey: SymmetricKey(size: .bits256))
            XCTFail("Another account's key must not open the copy")
        } catch let err as FinanceVaultError {
            XCTAssertEqual(err, .decryptionFailed(FinanceVault.otherAccountMessage))
            XCTAssertTrue(FinanceVault.otherAccountMessage.hasPrefix("Эту копию сделал другой аккаунт"))
        }
    }

    func testAccountBackupTamperedBoxFails() throws {
        let key = SymmetricKey(size: .bits256)
        var backup = try FinanceVault.sealAccountBackup(state: sampleState(), accountKey: key)
        var box = try XCTUnwrap(Data(base64Encoded: backup.box))
        box[box.count - 1] ^= 0xFF
        backup.box = box.base64EncodedString()
        XCTAssertThrowsError(try FinanceVault.openAccountBackup(backup, accountKey: key))
    }

    func testOldPasswordFixtureIsDetectedAndStillOpens() async throws {
        struct FixtureData: Decodable {
            let passphrase: String
            let envelope: FinanceVaultEnvelope
        }
        let fixture = try JSONDecoder().decode(FixtureData.self, from: Data(fixtureJson.utf8))
        let text = String(decoding: try JSONEncoder().encode(fixture.envelope), as: UTF8.self)

        XCTAssertEqual(try FinanceVault.backupKind(of: text), .password)
        let envelope = try FinanceVault.readVaultEnvelope(from: text)
        let opened = try await FinanceVault.openFinance(envelope: envelope, password: fixture.passphrase)
        XCTAssertEqual(opened.records, [])
    }

    func testFreshPasswordFileIsDetectedAsPassword() async throws {
        let envelope = try await FinanceVault.sealFinance(state: emptyFinance(), password: "correct-passphrase-8")
        let text = String(decoding: try JSONEncoder().encode(envelope), as: UTF8.self)
        XCTAssertEqual(try FinanceVault.backupKind(of: text), .password)
    }

    func testBackupKindRejectsUnknownFiles() {
        XCTAssertThrowsError(try FinanceVault.backupKind(of: "{\"format\":\"something-else\"}"))
        XCTAssertThrowsError(try FinanceVault.backupKind(of: "{\"format\":\"asan-finance-backup\",\"kind\":\"password\"}"))
        XCTAssertThrowsError(try FinanceVault.backupKind(of: "not json"))
    }

    func testAccountBackupRejectsOtherVersion() throws {
        var backup = try FinanceVault.sealAccountBackup(state: sampleState(), accountKey: SymmetricKey(size: .bits256))
        backup.version = 3
        XCTAssertThrowsError(try FinanceVault.readAccountBackup(from: try json(backup)))
    }
}
