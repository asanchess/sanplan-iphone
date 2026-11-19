import Foundation

/// PDF statements shared to A-san («Поделиться» in the bank's app, or the Shortcuts action), waiting until money is
/// open: FinanceStore.takeInStatements loads each through the same pipeline as the «Деньги» import, without the preview.
/// On the phone only, protected like the money file.
public struct BankStatementInbox {
    public let folder: URL
    private let fileManager: FileManager
    /// A year of Kaspi statement is well under this; anything larger is not a statement.
    static let maxBytes = 20 * 1024 * 1024

    public init(folder: URL, fileManager: FileManager = .default) {
        self.folder = folder
        self.fileManager = fileManager
    }

    /// Next to the Apple Pay inbox, the same folder as `FinanceStore.bankStatementInbox`.
    public static func standard(fileManager: FileManager = .default) -> BankStatementInbox {
        let feed = BankFeedInbox.standard(fileManager: fileManager).folder
        return BankStatementInbox(folder: feed.deletingLastPathComponent().appendingPathComponent("bank-statement-inbox", isDirectory: true),
                                  fileManager: fileManager)
    }

    public enum InboxError: LocalizedError {
        case tooLarge
        public var errorDescription: String? { "Файл слишком большой для выписки." }
    }

    /// The file's own name is kept after the arrival time, so the list of statements shows it.
    public func add(data: Data, name: String) throws {
        guard data.count <= Self.maxBytes else { throw InboxError.tooLarge }
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: nil)
        let stamp = String(format: "%013.0f", Date().timeIntervalSince1970 * 1000)
        let tag = String(UUID().uuidString.prefix(8)).lowercased()
        let url = folder.appendingPathComponent("\(stamp)-\(tag)-\(Self.safe(name))")
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// A PDF opened in A-san. The copy iOS put in the app's Documents/Inbox is removed once it is taken.
    public func add(fileAt url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        try add(data: Data(contentsOf: url), name: url.lastPathComponent)
        if url.deletingLastPathComponent().lastPathComponent == "Inbox" { try? fileManager.removeItem(at: url) }
    }

    /// Waiting statements, oldest first.
    public func pending() -> [URL] {
        guard let urls = try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return [] }
        return urls.filter { $0.pathExtension.lowercased() == "pdf" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// «1731…-ab12cd34-Выписка.pdf» → «Выписка.pdf».
    public static func originalName(_ url: URL) -> String {
        let parts = url.lastPathComponent.split(separator: "-", maxSplits: 2)
        return parts.count == 3 ? String(parts[2]) : url.lastPathComponent
    }

    public func remove(_ url: URL) {
        try? fileManager.removeItem(at: url)
    }

    public func clear() {
        try? fileManager.removeItem(at: folder)
    }

    private static func safe(_ name: String) -> String {
        let base = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        let trimmed = String(base.prefix(80))
        return trimmed.lowercased().hasSuffix(".pdf") ? trimmed : (trimmed.isEmpty ? "statement" : trimmed) + ".pdf"
    }
}
