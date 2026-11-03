import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    let images = ImageModel()

    /// ⌘O adds to whichever tab is showing.
    func openFiles() {
        if UserDefaults.standard.string(forKey: "tab") == AppTab.images.rawValue {
            images.showOpenPanel()
        } else {
            model.showOpenPanel()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare binary (swift run); harmless inside the .app.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        model.terminateNow()
    }
}

@main
struct ClipforgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup("Clipforge") {
            ContentView()
                .environmentObject(delegate.model)
                .environmentObject(delegate.images)
                .frame(minWidth: 960, minHeight: 640)
        }
        // The aurora runs under the (transparent) title bar; content stays below it.
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Files…") { delegate.openFiles() }
                    .keyboardShortcut("o")
            }
        }
    }
}
