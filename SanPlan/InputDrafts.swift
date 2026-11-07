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
        set(text, for: target)
    }

    public func isDictating(into target: Target) -> Bool {
        dictationBase[target] != nil
    }

    public func beginDictation(into target: Target) {
        dictationBase[target] = text(target)
    }

    /// The recogniser's full transcript so far for this dictation. Ignored once dictation into the field has ended.
    public func applySpeech(_ transcript: String, to target: Target) {
        guard let base = dictationBase[target] else { return }
        set(Self.compose(base: base, speech: transcript), for: target)
    }

    public func endDictation(into target: Target) {
        dictationBase[target] = nil
    }

    /// Hands over the field's text for parsing and empties the field.
    public func take(_ target: Target) -> String {
        let value = text(target).trimmingCharacters(in: .whitespacesAndNewlines)
        dictationBase[target] = nil
        set("", for: target)
        return value
    }

    public func clear(_ target: Target) {
        dictationBase[target] = nil
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
