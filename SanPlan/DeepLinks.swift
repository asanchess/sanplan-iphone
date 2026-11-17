import Combine
import Foundation

/// A place inside a section that another screen (Progress, Today, Summary, the mascot) can open exactly.
/// Owner, round 6: «каждая цифра ведёт точно туда, о чём она».
public enum DeepLink: Equatable {
    public enum Period: String, Equatable { case week, month }

    /// Деньги / Обзор, with «Траты по дням» on this period.
    case moneyOverview(Period)
    /// Деньги / План (envelopes).
    case moneyPlan
    /// Деньги / Операции.
    case moneyOperations
    /// Планы / Планы with the «Все» filter (not the last open tab).
    case plansAll
    case habits
    case goals
    /// Будильники (the clock in the Plans header).
    case alarms
    /// Тренировка / История on this period.
    case workoutHistory(Period)
    /// One finished workout in История, by its id.
    case workoutSession(String)
    case notes

    /// The tab this place lives in (`MainTab` raw value).
    public var tabRawValue: Int {
        switch self {
        case .moneyOverview, .moneyPlan, .moneyOperations: return 1
        case .plansAll, .habits, .goals, .alarms: return 2
        case .workoutHistory, .workoutSession: return 3
        case .notes: return 4
        }
    }
}

/// One shared mailbox: a screen calls `DeepLinks.shared.open(.moneyOverview(.month))`;
/// RootView switches the tab and closes sheets, and the section that owns the place shows it and calls `consume()`.
@MainActor
public final class DeepLinks: ObservableObject {
    public static let shared = DeepLinks()
    @Published public private(set) var pending: DeepLink?

    public func open(_ link: DeepLink) { pending = link }

    /// The section calls this after it has shown the place, so a later visit opens normally.
    public func consume() { pending = nil }
}
