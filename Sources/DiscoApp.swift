import AppKit
import SwiftUI

@main
struct DiscoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model: AppModel

    init() {
        _model = StateObject(wrappedValue: AppModel())
    }

    var body: some Scene {
        WindowGroup("Disco") {
            WorkspaceView()
                .environmentObject(model)
                .frame(minWidth: 960, minHeight: 640)
                .onAppear {
                    appDelegate.shutdownHandler = { [weak model] in
                        await model?.shutdown()
                    }
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建会话") {
                    model.startNewSession()
                }
                .keyboardShortcut("n", modifiers: [.command])
            }
        }

        Settings {
            SettingsView()
                .environmentObject(model)
                .frame(width: 640, height: 420)
        }
    }
}

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
