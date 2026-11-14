import Foundation
import Combine

/// Итоги дня и недели и время напоминания. Всё — в зашифрованной коллекции `reviews` (политика `.copy`: строка итога
/// не должна теряться при правке одного вечера на двух устройствах; копии сводятся в основную запись):
/// день — `r-ГГГГ-ММ-ДД`, неделя — `w-<понедельник>`, время напоминания — `s-reminder`. Пока хранилище закрыто —
/// в файле на аккаунт (имя — хэш почты, как у денег); открывшись, коллекция забирает локальные данные, а перед этим
/// файл копируется в `*.pre-sync-backup.json` (решение 4 в docs/ONE-APP-PLAN.md). Файл хранит и последнее известное
/// время напоминания, чтобы уведомление не сбивалось, пока ключ ещё не открыт.
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
    private var vault: VaultCollection<ReviewDayRecord>?
    private var vaultSub: AnyCancellable?
    private var settling = false
    /// The reminder last handed to `onReminderChanged` (or set here), to notice a change that came from another device.
    private var lastReminder: ReviewReminderSettings?
    /// Another device changed the reminder time: the local notification has to follow.
    public var onReminderChanged: ((ReviewReminderSettings) -> Void)?

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
        lastReminder = nil
        switch next {
        case .none: url = nil
        case .device: url = directory.appendingPathComponent("device.json")
        case .account(let email): url = directory.appendingPathComponent(FinanceStore.accountFolderName(email) + ".json")
        }
        load()
    }

    /// The account's encrypted collection, or nil while the vault is locked. The creator keeps it attached to the account.
    public func setCollection(_ next: VaultCollection<ReviewDayRecord>?) {
        guard next !== vault else { settle(); return }
        vaultSub = nil
        vault = next
        if let next {
            vaultSub = next.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in
                self?.objectWillChange.send()
                self?.settle()
            }
        }
        objectWillChange.send()
        settle()
    }

    private var vaultReady: Bool { vault?.isAvailable == true }

    private func remoteDays() -> [String: MergedReviewDay] {
        guard let vault, vault.isAvailable else { return [:] }
        return ReviewVault.merge(vault.items)
    }

    private func remoteWeeks() -> [String: MergedReviewWeek] {
        guard let vault, vault.isAvailable else { return [:] }
        return ReviewVault.mergeWeeks(vault.items)
    }

    private func remoteReminder() -> MergedReviewReminder? {
        guard let vault, vault.isAvailable else { return nil }
        return ReviewVault.mergeReminder(vault.items)
    }

    /// Local file < collection (when newer).
    private func dayMap() -> [String: ReviewEntry] {
        var map = file.days
        for (day, merged) in remoteDays() where map[day] == nil || merged.entry.updatedAt >= map[day]!.updatedAt { map[day] = merged.entry }
        return map
    }

    private func weekMap() -> [String: WeekReview] {
        var map = file.weeks
        for (start, merged) in remoteWeeks() where map[start] == nil || merged.week.updatedAt >= map[start]!.updatedAt { map[start] = merged.week }
        return map
    }

    /// Before the first move of local data into the account: a copy of the file, kept beside it, never overwritten.
    private func backupLocalOnce() {
        guard let url, fileManager.fileExists(atPath: url.path) else { return }
        let backup = url.deletingPathExtension().appendingPathExtension("pre-sync-backup.json")
        guard !fileManager.fileExists(atPath: backup.path) else { return }
        try? fileManager.copyItem(at: url, to: backup)
    }

    /// Local data goes into the collection once (idempotent by id); copies made by conflicts are merged into the primary record.
    private func settle() {
        guard !settling, let vault, vault.isAvailable, url != nil else { return }
        settling = true
        defer { settling = false }
        let remoteWeekNow = remoteWeeks()
        let remoteReminderNow = remoteReminder()
        let moveReminder = remoteReminderNow == nil && file.reminder != .standard
        if !file.days.isEmpty || !file.weeks.isEmpty || moveReminder { backupLocalOnce() }
        var next = file
        if !file.days.isEmpty {
            _ = vault.importMany(file.days.values.map { (id: ReviewVault.recordID(for: $0.day), data: ReviewDayRecord(day: $0.day, mood: $0.mood, text: $0.text), updatedAt: $0.updatedAt) })
            next.days = [:]
        }
        if !file.weeks.isEmpty {
            for (start, week) in file.weeks where remoteWeekNow[start].map({ $0.week.updatedAt < week.updatedAt }) ?? true {
                vault.put(ReviewVault.weekRecordID(for: start), ReviewDayRecord(week: week), updatedAt: week.updatedAt)
            }
            next.weeks = [:]
        }
        if moveReminder {
            vault.put(ReviewVault.reminderRecordID, ReviewDayRecord(reminder: file.reminder))
        } else if let remote = remoteReminderNow, remote.settings != file.reminder {
            next.reminder = remote.settings
        }
        if next != file { _ = commit(next) }
        for (day, merged) in remoteDays() {
            let primary = ReviewVault.recordID(for: day)
            let record = ReviewDayRecord(day: day, mood: merged.entry.mood, text: merged.entry.text)
            if merged.ids == [primary], vault.item(primary)?.data == record { continue }
            vault.put(primary, record)
            for id in merged.ids where id != primary { vault.remove(id) }
        }
        for (start, merged) in remoteWeeks() {
            let primary = ReviewVault.weekRecordID(for: start)
            let record = ReviewDayRecord(week: merged.week)
            if merged.ids == [primary], vault.item(primary)?.data == record { continue }
            vault.put(primary, record, updatedAt: merged.week.updatedAt)
            for id in merged.ids where id != primary { vault.remove(id) }
        }
        if let merged = remoteReminder() {
            let primary = ReviewVault.reminderRecordID
            let record = ReviewDayRecord(reminder: merged.settings)
            if !(merged.ids == [primary] && vault.item(primary)?.data == record) {
                vault.put(primary, record, updatedAt: merged.updatedAt)
                for id in merged.ids where id != primary { vault.remove(id) }
            }
        }
        noticeReminderChange()
    }

    private func noticeReminderChange() {
        let effective = reminder
        defer { lastReminder = effective }
        guard owner != .none, let last = lastReminder, last != effective else { return }
        onReminderChanged?(effective)
    }

    // MARK: Reading (DOMAINS.md §2: ReviewStore.day(_:))

    public func day(_ day: String) -> ReviewEntry? { dayMap()[day] }
    public func week(containing day: String) -> WeekReview? { weekMap()[ReviewCalendar.weekStart(day)] }
    public func previousWeek(before day: String) -> WeekReview? { weekMap()[ReviewCalendar.addDays(ReviewCalendar.weekStart(day), -7)] }
    /// Every saved week review, oldest first (the spheres screen in Plans).
    public var weeks: [WeekReview] { weekMap().values.sorted { $0.weekStart < $1.weekStart } }
    /// The account's reminder time; the file's copy of it while the collection is closed.
    public var reminder: ReviewReminderSettings { remoteReminder()?.settings ?? file.reminder }
    public var reviewedDays: [String] { dayMap().keys.sorted() }

    /// Days with a saved review, for the streak.
    public func activityDays(from: String, to: String) -> [String] {
        dayMap().keys.filter { $0 >= from && $0 <= to }.sorted()
    }

    // MARK: Writing

    @discardableResult
    public func saveDay(_ day: String, mood: Int?, text: String) -> Bool {
        guard url != nil else { return false }
        guard let entry = ReviewEntry.make(day: day, mood: mood, text: text, now: now()) else { return false }
        if let vault, vault.isAvailable {
            guard vault.put(ReviewVault.recordID(for: day), ReviewDayRecord(day: day, mood: entry.mood, text: entry.text), updatedAt: entry.updatedAt) != nil else { return false }
            if file.days[day] != nil {
                var cleaned = file
                cleaned.days[day] = nil
                _ = commit(cleaned)
            }
            return true
        }
        var next = file
        next.days[day] = entry
        return commit(next)
    }

    @discardableResult
    public func deleteDay(_ day: String) -> Bool {
        guard url != nil, dayMap()[day] != nil else { return false }
        if let ids = remoteDays()[day]?.ids, let vault {
            for id in ids { vault.remove(id) }
        }
        guard file.days[day] != nil else { return true }
        var next = file
        next.days[day] = nil
        return commit(next)
    }

    @discardableResult
    public func saveWeek(containing day: String, ratings: [String: Int]) -> Bool {
        guard url != nil, let week = WeekReview.make(containing: day, ratings: ratings, now: now()) else { return false }
        if let vault, vault.isAvailable {
            guard vault.put(ReviewVault.weekRecordID(for: week.weekStart), ReviewDayRecord(week: week), updatedAt: week.updatedAt) != nil else { return false }
            if file.weeks[week.weekStart] != nil {
                var cleaned = file
                cleaned.weeks[week.weekStart] = nil
                _ = commit(cleaned)
            }
            return true
        }
        var next = file
        next.weeks[week.weekStart] = week
        return commit(next)
    }

    @discardableResult
    public func setReminder(_ settings: ReviewReminderSettings) -> Bool {
        guard url != nil else { return false }
        lastReminder = settings
        if let vault, vault.isAvailable {
            guard vault.put(ReviewVault.reminderRecordID, ReviewDayRecord(reminder: settings)) != nil else { return false }
        }
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
