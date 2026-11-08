import Foundation
import Combine

@MainActor
public final class FinanceStore: ObservableObject {
    @Published public private(set) var state: FinanceState = emptyFinance()
    @Published public private(set) var summary: FinanceSummary? = nil
    @Published public var notice: String? = nil
    @Published public var isBusy: Bool = false

    private var isUnavailable = false
    private let fileManager: FileManager
    private let storageURL: URL
    private let corruptFolderURL: URL

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager

        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let arnaDir = appSupport.appendingPathComponent("ARNA", isDirectory: true)

        try? fileManager.createDirectory(at: arnaDir, withIntermediateDirectories: true, attributes: nil)

        self.storageURL = arnaDir.appendingPathComponent("finance_state.json")
        self.corruptFolderURL = arnaDir.appendingPathComponent("corrupt", isDirectory: true)

        loadInitialState()
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

    public func reset() {
        self.state = emptyFinance()
        self.summary = nil
        self.notice = nil
        try? fileManager.removeItem(at: storageURL)
        isUnavailable = false
    }

    // MARK: - Persistence

    private func updateState(_ newState: FinanceState, today: String) throws {
        reloadIfUnavailable()
        if isUnavailable {
            throw FinanceVaultError.decryptionFailed("Финансы недоступны, пока телефон заблокирован.")
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
        if isUnavailable { loadInitialState() }
    }

    private func loadInitialState() {
        guard fileManager.fileExists(atPath: storageURL.path) else {
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
            self.state = clean
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
