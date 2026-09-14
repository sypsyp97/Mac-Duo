import AppKit
import CoreGraphics

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var controller: LidController?
    private var statusItemController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Diagnostics.geometry.notice("launched, screen recording granted: \(CGPreflightScreenCaptureAccess())")
        let preferences = Preferences.shared
        let controller = LidController(preferences: preferences)
        self.controller = controller
        statusItemController = StatusItemController(controller: controller, preferences: preferences)
        controller.start()

        guard !CGPreflightScreenCaptureAccess() else { return }
        Task {
            let granted = await ScreenSnapshotter.requestPermission()
            Diagnostics.geometry.notice("screen recording requested at launch, granted: \(granted)")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.stop()
    }
}
