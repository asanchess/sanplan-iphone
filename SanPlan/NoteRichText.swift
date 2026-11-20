import Foundation

/// Lists and headings inside a note, kept as plain text so the web and old notes read the same:
/// «- [ ] » / «- [x] » checkbox, «• » bullet, «1. » numbered item, «# » heading.
/// The editor draws them (circles, dots, numbers, big text); this type does the text logic only.
public enum NoteLineStyle: Equatable, Sendable {
    case plain
    case heading
    case bullet
    case number(Int)
    case check(Bool)

    var isList: Bool {
        switch self {
        case .bullet, .number, .check: return true
        case .plain, .heading: return false
        }
    }
}

public struct NoteLine: Equatable, Sendable {
    public var style: NoteLineStyle
    public var body: String

    public init(_ style: NoteLineStyle, _ body: String) {
        self.style = style
        self.body = body
    }
}

/// The buttons on the keyboard bar.
public enum NoteListTool: String, CaseIterable, Sendable {
    case check, number, bullet, heading
}

/// A cursor inside the body of a line (after its marker).
public struct NoteCursor: Equatable, Sendable {
    public var line: Int
    public var column: Int
    public init(line: Int, column: Int) {
        self.line = line
        self.column = column
    }
}

public enum NoteLists {
    // MARK: Text ↔ lines

    public static func parse(_ text: String) -> [NoteLine] {
        text.components(separatedBy: "\n").map(parseLine)
    }

    public static func parseLine(_ raw: String) -> NoteLine {
        let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
        let lead = line.drop { $0 == " " }
        if let done = NoteText.checkbox(line) {
            return NoteLine(.check(done), NoteText.displayLine(line))
        }
        if lead.hasPrefix("# ") { return NoteLine(.heading, String(lead.dropFirst(2))) }
        if lead.hasPrefix("• ") { return NoteLine(.bullet, String(lead.dropFirst(2))) }
        if let (number, rest) = numbered(String(lead)) { return NoteLine(.number(number), rest) }
        return NoteLine(.plain, line)
    }

    /// «12. текст» → (12, «текст»); at most three digits, so «2024. год» stays a plain line.
    static func numbered(_ line: String) -> (Int, String)? {
        let digits = line.prefix { $0.isASCII && $0.isNumber }
        guard (1...3).contains(digits.count), let number = Int(digits) else { return nil }
        let after = line.dropFirst(digits.count)
        guard after.hasPrefix(". ") else { return nil }
        return (number, String(after.dropFirst(2)))
    }

    public static func marker(_ style: NoteLineStyle) -> String {
        switch style {
        case .plain: return ""
        case .heading: return "# "
        case .bullet: return "• "
        case .number(let n): return "\(n). "
        case .check(let done): return done ? NoteText.checked : NoteText.unchecked
        }
    }

    public static func text(_ lines: [NoteLine]) -> String {
        lines.map { marker($0.style) + $0.body }.joined(separator: "\n")
    }

    // MARK: Return

    /// Return at `cursor`: a list item continues on the next line (numbers count up); Return on an empty
    /// item ends the list instead, like the iPhone. A heading's next line is plain text.
    public static func pressReturn(_ lines: [NoteLine], at cursor: NoteCursor) -> (lines: [NoteLine], cursor: NoteCursor) {
        guard lines.indices.contains(cursor.line) else { return (lines, cursor) }
        var lines = lines
        let current = lines[cursor.line]
        // Columns count UTF-16 units, like UITextView ranges.
        let body = current.body as NSString
        let column = min(max(cursor.column, 0), body.length)
        if current.style.isList, current.body.trimmingCharacters(in: .whitespaces).isEmpty {
            lines[cursor.line] = NoteLine(.plain, "")
            return (renumbered(lines), NoteCursor(line: cursor.line, column: 0))
        }
        var cut = column
        if column > 0 {
            // Never split an emoji or a letter with its accent in two.
            let split = body.rangeOfComposedCharacterSequence(at: column - 1)
            if column < NSMaxRange(split) { cut = split.location }
        }
        let head = body.substring(to: cut)
        let tail = body.substring(from: cut)
        let nextStyle: NoteLineStyle
        switch current.style {
        case .plain: nextStyle = .plain
        case .heading: nextStyle = column == 0 ? .heading : .plain
        case .bullet: nextStyle = .bullet
        case .number(let n): nextStyle = .number(n + 1)
        case .check: nextStyle = .check(false)
        }
        if current.style == .heading, column == 0 {
            // Return at the start of a heading pushes it down and leaves an empty plain line above.
            lines[cursor.line] = NoteLine(.plain, "")
            lines.insert(NoteLine(.heading, tail), at: cursor.line + 1)
            return (lines, NoteCursor(line: cursor.line + 1, column: 0))
        }
        lines[cursor.line].body = head
        lines.insert(NoteLine(nextStyle, tail), at: cursor.line + 1)
        return (renumbered(lines), NoteCursor(line: cursor.line + 1, column: 0))
    }

    // MARK: Toolbar

    /// Applies a keyboard-bar button to the lines `range`. If every line already has that style it is
    /// removed (the button works as a switch); otherwise the lines take it, replacing any other marker.
    public static func apply(_ tool: NoteListTool, to lines: [NoteLine], range: ClosedRange<Int>) -> [NoteLine] {
        let range = range.clamped(to: 0...max(lines.count - 1, 0))
        guard !lines.isEmpty else { return lines }
        var lines = lines
        let allHave = range.allSatisfy { has(tool, lines[$0].style) }
        var next = startNumber(before: range.lowerBound, in: lines)
        for index in range {
            if allHave {
                lines[index].style = .plain
            } else {
                switch tool {
                case .check:
                    if case .check = lines[index].style { continue }
                    lines[index].style = .check(false)
                case .bullet: lines[index].style = .bullet
                case .heading: lines[index].style = .heading
                case .number:
                    lines[index].style = .number(next)
                    next += 1
                }
            }
        }
        return renumbered(lines)
    }

    static func has(_ tool: NoteListTool, _ style: NoteLineStyle) -> Bool {
        switch (tool, style) {
        case (.check, .check), (.bullet, .bullet), (.heading, .heading), (.number, .number): return true
        default: return false
        }
    }

    /// A numbered item right above continues its count.
    static func startNumber(before index: Int, in lines: [NoteLine]) -> Int {
        guard index > 0, case .number(let n) = lines[index - 1].style else { return 1 }
        return n + 1
    }

    /// Each run of numbered lines counts on from its first number, so inserting or removing an item keeps
    /// the order 1, 2, 3 without gaps.
    public static func renumbered(_ lines: [NoteLine]) -> [NoteLine] {
        var lines = lines
        var expected: Int?
        for index in lines.indices {
            guard case .number(let n) = lines[index].style else { expected = nil; continue }
            if let value = expected {
                lines[index].style = .number(value)
                expected = value + 1
            } else {
                expected = n + 1
            }
        }
        return lines
    }

    public static func toggleCheck(_ lines: [NoteLine], line index: Int) -> [NoteLine] {
        guard lines.indices.contains(index), case .check(let done) = lines[index].style else { return lines }
        var lines = lines
        lines[index].style = .check(!done)
        return lines
    }

    /// The note's first meaningful line without any marker, for lists and titles.
    public static func plainLine(_ line: String) -> String {
        if NotePhotos.id(in: line) != nil { return "Фото" }
        let parsed = parseLine(line.trimmingCharacters(in: .whitespaces))
        switch parsed.style {
        case .plain: return parsed.body
        default: return parsed.body.trimmingCharacters(in: .whitespaces)
        }
    }
}
