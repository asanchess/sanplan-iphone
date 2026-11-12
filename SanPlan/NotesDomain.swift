import Foundation

/// A note: something to keep in mind, not a task. Text with optional checklist lines «- [ ] » / «- [x] ».
public struct Note: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var text: String
    public var pinned: Bool
    public var createdAt: Int64
    public var updatedAt: Int64
    public var deleted: Bool

    public init(id: String = Note.newID(), text: String, pinned: Bool = false, createdAt: Int64, updatedAt: Int64? = nil, deleted: Bool = false) {
        self.id = id
        self.text = text
        self.pinned = pinned
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.deleted = deleted
    }

    public static func newID() -> String { UUID().uuidString.lowercased() }

    /// First non-empty line without checklist marks, for lists.
    public var title: String {
        lines.first.map(NoteText.displayLine) ?? ""
    }

    /// The line after the title, for one line of preview.
    public var preview: String {
        lines.dropFirst().first.map(NoteText.displayLine) ?? ""
    }

    private var lines: [String] {
        text.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    public var checklistProgress: (done: Int, total: Int)? {
        let items = text.split(separator: "\n").compactMap { NoteText.checkbox(String($0)) }
        guard !items.isEmpty else { return nil }
        return (items.filter { $0 }.count, items.count)
    }

    public func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return q.isEmpty || text.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}

/// The encrypted record body (E2E-SYNC.md): {v, updatedAt, deleted?, data}.
struct NoteRecord: Codable {
    struct Data: Codable {
        var text: String
        var pinned: Bool
        var createdAt: Int64
    }
    var v: Int
    var updatedAt: Int64
    var deleted: Bool?
    var data: Data

    init(_ note: Note) {
        v = 1
        updatedAt = note.updatedAt
        deleted = note.deleted ? true : nil
        data = Data(text: note.text, pinned: note.pinned, createdAt: note.createdAt)
    }

    func note(id: String) -> Note {
        Note(id: id, text: data.text, pinned: data.pinned, createdAt: data.createdAt, updatedAt: updatedAt, deleted: deleted ?? false)
    }
}

public enum NoteText {
    static let unchecked = "- [ ] "
    static let checked = "- [x] "

    /// nil for a plain line, otherwise whether the box is ticked.
    public static func checkbox(_ line: String) -> Bool? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix(unchecked) || trimmed == "- [ ]" { return false }
        if trimmed.lowercased().hasPrefix(checked) || trimmed.lowercased() == "- [x]" { return true }
        return nil
    }

    public static func displayLine(_ line: String) -> String {
        guard checkbox(line) != nil else { return line }
        return String(line.trimmingCharacters(in: .whitespaces).dropFirst(5)).trimmingCharacters(in: .whitespaces)
    }

    /// Ticks or unticks the checklist line at `index`; other lines stay byte-for-byte the same.
    public static func toggle(_ text: String, line index: Int) -> String {
        var lines = text.components(separatedBy: "\n")
        guard lines.indices.contains(index), let done = checkbox(lines[index]) else { return text }
        let indent = String(lines[index].prefix { $0 == " " })
        lines[index] = indent + (done ? unchecked : checked) + displayLine(lines[index])
        return lines.joined(separator: "\n")
    }

    /// What a captured phrase could become besides a note. Only offered, never applied silently.
    public struct Hints: Equatable {
        public var looksLikePlan: Bool
        public var looksLikeExpense: Bool
    }

    public static func hints(_ text: String) -> Hints {
        let lower = text.lowercased()
        let time = lower.range(of: #"\b([01]?\d|2[0-3])[:.][0-5]\d\b"#, options: .regularExpression) != nil
        let dayWords = ["сегодня", "завтра", "послезавтра", "понедельник", "вторник", "сред", "четверг", "пятниц", "суббот", "воскресен", "утром", "вечером", " в ", "напомни"]
        let hasDay = dayWords.contains { word in
            word == " в " ? lower.range(of: #"\bв\s+\d{1,2}\b"#, options: .regularExpression) != nil : lower.contains(word)
        }
        let money = lower.range(of: #"\d[\d\s]*\s*(₸|тг|тенге|тыс|к\b|руб|₽|\$)"#, options: .regularExpression) != nil
        let spendWords = ["потратил", "потратила", "купил", "купила", "заплатил", "заплатила", "оплатил", "оплатила"]
        let spent = spendWords.contains { lower.contains($0) } && lower.range(of: #"\d"#, options: .regularExpression) != nil
        return Hints(looksLikePlan: time || hasDay, looksLikeExpense: money || spent)
    }
}
