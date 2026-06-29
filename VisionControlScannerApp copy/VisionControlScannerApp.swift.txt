import SwiftUI

@main
struct VisionControlScannerApp: App {
    init() {
        // Bail out to CLI mode before SwiftUI ever initializes a window.
        if CLI.runIfNeeded() {
            exit(0)
        }
    }

    var body: some Scene {
        WindowGroup("Vision Control Scanner") {
            ContentView()
                .frame(minWidth: 1200, minHeight: 780)
        }
        .windowResizability(.contentSize)
    }
}
