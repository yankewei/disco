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
                .frame(minWidth: 900, minHeight: 560)
                .onAppear {
                    appDelegate.shutdownHandler = { [weak model] in
                        await model?.shutdown()
                    }
                }
        }
        .defaultSize(width: 1000, height: 640)
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
                .frame(width: 1100, height: 720)
        }
    }
}
