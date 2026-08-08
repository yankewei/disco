//
//  ContentView.swift
//  disco
//
//  Created by 闫柯玮 on 2026/8/4.
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        NavigationSplitView {
            ConversationSidebar()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        } detail: {
            if let conversation = appState.selectedConversation {
                ChatView(store: conversation.store)
                    .id(conversation.id)
            } else {
                ContentUnavailableView(
                    "选择一段对话",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("从左侧选择会话，或创建一段新对话。")
                )
            }
        }
        .navigationSplitViewStyle(.balanced)
    }
}

private struct ConversationSidebar: View {
    @EnvironmentObject private var appState: AppState

    /// 当前服务商已保存 Key 但从未验证过连接时，提示用户去设置页验证
    private var needsVerificationAttention: Bool {
        guard let config = appState.config(for: appState.activeVendor) else { return false }
        return appState.activeVendor.requiresAPIKey
            && config.hasAPIKey
            && config.lastVerifiedAt == nil
    }

    var body: some View {
        VStack(spacing: 0) {
            sidebarHeader

            List(selection: $appState.selectedConversationID) {
                Section("最近对话") {
                    ForEach(appState.conversations) { conversation in
                        ConversationRow(conversation: conversation)
                            .tag(conversation.id)
                            .contextMenu {
                                Button("删除对话", role: .destructive) {
                                    appState.deleteConversation(id: conversation.id)
                                }
                            }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            if let storageError = appState.storageError {
                Label(storageError, systemImage: "externaldrive.badge.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(storageError)
            }

            Divider()

            SettingsLink {
                HStack(spacing: 10) {
                    Image(systemName: "slider.horizontal.3")
                        .frame(width: 20)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("连接设置")
                            .font(.callout.weight(.medium))
                        Text(appState.isActiveVendorConfigured ? appState.model : "尚未连接模型")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer(minLength: 4)

                    // 正常（已验证）时不显示圆点；仅未验证这种状态需要引起注意
                    if needsVerificationAttention {
                        Circle()
                            .fill(Color.orange)
                            .frame(width: 7, height: 7)
                            .help("连接已保存，尚未验证")
                    }
                }
                .contentShape(Rectangle())
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
        }
        .background(.regularMaterial)
    }

    private var sidebarHeader: some View {
        HStack(spacing: 11) {
            DiscoMark(size: 27)

            VStack(alignment: .leading, spacing: 1) {
                Text("Disco")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                Text("你的对话")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                appState.createConversation()
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: DiscoRadius.small))
            }
            .buttonStyle(DiscoPressButtonStyle())
            .help("新建对话（⌘N）")
        }
        .padding(.horizontal, 14)
        .padding(.top, 13)
        .padding(.bottom, 12)
    }
}

private struct ConversationRow: View {
    let conversation: ConversationSession

    @ObservedObject private var store: ConversationStore

    init(conversation: ConversationSession) {
        self.conversation = conversation
        store = conversation.store
    }

    private var title: String {
        store.messages.first(where: { $0.role == .user })?.text ?? "新对话"
    }

    private var preview: String {
        store.messages.last?.text.isEmpty == false
            ? store.messages.last?.text ?? ""
            : "开始一段新的对话"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            DiscoMark(size: 19, isActive: store.isStreaming)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    Text(conversation.updatedAt, style: .time)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }

                Text(store.isStreaming ? "正在生成回复…" : preview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    ContentView()
        .environmentObject(AppState(keychain: InMemoryAuthStore()))
}
