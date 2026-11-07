import SwiftUI

/// How far along the current timer or the whole workout is, from 0 to 1.
public enum WorkoutProgress {
    /// The warm-up countdown that every session starts with.
    public static let preparationSeconds = 30

    /// Rest and warm-up fill as time passes; during a set the mark shows the share of sets done.
    public static func fraction(_ session: WorkoutSessionState, remainingSeconds: Int) -> Double {
        switch session.phase {
        case .preparing:
            return timerFraction(total: preparationSeconds, remaining: remainingSeconds)
        case .resting, .paused:
            let exercise = session.exercises[session.exerciseIndex]
            let planned = exercise.rests.indices.contains(session.setIndex) ? exercise.rests[session.setIndex] : remainingSeconds
            // «+30 с» can push the remaining time past the plan; then the mark restarts from that point.
            return timerFraction(total: max(planned, remainingSeconds), remaining: remainingSeconds)
        case .working, .alerting:
            return setsFraction(session)
        case .complete:
            return 1
        }
    }

    /// Sets finished before the current one, over all sets in the session.
    public static func setsFraction(_ session: WorkoutSessionState) -> Double {
        let total = session.exercises.reduce(0) { $0 + $1.rests.count }
        guard total > 0 else { return 0 }
        let done = session.exercises.prefix(session.exerciseIndex).reduce(0) { $0 + $1.rests.count } + session.setIndex
        return min(1, max(0, Double(done) / Double(total)))
    }

    private static func timerFraction(total: Int, remaining: Int) -> Double {
        guard total > 0 else { return 1 }
        return min(1, max(0, 1 - Double(remaining) / Double(total)))
    }
}

/// Taps in the hand at the moments that matter: a set ends, a rest ends, the workout is done.
public enum WorkoutHaptics {
    public static func feedback(from old: WorkoutPhase, to new: WorkoutPhase) -> SensoryFeedback? {
        guard old != new else { return nil }
        switch (old, new) {
        case (_, .complete):
            return .success
        case (_, .alerting):
            return .impact(weight: .heavy, intensity: 1)
        case (.working, .resting), (.preparing, .resting), (.alerting, .resting):
            return .impact(weight: .medium, intensity: 0.8)
        case (_, .working):
            return .impact(weight: .light, intensity: 0.7)
        default:
            return nil
        }
    }
}
