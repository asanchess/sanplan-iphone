import SwiftUI

/// The calendar day the app calls «сегодня», as "yyyy-MM-dd".
///
/// It turns over at midnight, on a time-zone or clock change and when the app comes back to the front,
/// so a phone that kept ARNA open overnight does not show yesterday in the morning.
public enum DayTurn {
    /// The day a screen should show after the turn: it follows the new day only if it was showing the old «сегодня».
    /// A day the person picked on purpose (tomorrow, last Friday) stays.
    public static func follow(selected: String, oldToday: String, newToday: String) -> String {
        selected == oldToday ? newToday : selected
    }

    /// The weekday a screen should show after the turn, by the same rule. 1 = Monday … 7 = Sunday.
    public static func follow(weekday: Int, oldToday: Int, newToday: Int) -> Int {
        weekday == oldToday ? newToday : weekday
    }
}

public extension EnvironmentValues {
    /// Today's "yyyy-MM-dd". A screen that reads it is drawn again when the day turns over.
    @Entry var dayKey: String = PlanDomain.today()
}
