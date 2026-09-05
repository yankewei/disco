import SwiftUI

struct LocalAgentConfigurationView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State var agents: [LocalAgentConfiguration]
    @State private var selectedID: String?
    @State private var isSaving = false

    private var selectedIndex: Int? { agents.firstIndex { $0.id == selectedID } }
    private var canSave: Bool {
        !isSaving && model.runningSessionIDs.isEmpty && agents.allSatisfy {
            !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !$0.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("ACP Agent").font(.title2.weight(.semibold))
            Text("配置已安装的 Agent 启动命令。登录与模型设置由各自的命令行工具管理。")
                .foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 16) {
                VStack(spacing: 8) {
                    List(selection: $selectedID) {
                        ForEach(agents) { agent in
                            Text(agent.name.isEmpty ? "新 Agent" : agent.name).tag(agent.id)
                        }
                    }
                    .scrollIndicators(.hidden)
                    HStack {
                        Menu {
                            ForEach(LocalAgentConfiguration.presets) { preset in
                                Button(preset.name) {
                                    let agent = LocalAgentConfiguration(id: UUID().uuidString, name: preset.name, command: preset.command, arguments: preset.arguments)
                                    agents.append(agent)
                                    selectedID = agent.id
                                }
                            }
                            Divider()
                            Button("自定义") {
                                let agent = LocalAgentConfiguration(id: UUID().uuidString, name: "新 Agent", command: "", arguments: [])
                                agents.append(agent)
                                selectedID = agent.id
                            }
                        } label: {
                            Image(systemName: "plus")
                        }
                        .menuIndicator(.hidden)
                        .help("添加 Agent")
                        Button {
                            agents.removeAll { $0.id == selectedID }
                            selectedID = agents.first?.id
                        } label: { Image(systemName: "minus") }
                        .disabled(selectedID == nil)
                        .help("移除配置，保留已有会话")
                        Spacer()
                    }
                }
                .frame(width: 160)

                if let index = selectedIndex {
                    Form {
                        TextField("名称", text: $agents[index].name)
                        TextField("启动命令", text: $agents[index].command)
                        LabeledContent("参数") {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(agents[index].arguments.indices, id: \.self) { argumentIndex in
                                    HStack {
                                        TextField("参数", text: $agents[index].arguments[argumentIndex])
                                        Button {
                                            agents[index].arguments.remove(at: argumentIndex)
                                        } label: { Image(systemName: "minus.circle") }
                                        .buttonStyle(.borderless)
                                        .help("移除此参数")
                                    }
                                }
                                Button("添加参数") { agents[index].arguments.append("") }
                            }
                        }
                        Text("每个参数单独填写，路径含空格时无需添加引号。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .formStyle(.grouped)
                    .scrollIndicators(.hidden)
                    .id(agents[index].id)
                } else {
                    Text("添加或选择一个 Agent")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(height: 300)
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    isSaving = true
                    Task {
                        if await model.saveLocalAgents(agents) { dismiss() }
                        isSaving = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding(24)
        .frame(width: 660)
        .onAppear { selectedID = agents.first?.id }
    }
}
