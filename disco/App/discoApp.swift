//
//  discoApp.swift
//  disco
//
//  Created by 闫柯玮 on 2026/8/4.
//

import SwiftUI

@main
struct DiscoApp: App {
    @StateObject private var appState: AppState

    init() {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            _appState = StateObject(
                wrappedValue: AppState(
                    keychain: InMemoryAuthStore(),
                    persistence: VolatileConversationPersistence()
                )
            )
        } else {
            _appState = StateObject(wrappedValue: AppState())
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .tint(DiscoTheme.accent)
                .frame(minWidth: 820, minHeight: 560)
        }
        .defaultSize(width: 1120, height: 760)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(after: .newItem) {
                Button("新建对话") {
                    appState.createConversation()
                }
                .keyboardShortcut("n", modifiers: .command)
            }

            CommandMenu("对话") {
                Button("清空当前对话…") {
                    NotificationCenter.default.post(name: .discoRequestClearConversation, object: nil)
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .disabled(appState.selectedConversation?.store.messages.isEmpty ?? true)

                Divider()

                Button("删除当前对话") {
                    if let id = appState.selectedConversation?.id {
                        appState.deleteConversation(id: id)
                    }
                }
                .disabled(appState.selectedConversation == nil)
            }
        }

        Settings {
            SettingsView()
                .environmentObject(appState)
                .tint(DiscoTheme.accent)
        }
    }
}
