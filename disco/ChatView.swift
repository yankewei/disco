import AppKit
import MarkdownView
import SwiftUI

struct ChatView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var store: ConversationStore
    @State private var isConfirmingClear = false

    private var providerHost: String {
        URL(string: appState.baseURL)?.host ?? appState.baseURL
    }

    var body: some View {
        ZStack {
            DiscoTheme.canvas
                .ignoresSafeArea()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 32) {
                        if store.messages.isEmpty {
                            EmptyConversationView(
                                isConfigured: appState.hasAPIKey,
                                model: appState.model,
                                providerHost: providerHost
                            )
                            .containerRelativeFrame(.vertical, alignment: .center) { height, _ in
                                max(height - 150, 320)
                            }
                        } else {
                            ForEach(store.messages) { message in
                                MessageRow(
                                    message: message,
                                    isStreaming: store.isStreaming && message.id == store.messages.last?.id
                                )
                                .id(message.id)
                            }
                        }
                    }
                    .frame(maxWidth: 760)
                    .padding(.horizontal, 28)
                    .padding(.top, 36)
                    .padding(.bottom, 20)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: store.messages) {
                    guard let id = store.messages.last?.id else { return }
                    withAnimation(.easeOut(duration: 0.18)) {
                        proxy.scrollTo(id, anchor: .bottom)
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 10) {
                if let errorMessage = store.errorMessage {
                    ChatErrorBanner(
                        message: errorMessage,
                        canRetry: store.canRetry,
                        retry: store.retryLastMessage,
                        dismiss: store.dismissError
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                ComposerView(
                    store: store,
                    isConfigured: appState.hasAPIKey,
                    model: appState.model,
                    providerHost: providerHost
                )
            }
            .frame(maxWidth: 760)
            .padding(.horizontal, 20)
            .padding(.bottom, 18)
            .frame(maxWidth: .infinity)
        }
        .animation(.easeOut(duration: 0.2), value: store.errorMessage)
        .toolbar {
            ToolbarSpacer(.flexible)

            ToolbarItemGroup(placement: .primaryAction) {
                SettingsLink {
                    ModelStatusPill(
                        model: appState.model,
                        isConfigured: appState.hasAPIKey
                    )
                }
                .help(appState.hasAPIKey ? "配置模型与 API" : "连接模型")

                Button {
                    isConfirmingClear = true
                } label: {
                    Image(systemName: "trash")
                        .frame(width: 20, height: 20)
                }
                .help("清空当前对话")
                .disabled(store.messages.isEmpty)
            }
        }
        .confirmationDialog(
            "清空当前对话？",
            isPresented: $isConfirmingClear,
            titleVisibility: .visible
        ) {
            Button("清空", role: .destructive) {
                store.clear()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这只会清空当前窗口中的消息。")
        }
    }
}

private struct ModelStatusPill: View {
    let model: String
    let isConfigured: Bool

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(isConfigured ? DiscoTheme.coral : Color.secondary.opacity(0.45))
                .frame(width: 7, height: 7)

            Text(isConfigured ? model : "连接模型")
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.quaternary, in: Capsule())
        .help(model)
    }
}

private struct EmptyConversationView: View {
    let isConfigured: Bool
    let model: String
    let providerHost: String

    var body: some View {
        HStack(spacing: 26) {
            DiscoMark(size: 76)

            VStack(alignment: .leading, spacing: 11) {
                Text(isConfigured ? "开始一段对话" : "连接你的模型")
                    .font(.system(size: 28, weight: .semibold, design: .rounded))

                if isConfigured {
                    Text("Disco 已准备好。输入问题、想法或一段需要继续完成的文字。")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Label("\(model)  ·  \(providerHost)", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("添加 Base URL 和 API Key，再选择一个模型。凭据只保存在这台 Mac。")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    SettingsLink {
                        Label("打开连接设置", systemImage: "arrow.right")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 15)
                            .padding(.vertical, 9)
                            .background(DiscoTheme.coral, in: Capsule())
                    }
                    .buttonStyle(DiscoPressButtonStyle())
                }
            }
            .frame(maxWidth: 420, alignment: .leading)
        }
        .frame(maxWidth: 560, alignment: .leading)
        .padding(.horizontal, 24)
        .accessibilityElement(children: .contain)
    }
}

private struct MessageRow: View {
    let message: ChatMessage
    let isStreaming: Bool

    @State private var isHovered = false

    var body: some View {
        Group {
            if message.role == .user {
                HStack(alignment: .top) {
                    Spacer(minLength: 100)
                    Text(message.text)
                        .font(.body)
                        .lineSpacing(4)
                        .textSelection(.enabled)
                        .padding(.horizontal, 15)
                        .padding(.vertical, 11)
                        .background(DiscoTheme.coral.opacity(0.11))
                        .clipShape(RoundedRectangle(cornerRadius: DiscoRadius.medium, style: .continuous))
                }
            } else {
                HStack(alignment: .top, spacing: 13) {
                    DiscoMark(size: 23, isActive: isStreaming)
                        .padding(.top, 1)

                    VStack(alignment: .leading, spacing: 10) {
                        if message.text.isEmpty && isStreaming {
                            Text("正在生成")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 2)
                        } else {
                            MarkdownView(message.text)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        if !message.text.isEmpty {
                            Button(action: copyMessage) {
                                Label("复制", systemImage: "doc.on.doc")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 5)
                                    .background(.quaternary, in: Capsule())
                            }
                            .buttonStyle(DiscoPressButtonStyle())
                            .opacity(isHovered ? 1 : 0.55)
                        }
                    }
                    .frame(maxWidth: 680, alignment: .leading)

                    Spacer(minLength: 40)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .onHover { isHovered = $0 }
        .contextMenu {
            if !message.text.isEmpty {
                Button("复制") {
                    copyMessage()
                }
            }
        }
    }

    private func copyMessage() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.text, forType: .string)
    }
}

private struct ChatErrorBanner: View {
    let message: String
    let canRetry: Bool
    let retry: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)

            Text(message)
                .font(.callout)
                .foregroundStyle(.primary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)

            if canRetry {
                Button("重试", action: retry)
                    .buttonStyle(.plain)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.red)
            }

            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("关闭错误")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(Color.red.opacity(0.09), in: RoundedRectangle(cornerRadius: DiscoRadius.medium))
    }
}

private struct ComposerView: View {
    @ObservedObject var store: ConversationStore
    let isConfigured: Bool
    let model: String
    let providerHost: String

    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField(
                isConfigured ? "输入消息" : "连接模型后开始对话",
                text: $store.draft,
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .font(.body)
            .lineLimit(1...6)
            .focused($isFocused)
            .disabled(!isConfigured || store.isStreaming)
            .onKeyPress(.return, phases: .down) { keyPress in
                guard !keyPress.modifiers.contains(.command) else { return .ignored }
                store.draft.append("\n")
                return .handled
            }

            HStack(spacing: 8) {
                if isConfigured {
                    DiscoMark(size: 10, isActive: store.isStreaming)

                    Text(model)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(model)

                    Text(providerHost)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(providerHost)
                } else {
                    Image(systemName: "lock.fill")
                    Text("API Key 保存在 Keychain")
                }

                Spacer(minLength: 12)

                if isConfigured {
                    Text("⌘↩︎")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                } else {
                    SettingsLink {
                        Text("连接")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(DiscoTheme.coral)
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    if store.isStreaming {
                        store.stop()
                    } else {
                        store.send()
                    }
                } label: {
                    Image(systemName: store.isStreaming ? "stop.fill" : "arrow.up")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(
                            store.isStreaming ? Color.primary.opacity(0.72) : DiscoTheme.coral,
                            in: Circle()
                        )
                }
                .buttonStyle(DiscoPressButtonStyle())
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(!store.isStreaming && !store.canSend)
                .opacity((store.isStreaming || store.canSend) ? 1 : 0.38)
                .help(store.isStreaming ? "停止生成" : "发送")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(15)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DiscoRadius.large, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 18, y: 7)
        .onAppear {
            if isConfigured {
                isFocused = true
            }
        }
        .onChange(of: isConfigured) { _, configured in
            if configured {
                isFocused = true
            }
        }
    }
}
