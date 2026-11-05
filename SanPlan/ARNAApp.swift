import SwiftUI

@main
struct ARNAApp: App {
    @StateObject private var authService: AuthService
    @StateObject private var alarmCoordinator: AlarmCoordinator

    init() {
        let client = APIClient()
        _authService = StateObject(wrappedValue: AuthService(client: client))
        _alarmCoordinator = StateObject(wrappedValue: AlarmCoordinator())
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(authService)
                .environmentObject(alarmCoordinator)
        }
    }
}
