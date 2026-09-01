import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var shutdownHandler: (() async -> Void)?
    private var terminationRequested = false

    func applicationDidFinishLaunching(_: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationRequested else { return .terminateLater }
        terminationRequested = true
        Task { [weak self] in
            await self?.shutdownHandler?()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
