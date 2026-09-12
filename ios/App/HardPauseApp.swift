import SwiftUI

@main
struct HardPauseApp: App {
    @StateObject private var controller = LockController()

    var body: some Scene {
        WindowGroup {
            RootView(controller: controller)
        }
    }
}
