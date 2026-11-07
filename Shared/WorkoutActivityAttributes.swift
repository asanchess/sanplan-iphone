import ActivityKit
import Foundation

/// The workout on the lock screen and in the Dynamic Island. Shared by the app and the widget extension.
public struct WorkoutActivityAttributes: ActivityAttributes {
    public enum Phase: String, Codable, Hashable {
        case preparing, working, resting, paused, alerting
    }

    public struct ContentState: Codable, Hashable {
        public var exerciseName: String
        public var setNumber: Int
        public var setTotal: Int
        public var phase: Phase
        /// Counts down to this moment during the warm-up and rest.
        public var countdownEnd: Date?
        /// Counts up from this moment during a set.
        public var stopwatchStart: Date?
        /// Frozen rest time while paused.
        public var pausedRemainingSeconds: Int?
        public var isLastSet: Bool
        /// Share of the session done, 0…1, for the ARNA mark.
        public var progress: Double

        public init(
            exerciseName: String,
            setNumber: Int,
            setTotal: Int,
            phase: Phase,
            countdownEnd: Date? = nil,
            stopwatchStart: Date? = nil,
            pausedRemainingSeconds: Int? = nil,
            isLastSet: Bool = false,
            progress: Double = 0
        ) {
            self.exerciseName = exerciseName
            self.setNumber = setNumber
            self.setTotal = setTotal
            self.phase = phase
            self.countdownEnd = countdownEnd
            self.stopwatchStart = stopwatchStart
            self.pausedRemainingSeconds = pausedRemainingSeconds
            self.isLastSet = isLastSet
            self.progress = progress
        }

        public var setLabel: String { "Подход \(setNumber) из \(setTotal)" }

        public var phaseTitle: String {
            switch phase {
            case .preparing: return "Разминка"
            case .working: return "Подход"
            case .resting: return "Отдых"
            case .paused: return "Пауза"
            case .alerting: return "Отдых окончен"
            }
        }
    }

    public init() {}
}
