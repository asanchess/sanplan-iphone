import Foundation

/// The text in the Plans and Money input fields. Lives above the tabs, so a draft and a running dictation survive tab switches.
@MainActor
public final class InputDrafts: ObservableObject {
    public enum Target: String, CaseIterable {
        case plans, money
    }

    @Published public private(set) var plans: String = ""
    @Published public private(set) var money: String = ""

    /// The text that was in the field when dictation started; live speech is appended after it.
    private var dictationBase: [Target: String] = [:]
    /// The recogniser's last transcript, to notice when it starts over after a pause.
    private var lastSpeech: [Target: String] = [:]

    public init() {}

    public func text(_ target: Target) -> String {
        switch target {
        case .plans: return plans
        case .money: return money
        }
    }

    /// A user edit. It ends dictation into this field, so later speech results never overwrite what was typed.
    public func edit(_ text: String, for target: Target) {
        dictationBase[target] = nil
        lastSpeech[target] = nil
        set(text, for: target)
    }

    public func isDictating(into target: Target) -> Bool {
        dictationBase[target] != nil
    }

    public func beginDictation(into target: Target) {
        dictationBase[target] = text(target)
        lastSpeech[target] = nil
    }

    /// The recogniser's transcript so far for this dictation. Ignored once dictation into the field has ended.
    /// After a pause the recogniser may start a fresh transcript; the words before the pause then stay in the field.
    public func applySpeech(_ transcript: String, to target: Target) {
        guard var base = dictationBase[target] else { return }
        if let previous = lastSpeech[target], Self.startsOver(previous: previous, next: transcript) {
            base = Self.compose(base: base, speech: previous)
            dictationBase[target] = base
        }
        lastSpeech[target] = transcript
        set(Self.compose(base: base, speech: transcript), for: target)
    }

    public func endDictation(into target: Target) {
        dictationBase[target] = nil
        lastSpeech[target] = nil
    }

    /// Whether a new transcript replaces the previous one instead of extending or correcting it. The recogniser
    /// revises a transcript from its start, so a new phrase is one that begins differently. A grown or corrected
    /// first word («при» → «привет», «тут» → «тот хлеб») is not a new start.
    public static func startsOver(previous: String, next: String) -> Bool {
        let old = words(previous)
        let new = words(next)
        guard let oldFirst = old.first, let newFirst = new.first else { return false }
        if oldFirst.hasPrefix(newFirst) || newFirst.hasPrefix(oldFirst) {
            // The same opening word: only a much shorter transcript is a new phrase.
            return next.count < previous.count && old.count >= 3 && new.count * 3 <= old.count
        }
        // A different opening word. While only one word was heard, a similar word may still be its correction.
        return oldFirst.first != newFirst.first || old.count >= 2
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.letters.union(.decimalDigits).inverted)
            .filter { !$0.isEmpty }
    }

    /// Hands over the field's text for parsing and empties the field.
    public func take(_ target: Target) -> String {
        let value = text(target).trimmingCharacters(in: .whitespacesAndNewlines)
        dictationBase[target] = nil
        lastSpeech[target] = nil
        set("", for: target)
        return value
    }

    public func clear(_ target: Target) {
        dictationBase[target] = nil
        lastSpeech[target] = nil
        set("", for: target)
    }

    public static func compose(base: String, speech: String) -> String {
        let spoken = speech.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spoken.isEmpty else { return base }
        let trimmedBase = base.trimmingCharacters(in: .whitespaces)
        guard !trimmedBase.isEmpty else { return spoken }
        let separator = trimmedBase.hasSuffix("\n") ? "" : " "
        return trimmedBase + separator + spoken
    }

    private func set(_ text: String, for target: Target) {
        switch target {
        case .plans: if plans != text { plans = text }
        case .money: if money != text { money = text }
        }
    }
}
