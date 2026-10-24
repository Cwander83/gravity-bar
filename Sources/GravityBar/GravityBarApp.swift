import SwiftUI
import AppKit

@main
struct GravityBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--test") {
            Task {
                exit(await SelfTests.run())
            }
            return
        }

        // Run as menu bar accessory (hide Dock icon)
        NSApp.setActivationPolicy(.accessory)
        statusBarController = StatusBarController(manager: .shared)
    }
}
