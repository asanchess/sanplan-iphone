import Foundation

/// PDFs sent to A-san from «Поделиться» in the bank app. They wait here until «Деньги» reads them, one by one.
/// The copy lives in tmp and is deleted once read: a statement does not stay on the phone outside the vault.
@MainActor
final class StatementInbox: ObservableObject {
    static let shared = StatementInbox()

    @Published private(set) var files: [URL] = []

    private let folder: URL

    init(folder: URL = FileManager.default.temporaryDirectory.appendingPathComponent("StatementInbox", isDirectory: true)) {
        self.folder = folder
    }

    /// Takes a shared file. Returns false for anything that is not a PDF.
    @discardableResult
    func receive(_ url: URL) -> Bool {
        guard url.isFileURL, url.pathExtension.lowercased() == "pdf" else { return false }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            // A short random folder keeps the bank's file name, which the import history shows.
            let place = folder.appendingPathComponent(UUID().uuidString.prefix(8).lowercased(), isDirectory: true)
            try fm.createDirectory(at: place, withIntermediateDirectories: true)
            let copy = place.appendingPathComponent(url.lastPathComponent)
            try fm.copyItem(at: url, to: copy)
            // iOS puts «Open in» copies in Documents/Inbox; ours is in tmp now.
            if url.path.contains("/Documents/Inbox/") { try? fm.removeItem(at: url) }
            files.append(copy)
            return true
        } catch {
            return false
        }
    }

    /// The next file to read, taken off the queue.
    func next() -> URL? {
        files.isEmpty ? nil : files.removeFirst()
    }

    /// Deletes a file this inbox made, after it has been read.
    func discard(_ url: URL) {
        guard url.path.hasPrefix(folder.path) else { return }
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}
