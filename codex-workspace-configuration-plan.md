# Codex cwd 与 sandbox configuration 实施计划

> 状态：已完成代码与 `codex-cli 0.147.0` schema 核对；按 2026-08-09 优先级调整延后，待 Generic tool loop 只读闭环后再实施

## 目标

把 Project 阶段产出的 `WorkspaceContext` 接入 Codex app-server，使项目会话满足以下不变量：

- 新建、恢复和进程重连后的 Codex thread 始终绑定到当前 Project 的规范化根目录。
- 当前只读阶段不能写工作区，也不能访问网络；不得回退到用户本机 Codex 的宽松默认配置。
- Project 重新关联到不同目录后，旧 thread 不得静默带入新工作区。
- 临时对话继续可用，但不获得工作区写权限。

本阶段只建立 cwd 与执行策略的安全链路，不接入 command/file item、审批 UI、diff、Generic tool loop 或 Tool Host。

## 协议基线

- 本机与项目锁定版本均为 `codex-cli 0.147.0`。
- 实现前重新运行 `codex app-server generate-json-schema`，生成目录只用于 diff，不整体提交。
- `thread/start` 使用：`model`、`cwd`、`approvalPolicy`、`sandbox`、`serviceName`。
- `thread/resume` 重新发送：`model`、`cwd`、`approvalPolicy`、`sandbox`，不能依赖旧 thread 或用户配置中的默认值。
- `turn/start` 重新发送：`cwd`、`approvalPolicy`、结构化 `sandboxPolicy`，防止 turn 覆盖或连接恢复后策略漂移。
- 不发送 `baseInstructions` 或 `developerInstructions`；继续让 Codex 从 cwd 加载作用域内的 `AGENTS.md`。
- 不使用 `danger-full-access`。

## 设计决策

### 1. Workspace 固定在 Runtime 配置

`WorkspaceContext` 和执行策略加入 `CodexRuntime.Configuration`，不在本阶段加入 `AgentRunRequest`。

原因：workspace 是 Conversation/Codex thread 的稳定身份，不是单次消息参数；`thread/start`、手动压缩、断线后的 `thread/resume` 都需要同一份配置。由 Runtime 统一持有可以隐藏 start/resume/turn 的协议差异，也消除“同一个 thread 在两次 run 间换目录”的非法状态。

未来 Generic tool loop 接入时，再基于两条真实实现共同需要的语义收敛领域 `ExecutionPolicy`，不提前增加只做字段转发的公共接口。

### 2. 第一阶段使用显式只读策略

审批请求目前仍被 Transport 明确拒绝，因此本阶段不能把 `workspace-write` 当作已安全接入：

- thread：`sandbox: "read-only"`。
- turn：`sandboxPolicy: { "type": "readOnly", "networkAccess": false }`。
- approval：在 `untrusted` 与 `on-request` 之间做一次真实 smoke test，选择能让 `pwd`、仓库读取和 `git status --short` 正常执行，同时让写入/提权进入拒绝路径的策略。
- 若两者都会产生当前无法处理的审批请求，则保持 read-only，并把稳定失败翻译为中文错误；不得改用 `never` 或放宽 sandbox 来绕过问题。

等原生审批链路完成后，另一个 PR 才能把 Project 会话切到 `workspace-write`。

### 3. Thread 必须带工作区绑定

仅持久化 `threadID` 无法判断它是否属于当前目录。新增 thread workspace 绑定信息，并遵守：

- Project 会话只有在持久化路径与当前规范化 `WorkspaceContext.rootURL` 一致时才能 resume。
- 旧数据只有 `threadID`、没有 workspace 路径时，Project 会话不 resume，首次运行创建新 thread 并写回完整绑定。
- Project 重新关联到相同规范路径时保留 thread。
- Project 重新关联到不同规范路径时立即使旧绑定失效、停止旧运行并重建 Runtime；下一次发送创建新 thread。
- 临时对话可以恢复无 workspace 绑定的 thread，但仍显式使用 read-only、network disabled。
- app-server 返回的实际 cwd 必须规范化后与请求 cwd 相等；不相等时在 `turn/start` 前失败，不能静默接受服务端 cwd。

建议把领域状态收敛为 `CodexThreadBinding`，由 `ConversationStore` 通过一个持久化操作整体替换，而不是让调用方分别维护 thread ID 与路径。

## 实施步骤

### 1. 锁定 wire DTO

修改 `disco/AgentRuntime/CodexAppServerProtocol.swift`：

- 扩展 `CodexThreadStartParams` 与 `CodexThreadResumeParams`。
- 扩展 `CodexTurnStartParams`。
- 增加当前实际使用的 approval、sandbox mode 和 read-only sandbox policy 类型。
- 扩展 thread response，至少解码 `id`、`cwd`、`approvalPolicy`、`sandbox`、`instructionSources` 中本阶段需要验证的字段。
- 只实现 0.147.0 schema 中本阶段使用的形态，不为未来权限类型预建抽象。

### 2. 建立 thread workspace 绑定

修改 `ConversationSession.swift`、`ConversationStore.swift` 与 `ConversationPersistence.swift`：

- 用 `CodexThreadBinding` 表达 thread ID 与可选 workspace 根路径。
- SwiftData 增加可选 workspace path，保留旧 `threadID` 的读取兼容。
- Project 旧 thread 缺少路径时按不可信绑定处理，不 resume。
- 增加持久化往返、旧数据兼容和绑定替换测试。

### 3. 在 AppState 装配 Workspace

修改 `AppState.makeRuntime(for:)`：

- 从 `projectAvailability` 取得 `.available(WorkspaceContext)`，传入 `CodexRuntime.Configuration`。
- Project 不可用时继续不创建 Runtime。
- 临时对话传 nil workspace，但使用显式只读策略。
- `reconnectProject` 检测规范根路径是否变化；变化时使受影响会话的旧 thread 绑定失效并重建 Runtime。

### 4. 让 Runtime 统一维持配置

修改 `CodexRuntime.swift`：

- `Configuration` 持有 workspace 与本阶段固定的执行策略。
- `ensureReady()` 对 start、resume 和进程重连使用同一配置。
- 只有匹配当前 workspace 的 binding 才传给 `thread/resume`。
- 校验 app-server 返回 cwd；失败时不发送 `turn/start`。
- `startTurn` 每次重申 cwd、approval 和 read-only sandbox policy。
- 保持一次 run 恰好一个终止事件。

### 5. 收紧 Transport 接口

修改 `CodexAppServerTransport.swift`：

- 让 `startThread` 接受一份线程配置并返回包含 thread ID 与实际 cwd 的结果，不继续增加互相独立的布尔参数。
- start 与 resume 的 wire 差异留在 Transport 实现内部。
- `startTurn` 接受 Runtime 已确定的 turn 配置。
- workspace mismatch、非法 cwd 和不支持策略返回可诊断错误。

## 自动化测试

### DTO / Transport 合约

- `thread/start` 精确包含 model、规范 cwd、approval policy、`read-only` sandbox 和 `serviceName`。
- `thread/resume` 同样重申 cwd 与策略。
- `turn/start` 包含同一 cwd 与 `{ type: "readOnly", networkAccess: false }`。
- 所有请求都不出现 `danger-full-access`、`workspace-write` 或 `networkAccess: true`。
- app-server 返回不同 cwd 时失败，且没有发送 `turn/start`。
- 进程退出重连后，resume 仍使用原 cwd 与策略。

### Runtime / AppState

- Project 会话使用当前 `.available` workspace。
- 临时会话不获得 Project cwd，且显式只读。
- 相同 workspace 的持久化 thread 正常 resume。
- 旧 thread 缺少 workspace 绑定时创建新 thread。
- Project 重新关联到不同根目录后创建新 thread；旧 thread 不 resume。
- Project 不可用时不能启动 turn。
- 新错误路径和取消路径仍各自只产生一个终止事件。

### Persistence

- thread ID 与 workspace path 往返一致。
- 旧记录没有 workspace path 时可加载，但不会被 Project 会话误 resume。
- 清除/替换绑定立即持久化。

## 手工验收

1. 打开 Project A，发送“报告当前目录并概括仓库结构”，返回路径必须是 A。
2. 重启 App 后继续该会话，确认走 resume 且 cwd 仍是 A。
3. 打开 Project B，执行同样请求，不能看到或报告 A 的路径。
4. 把 A 重新关联到不同目录，再发送消息，必须创建新 thread，不得沿用旧上下文。
5. 请求创建一个测试文件，操作必须被 read-only sandbox 拒绝，磁盘上不得出现文件。
6. 请求进行网络访问，必须失败或进入当前明确拒绝的审批路径，不能静默联网。
7. 临时对话仍能完成纯文本问答。

最后运行完整 `xcodebuild test`，并做一次显式 opt-in 的真实 app-server smoke test。上述自动化与手工验收全部通过后，本阶段才完成。

## 明确不做

- 不展示 command/file item 或命令输出卡片。
- 不响应 command/file approval。
- 不实现 `workspace-write`。
- 不实现 diff、文件编辑或 Tool Host。
- 不修改 Generic Provider 的请求与工具循环。
- 不允许一次 turn 覆盖到另一个 Project。
