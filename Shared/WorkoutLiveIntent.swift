import AppIntents
import Foundation

/// The buttons on the workout Live Activity. They run in the app process and send the same commands as the app's buttons.
public struct WorkoutLiveIntent: LiveActivityIntent {
    public enum Action: String {
        case startNow, startRest, skipRest, addThirty, nextSet, finish, resume
    }

    public static var title: LocalizedStringResource = "Команда тренировки"
    public static var isDiscoverable: Bool = false

    @Parameter(title: "Действие")
    public var action: String

    public init() {}

    public init(_ action: Action) {
        self.action = action.rawValue
    }

    public func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        if let parsed = Action(rawValue: action) {
            await WorkoutLiveActivityController.handle(parsed)
        }
        #endif
        return .result()
    }
}
