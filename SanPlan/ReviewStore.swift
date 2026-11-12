import Foundation
import Combine

/// Итоги дня и недели, на устройстве. Пока координатор не выдал общий магазин зашифрованной коллекции `reviews`,
/// хранилище — файл на аккаунт (имя — хэш почты, как у денег). Перенос в облако — отдельным шагом.
@MainActor
public final class ReviewStore: ObservableObject {
    struct FileState: Codable, Equatable {
        var version: Int = 1
        var days: [String: ReviewEntry] = [:]
        var weeks: [String: WeekReview] = [:]
        var reminder: ReviewReminderSettings = .standard
    }

    @Published private(set) var file = FileState()
    @Published public private(set) var errorMessage: String?

    public private(set) var owner: FinanceStore.Owner = .none
    private let directory: URL
    private let fileManager: FileManager
    private let now: () -> Int64
    private var url: URL?

    public init(directory: URL? = nil, fileManager: FileManager = .default, now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.fileManager = fileManager
        self.now = now
        let base = directory ?? (fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())).appendingPathComponent("ARNA", isDirectory: true).appendingPathComponent("reviews", isDirectory: true)
        self.directory = base
        try? fileManager.createDirectory(at: base, withIntermediateDirectories: true)
    }

    // MARK: Account

    /// Opens the reviews of whoever is signed in now; the same owner again changes nothing. Signed out: nothing loaded.
    public func switchOwner(to next: FinanceStore.Owner) {
        guard next != owner else { return }
        owner = next
        errorMessage = nil
        file = FileState()
        switch next {
        case .none: url = nil
        case .device: url = directory.appendingPathComponent("device.json")
        case .account(let email): url = directory.appendingPathComponent(FinanceStore.accountFolderName(email) + ".json")
        }
        load()
    }

    // MARK: Reading (DOMAINS.md §2: ReviewStore.day(_:))

    public func day(_ day: String) -> ReviewEntry? { file.days[day] }
    public func week(containing day: String) -> WeekReview? { file.weeks[ReviewCalendar.weekStart(day)] }
    public func previousWeek(before day: String) -> WeekReview? { file.weeks[ReviewCalendar.addDays(ReviewCalendar.weekStart(day), -7)] }
    public var reminder: ReviewReminderSettings { file.reminder }
    public var reviewedDays: [String] { file.days.keys.sorted() }

    /// Days with a saved review, for the streak.
    public func activityDays(from: String, to: String) -> [String] {
        file.days.keys.filter { $0 >= from && $0 <= to }.sorted()
    }

    // MARK: Writing

    @discardableResult
    public func saveDay(_ day: String, mood: Int?, text: String) -> Bool {
        guard url != nil else { return false }
        guard let entry = ReviewEntry.make(day: day, mood: mood, text: text, now: now()) else { return false }
        var next = file
        next.days[day] = entry
        return commit(next)
    }

    @discardableResult
    public func deleteDay(_ day: String) -> Bool {
        guard url != nil, file.days[day] != nil else { return false }
        var next = file
        next.days[day] = nil
        return commit(next)
    }

    @discardableResult
    public func saveWeek(containing day: String, ratings: [String: Int]) -> Bool {
        guard url != nil, let week = WeekReview.make(containing: day, ratings: ratings, now: now()) else { return false }
        var next = file
        next.weeks[week.weekStart] = week
        return commit(next)
    }

    @discardableResult
    public func setReminder(_ settings: ReviewReminderSettings) -> Bool {
        guard url != nil else { return false }
        var next = file
        next.reminder = settings
        return commit(next)
    }

    // MARK: Disk

    private func commit(_ next: FileState) -> Bool {
        guard let url else { return false }
        do {
            let data = try JSONEncoder().encode(next)
            try data.write(to: url, options: .atomic)
            file = next
            errorMessage = nil
            return true
        } catch {
            errorMessage = "Не удалось сохранить итоги на устройстве."
            return false
        }
    }

    private func load() {
        guard let url, fileManager.fileExists(atPath: url.path) else { return }
        guard let data = try? Data(contentsOf: url), let decoded = try? JSONDecoder().decode(FileState.self, from: data) else {
            // Keep the unreadable file beside the new one instead of overwriting it.
            let aside = url.deletingPathExtension().appendingPathExtension("unreadable-\(now()).json")
            try? fileManager.moveItem(at: url, to: aside)
            errorMessage = "Файл итогов не прочитан; он сохранён рядом, новые итоги пишутся в чистый файл."
            return
        }
        file = decoded
    }
}
