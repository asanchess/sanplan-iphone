import SwiftUI

@main
struct ARNAApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .environmentObject(model.auth)
                .environmentObject(model.alarms)
        }
    }
}
