import SwiftUI

/// Точка входа в приложение SanPlan iOS.
@main
struct SanPlanApp: App {
    @StateObject private var gateway = PlanGateway()
    @StateObject private var coordinator = AlarmCoordinator()

    var body: some Scene {
        WindowGroup {
            ContentView(gateway: gateway, coordinator: coordinator)
        }
    }
}
