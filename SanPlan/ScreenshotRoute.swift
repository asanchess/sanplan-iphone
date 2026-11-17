import Foundation

/// Debug-only routes for the cloud screenshots, so every screen can be compared with the canvas
/// (`docs/design/canvas-r5`). Launch flags (with `--screenshot-signed-in`):
/// - `--screenshot-tab N` picks the tab (see `MainTab` raw values);
/// - `--screenshot-screen <id>` opens one place inside it, e.g. `money-plan`, `plans-habits`, `workout-history`, `progress`, `profile`;
/// - `--screenshot-demo-data` fills the stores with made-up data, so screens are not empty.
/// Each section reads these itself; nothing here is saved or reaches release builds.
public enum ScreenshotRoute {
    /// Every screen the cloud build photographs: id and the tab it opens on.
    public static let all: [(id: String, tab: Int)] = [
        ("today", 0), ("summary", 0), ("progress", 0), ("profile", 0), ("profile-mascot", 0), ("profile-settings", 0),
        ("money-overview", 1), ("money-plan", 1), ("money-ops", 1),
        ("plans-plans", 2), ("plans-habits", 2), ("plans-goals", 2), ("plans-alarms", 2),
        ("workout-plan", 3), ("workout-history", 3),
        ("notes-list", 4), ("notes-editor", 4),
    ]

    /// The screen asked for by `--screenshot-screen`, or nil.
    public static var screen: String? {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--screenshot-signed-in"),
              let index = arguments.firstIndex(of: "--screenshot-screen"), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
        #else
        return nil
        #endif
    }

    /// True when this exact screen was asked for.
    public static func `is`(_ id: String) -> Bool { screen == id }

    /// True when made-up data should fill the stores.
    public static var demoData: Bool {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("--screenshot-signed-in") && arguments.contains("--screenshot-demo-data")
        #else
        return false
        #endif
    }
}
