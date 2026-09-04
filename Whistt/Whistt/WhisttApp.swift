import SwiftUI

@main
struct WhisttApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView(appDelegate: appDelegate)
        }
        .windowResizability(.contentSize)
    }
}
