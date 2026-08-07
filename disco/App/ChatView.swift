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
                    isConfigured: appState.hasAPIKey
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
        .onReceive(NotificationCenter.default.publisher(for: .discoRequestClearConversation)) { _ in
            guard !store.messages.isEmpty else { return }
            isConfirmingClear = true
        }
    }
}

private struct ModelStatusPill: View {
    let model: String
    let isConfigured: Bool

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(isConfigured ? DiscoTheme.accent : Color.secondary.opacity(0.45))
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
                            .background(DiscoTheme.accent, in: Capsule())
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
                        .background(DiscoTheme.accent.opacity(0.11))
                        .clipShape(RoundedRectangle(cornerRadius: DiscoRadius.medium, style: .continuous))
                }
            } else {
                HStack(alignment: .top, spacing: 13) {
                    VStack(alignment: .leading, spacing: 10) {
                        // 无思考内容的生成中（thinking 关闭时）用扫光占位；
                        // 有 reasoning 时由思考块头部承担状态展示。
                        if message.text.isEmpty && isStreaming && message.reasoning.isEmpty {
                            ThinkingIndicator()
                        }

                        ForEach(Array(message.parts.enumerated()), id: \.offset) { _, part in
                            switch part {
                            case let .text(text):
                                if !text.isEmpty {
                                    MarkdownView(text)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            case let .reasoning(reasoning):
                                ReasoningDisclosure(
                                    reasoning: reasoning,
                                    isThinking: isStreaming && message.text.isEmpty
                                )
                            case let .toolCall(call):
                                ToolCallRow(call: call)
                            }
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

private struct ThinkingIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Text("思考中")
            .font(.callout)
            .foregroundStyle(.secondary)
            .modifier(ShimmerModifier(reduceMotion: reduceMotion))
    }
}

/// 从左到右扫光：一个高光条在文字形状内循环掠过。
private struct ShimmerModifier: ViewModifier {
    let reduceMotion: Bool
    var duration: Double = 2.0

    func body(content: Content) -> some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
            let progress = context.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: duration) / duration
            let position = -0.4 + progress * 1.8

            content
                .overlay {
                    LinearGradient(
                        colors: [.clear, Color.primary.opacity(0.85), .clear],
                        startPoint: UnitPoint(x: position - 0.25, y: 0.5),
                        endPoint: UnitPoint(x: position + 0.25, y: 0.5)
                    )
                }
                .mask(content)
        }
    }
}

private struct ReasoningDisclosure: View {
    let reasoning: String
    /// 思考阶段（流式中且正文未出）：头部显示「思考中」+ 扫光，内容限高滚动；
    /// 思考结束：头部变「思考过程」，自动收起，展开时完整显示。
    let isThinking: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(reduceMotion ? nil : DiscoMotion.spring) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "brain")
                        .font(.system(size: 11, weight: .medium))

                    if isThinking {
                        Text("思考中")
                            .font(.caption.weight(.medium))
                            .modifier(ShimmerModifier(reduceMotion: reduceMotion))
                    } else {
                        Text("思考过程")
                            .font(.caption.weight(.medium))
                    }

                    Spacer(minLength: 12)
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isThinking ? "思考中" : (isExpanded ? "收起思考过程" : "展开思考过程"))

            if isExpanded {
                Group {
                    if isThinking {
                        // 思考内容实时增长：限高内部滚动，自动跟随底部
                        ScrollViewReader { proxy in
                            ScrollView {
                                Text(reasoning)
                                    .id("bottom")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineSpacing(3)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(10)
                            }
                            .frame(maxHeight: 240)
                            .onChange(of: reasoning.count) {
                                proxy.scrollTo("bottom", anchor: .bottom)
                            }
                        }
                    } else {
                        Text(reasoning)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineSpacing(3)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    }
                }
                .background(
                    Color.primary.opacity(0.05),
                    in: RoundedRectangle(cornerRadius: DiscoRadius.small, style: .continuous)
                )
            }
        }
        .padding(.leading, 8)
        .onAppear {
            if isThinking {
                isExpanded = true
            }
        }
        .onChange(of: isThinking) { _, thinking in
            withAnimation(.easeOut(duration: 0.18)) {
                isExpanded = thinking
            }
        }
    }
}

/// 工具调用块（预留：解析与执行尚未接入，wrench 图标）。
private struct ToolCallRow: View {
    let call: ChatMessage.ToolCallSnapshot

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(reduceMotion ? nil : DiscoMotion.spring) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.system(size: 11, weight: .medium))
                    Text(call.name)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 12)
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "收起工具调用" : "展开工具调用")

            if isExpanded {
                Text(call.arguments)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(
                        Color.primary.opacity(0.05),
                        in: RoundedRectangle(cornerRadius: DiscoRadius.small, style: .continuous)
                    )
            }
        }
        .padding(.leading, 8)
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

    @EnvironmentObject private var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isModelDrawerPresented = false
    @FocusState private var isFocused: Bool

    private var activeVendor: ProviderVendor {
        appState.activeVendor
    }

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
                    modelDrawerTrigger
                    thinkingToggle
                } else {
                    Image(systemName: "lock.fill")
                    Text("API Key 仅保存在本机")
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
                            .foregroundStyle(DiscoTheme.accent)
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
                            store.isStreaming ? Color.primary.opacity(0.72) : DiscoTheme.accent,
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

    // MARK: - 配置行控件

    /// 打开模型抽屉的入口胶囊：显示当前服务商与模型，宽度随文字自适应
    private var modelDrawerTrigger: some View {
        Button {
            isModelDrawerPresented = true
        } label: {
            segmentLabel(modelLabel)
                .contentTransition(.opacity)
                .padding(.horizontal, 10)
                .frame(minHeight: 28)
                .background(.quaternary, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(store.isStreaming)
        .help("选择服务商与模型")
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: modelLabel)
        .popover(isPresented: $isModelDrawerPresented, arrowEdge: .bottom) {
            ModelDrawer(dismiss: { isModelDrawerPresented = false })
        }
    }

    /// 当前选择文案：服务商 · 模型（未选模型时只显示服务商）
    private var modelLabel: String {
        appState.model.isEmpty ? appState.activeVendor.title : "\(appState.activeVendor.title) · \(appState.model)"
    }

    /// 抽屉入口的标签：文字（不截断）+ 下箭头，宽度随内容自适应
    private func segmentLabel(_ text: String) -> some View {
        HStack(spacing: 5) {
            Text(text)
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .semibold))
        }
    }

    private var thinkingToggle: some View {
        let isOn = appState.config(for: activeVendor)?.thinkingEnabled ?? true

        return Button {
            appState.setThinkingEnabled(!isOn, for: activeVendor)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "brain")
                Text("思考")
            }
            .foregroundStyle(isOn ? DiscoTheme.accent : Color.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                isOn ? DiscoTheme.accent.opacity(0.14) : Color.clear,
                in: Capsule()
            )
        }
        .buttonStyle(DiscoPressButtonStyle())
        .disabled(store.isStreaming)
        .help(isOn ? "思考模式已开启，点击关闭" : "思考模式已关闭，点击开启")
    }
}

/// 模型抽屉：左列选服务商、右列展示该服务商全部模型；选中模型后切换并关闭
private struct ModelDrawer: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openSettings) private var openSettings

    /// 关闭抽屉（选中模型或打开设置后调用）
    let dismiss: () -> Void

    /// 抽屉内当前高亮的服务商；打开时默认跟随当前服务商
    @State private var selectedVendor: ProviderVendor?

    /// 已配置 API Key 的服务商
    private var vendors: [ProviderVendor] {
        ProviderVendor.allCases.filter {
            $0.isAvailable && appState.config(for: $0)?.hasAPIKey == true
        }
    }

    private var highlightedVendor: ProviderVendor {
        selectedVendor ?? appState.activeVendor
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                vendorPane

                Divider()

                modelPane
                    .id(highlightedVendor)
            }
            .frame(maxHeight: .infinity)

            Divider()

            Button {
                dismiss()
                openSettings()
            } label: {
                Label("管理连接…", systemImage: "slider.horizontal.3")
                    .font(.callout)
                    .foregroundStyle(DiscoTheme.accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(width: 460, height: 300)
        .onAppear { selectedVendor = appState.activeVendor }
    }

    // MARK: 左列：服务商

    private var vendorPane: some View {
        VStack(spacing: 0) {
            Text("服务商")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

            Divider()

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(vendors) { vendor in
                        vendorRow(vendor)
                    }
                }
                .padding(6)
            }
        }
        .frame(width: 168)
    }

    private func vendorRow(_ vendor: ProviderVendor) -> some View {
        Button {
            // 切换服务商后，右侧模型栏随之更新
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                selectedVendor = vendor
            }
        } label: {
            HStack(spacing: 8) {
                Text(vendor.title)
                    .font(.callout.weight(highlightedVendor == vendor ? .semibold : .regular))
                    .foregroundStyle(highlightedVendor == vendor ? .primary : .secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .background(
                highlightedVendor == vendor ? DiscoTheme.accent.opacity(0.12) : Color.clear,
                in: RoundedRectangle(cornerRadius: DiscoRadius.small)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: 右列：模型

    @ViewBuilder
    private var modelPane: some View {
        let vendor = highlightedVendor
        let models = appState.config(for: vendor)?.models ?? []

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(vendor.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if models.isEmpty {
                    Text("尚未加载模型列表")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            if models.isEmpty {
                Spacer()
                Text("请先在设置中验证连接，加载模型列表")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(14)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(models, id: \.self) { name in
                            modelRow(name, vendor: vendor)

                            if name != models.last {
                                Divider()
                                    .padding(.leading, 14)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .transition(.asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .opacity
        ))
    }

    private func modelRow(_ name: String, vendor: ProviderVendor) -> some View {
        Button {
            selectModel(vendor, name)
        } label: {
            HStack(spacing: 10) {
                Text(name)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if vendor == appState.activeVendor && name == appState.model {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(DiscoTheme.accent)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 选中模型：跨服务商时先切换服务商，再设置模型并关闭抽屉
    private func selectModel(_ vendor: ProviderVendor, _ name: String) {
        if vendor != appState.activeVendor {
            appState.setActiveVendor(vendor)
        }
        appState.setActiveModel(name, for: vendor)
        dismiss()
    }
}

// MARK: - 预览

/// 预览用 AppState：内存替身 + 独立 UserDefaults，绝不读写真实凭据/数据库
@MainActor
private func makePreviewAppState() -> AppState {
    let appState = AppState(
        keychain: InMemoryAuthStore(),
        defaults: UserDefaults(suiteName: "disco.preview.\(UUID().uuidString)")!,
        persistence: VolatileConversationPersistence()
    )
    try? appState.saveProviderConfig(
        vendor: .deepseek,
        baseURL: "https://api.deepseek.com/v1",
        apiKey: "sk-preview-deepseek",
        model: "deepseek-chat",
        models: ["deepseek-chat", "deepseek-reasoner"]
    )
    try? appState.saveProviderConfig(
        vendor: .openai,
        baseURL: "https://api.openai.com/v1",
        apiKey: "sk-preview-openai",
        model: "gpt-4o-mini",
        models: ["gpt-4o-mini", "gpt-4o"]
    )
    return appState
}

/// 预览用示例对话（含思考过程与正文）
@MainActor
private func makePreviewConversation() -> ConversationSession {
    ConversationSession(
        messages: [
            ChatMessage(role: .user, text: "用 Swift 写一个冒泡排序"),
            ChatMessage(
                role: .assistant,
                text: "```swift\nfunc bubbleSort(_ arr: inout [Int]) {\n    for i in 0..<arr.count {\n        for j in 0..<(arr.count - i - 1) {\n            if arr[j] > arr[j + 1] {\n                arr.swapAt(j, j + 1)\n            }\n        }\n    }\n}\n```\n\n这是冒泡排序的实现，最坏时间复杂度 O(n²)。",
                reasoning: "用户要求用 Swift 实现冒泡排序。直接给出可运行的实现，并补充复杂度说明。"
            ),
        ]
    )
}

#Preview("聊天窗") {
    ChatView(store: makePreviewConversation().store)
        .environmentObject(makePreviewAppState())
        .frame(width: 820, height: 600)
}

#Preview("模型抽屉") {
    ModelDrawer(dismiss: {})
        .environmentObject(makePreviewAppState())
        .frame(width: 460, height: 300)
}
