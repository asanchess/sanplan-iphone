import Foundation

// MARK: - «Недавно удалённые»

/// Deleted notes keep their (encrypted) text as tombstones, so they are listed in Профиль → Недавно удалённые
/// for 30 days and can be brought back on any device of the account.
extension NotesStore: RecentlyDeletedSource {
    private static let itemPrefix = "note:"

    var deletedItems: [DeletedItem] {
        all.values
            .filter { $0.deleted && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map {
                DeletedItem(
                    id: Self.itemPrefix + $0.id,
                    title: "Заметка «\($0.title)»",
                    section: .notes,
                    deletedAt: Date(timeIntervalSince1970: TimeInterval($0.updatedAt) / 1000)
                )
            }
    }

    func restoreDeleted(id: String) { restore(Self.noteID(id)) }

    func purgeDeleted(id: String) { purge(Self.noteID(id)) }

    private static func noteID(_ itemID: String) -> String {
        itemID.hasPrefix(itemPrefix) ? String(itemID.dropFirst(itemPrefix.count)) : itemID
    }
}

/// List and editor actions that offer the shared «Отменить».
@MainActor
enum NotesActions {
    static func delete(_ id: String, in store: NotesStore) {
        guard let note = store.note(id) else { return }
        store.delete(id)
        RecentlyDeleted.shared.register(store)
        UndoCenter.shared.show("Заметка «\(note.title)» удалена") { [weak store] in
            store?.restore(id)
        }
    }
}

// MARK: - Screenshot demo data

#if DEBUG
/// Debug screenshots only (`--screenshot-demo-data`): made-up notes shown from memory, never sealed into the vault.
@MainActor
enum NotesDemo {
    /// The note `notes-editor` opens: a checklist, so the reading mode with boxes is shown.
    static let editorNoteID = "demo-shopping"
    private static var applied = false

    static func apply(to store: NotesStore, now: Date = Date()) {
        guard !applied else { return }
        applied = true
        let calendar = Calendar.current
        func stamp(daysAgo: Int, _ hour: Int, _ minute: Int) -> Int64 {
            let day = calendar.date(byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: now)) ?? now
            let moment = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
            return Int64(min(moment, now.addingTimeInterval(-600)).timeIntervalSince1970 * 1000)
        }
        func note(_ id: String, _ text: String, _ updated: Int64, pinned: Bool = false) -> Note {
            Note(id: id, text: text, pinned: pinned, createdAt: updated - 3_600_000, updatedAt: updated)
        }
        store.showDemo([
            note("demo-week", "Идеи на неделю\nПересобрать план тренировок, созвон в среду, подарок маме до пятницы.",
                 stamp(daysAgo: 0, 9, 12), pinned: true),
            note(editorNoteID, "Список покупок\n- [x] Курица\n- [x] рис\n- [x] творог\n- [ ] бананы\n- [ ] овсянка",
                 stamp(daysAgo: 0, 8, 40)),
            note("demo-gym", "Мысли после зала\nЖим пошёл легче, в четверг добавить 2,5 кг.", stamp(daysAgo: 1, 20, 5)),
            note("demo-books", "Книги\nЧто прочитать до конца года: «Пикник на обочине», «Стоунер».", stamp(daysAgo: 5, 22, 30)),
            note("demo-gift", "Подарок маме\nПлед и чайный набор. Узнать у сестры, какой цвет она любит.", stamp(daysAgo: 8, 13, 15)),
            note("demo-trip", "Отпуск в марте\nСравнить билеты в Тбилиси и Казань, отпуск согласовать до 1 декабря.", stamp(daysAgo: 11, 19, 0)),
            note("demo-balcony", "Ремонт балкона\nЗамерить окна, спросить про утепление, бюджет до 150 тыс.", stamp(daysAgo: 16, 11, 45)),
        ])
    }
}
#endif
