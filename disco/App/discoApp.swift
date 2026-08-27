//
//  discoApp.swift
//  disco
//
//  Created by 闫柯玮 on 2026/8/4.
//

import AppKit
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

    private var sidebarOrderedConversations: [ConversationSession] {
        let projectIDs = Set(appState.projects.map(\.id))
        let projectConversations = appState.projects.flatMap { project in
            appState.conversations.filter { $0.projectID == project.id }
        }
        let temporaryConversations = appState.conversations.filter { conversation in
            guard let projectID = conversation.projectID else {
                return !conversation.store.messages.isEmpty
                    || conversation.id == appState.selectedConversationID
            }
            return !projectIDs.contains(projectID)
                && (!conversation.store.messages.isEmpty
                    || conversation.id == appState.selectedConversationID)
        }
        return projectConversations + temporaryConversations
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
            // replacing .newItem：移除 WindowGroup 自带的「新建窗口 ⌘N」，避免 ⌘N 另开新窗口
            CommandGroup(replacing: .newItem) {
                Button("新建对话") {
                    appState.createConversationInCurrentContext()
                }

                Button("添加项目…") {
                    NotificationCenter.default.post(name: .discoRequestOpenProject, object: nil)
                }
                .keyboardShortcut("o", modifiers: .command)

                Button("新建临时对话") {
                    appState.createConversation(projectID: nil)
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])

                Divider()

                Button("搜索对话…") {
                    NotificationCenter.default.post(
                        name: .discoFocusSidebarSearch,
                        object: nil
                    )
                }
                .keyboardShortcut("f", modifiers: .command)
            }

            // ⌘1-9：按侧栏顺序跳转到前 9 个会话
            CommandGroup(after: .sidebar) {
                ForEach(Array(sidebarOrderedConversations.prefix(9).enumerated()), id: \.element.id) { index, conversation in
                    Button("转到：\(ConversationTitle.make(from: conversation.store.messages))") {
                        appState.selectedConversationID = conversation.id
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                }
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
