import Foundation

extension NotesStore {
    /// Days (YYYY-MM-DD, owner's time zone) on which a note was written or changed; deleted notes do not count.
    /// DOMAINS.md §2: `NotesStore.activityDays(from:to:)`, used by the streak.
    public func activityDays(from: String, to: String, timeZone: String = PlanDomain.defaultTimeZone) -> [String] {
        var days = Set<String>()
        for note in all.values where !note.deleted {
            let day = ReviewCalendar.day(ofMilliseconds: note.updatedAt, timeZone: timeZone)
            if day >= from && day <= to { days.insert(day) }
        }
        return days.sorted()
    }

    /// Moments notes were created, for counting in the week summary.
    var creationMoments: [Int64] { all.values.filter { !$0.deleted }.map(\.createdAt) }
}

extension ReviewSources {
    /// A snapshot of what the stores hold now.
    @MainActor
    static func current(plans: PlanStore, finance: FinanceStore, workouts: WorkoutStore, notes: NotesStore?) -> ReviewSources {
        ReviewSources(
            plans: plans.plans,
            finance: finance.state.records,
            workouts: workouts.history.records,
            noteMoments: notes?.creationMoments ?? [],
            timeZone: plans.timeZone,
            habitsDay: nil // TEMP: HabitStore.daySummary(for:) from Plans
        )
    }
}
