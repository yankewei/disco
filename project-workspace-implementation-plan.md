# Project / Workspace 纵向切片实现计划

> 状态：实现已落地；专项 XCTest 与 Project/Workspace 手工 UI 验收均已通过（2026-08-09）

## 目标

实现可持久化的 Project 与 Workspace：

- 用户通过目录选择器打开任意可读目录并创建 Project。
- 一个 Project 可以拥有多段对话；普通对话继续保持无 Project 模式。
- Project、目录书签、对话归属和空项目对话可跨重启恢复。
- 目录失效时保留 Project 与历史记录，禁止继续发送，并允许重新关联。
- 本阶段只建立工作区身份、持久化与 UI，不把目录传给 Codex，也不提供文件或命令能力。

完成后，按 2026-08-09 优先级调整，先把 `WorkspaceContext` 接入 Generic Runtime 的只读 Tool Host；Codex `cwd` 与 sandbox policy 延后。

## 领域模型与接口

新增 `AgentDomain/Workspace.swift`，采用以下稳定语义：

```swift
struct WorkspaceContext: Sendable, Equatable {
    let rootURL: URL
    let additionalReadableRoots: [URL]
}

struct ProjectSnapshot: Identifiable, Sendable, Equatable {
    let id: UUID
    var name: String
    var workspaceRoot: URL
    var bookmarkData: Data?
    let createdAt: Date
    var lastOpenedAt: Date
}

enum ProjectAvailability: Sendable, Equatable {
    case available(WorkspaceContext)
    case unavailable(WorkspaceUnavailableReason)
}

enum WorkspaceUnavailableReason: Sendable, Equatable {
    case missing
    case unreadable
}
```

- `Project` 是持久化身份和会话分组，不等同于路径字符串。
- `WorkspaceContext` 只能从当前可用的 Project 派生；第一版 `additionalReadableRoots` 固定为空。
- `ConversationSession` 和 `ConversationSnapshot` 增加 `projectID: UUID?`：
  - `nil` 表示普通对话或旧对话。
  - 非空表示归属于对应 Project。
- 不引入单纯转发字段的 `ProjectSession` 等包装类型。
- `WorkspaceResolver` 作为具体模块封装目录校验、规范化、书签创建和恢复，避免这些易错约束散落在 UI 与状态层。

持久化接口拆分为真实能力：

```swift
@MainActor
protocol ProjectPersisting: AnyObject {
    func loadProjects() throws -> [ProjectSnapshot]
    func saveProject(_ project: ProjectSnapshot) throws
}
```

- `ConversationPersistence` 和 `VolatileConversationPersistence` 同时实现 `ConversationPersisting` 与 `ProjectPersisting`。
- `AppState` 注入并持有这两个协议的组合，不新增只起别名作用的聚合协议。
- 本阶段没有 Project 删除接口，因为 UI 不提供删除 Project。

## 持久化与目录解析

### SwiftData

在现有同一个 `ModelContainer` 中新增 `PersistedProject`：

- `id: UUID`，唯一。
- `name: String`。
- `workspacePath: String`。
- `bookmarkData: Data?`。
- `createdAt: Date`。
- `lastOpenedAt: Date`。

为 `PersistedConversation` 增加可选的 `projectID: UUID?`。

约束：

- Project 与 Conversation 通过 UUID 标量关联，不建立 SwiftData relationship；这样旧记录天然为无 Project，对话也不会因为 Project 状态异常而被级联删除。
- 启动时先加载 Project，再加载 Conversation。
- 对话引用未知 Project 时，将其作为普通对话加载并显示存储警告，不丢弃消息。
- Project 对话即使没有消息也立即保存；普通空对话继续沿用当前不落盘策略。
- 清空 Project 对话会保存空快照，清空普通对话仍从持久层删除。
- 删除最后一段 Project 对话不会删除 Project，空 Project 仍留在侧栏。

本阶段采用一次性开发基线重置，不做旧会话迁移：

- 在开始实现本阶段前，由用户明确确认后删除现有 `conversations.store`、`conversations.store-wal` 和 `conversations.store-shm`。
- 新增 `PersistedProject`、`projectID` 等 schema 后直接以全新数据库启动，不读取或迁移旧会话。
- 不把旧数据库兼容列为本阶段验收要求；旧会话属于已明确放弃的数据。
- 本阶段不提供应用内“重置本地数据”按钮，也不在数据库打不开时静默切换为空的内存存储。
- 数据库初始化失败时显示明确的存储错误；测试使用注入的临时 store URL，不接触真实用户目录。
- 以后如果需要面向正式用户发布，必须另立迁移/备份方案，不能沿用本阶段的开发基线重置策略。

### WorkspaceResolver

选择或重新关联目录时：

1. 要求绝对的本地 file URL。
2. 使用 standardized URL 并解析符号链接，得到规范根路径。
3. 验证路径存在、是目录且当前可读；不要求包含 `.git`。
4. 创建普通 bookmark；应用未启用 Sandbox，因此不申请 security-scoped bookmark。
5. bookmark 创建失败不阻止创建 Project，仍保存规范路径作为回退。
6. Project 名称取目录的 localized name，回退到目录名。

启动恢复时：

1. 优先解析 bookmark。
2. bookmark 过期但仍可解析时刷新 bookmark 并保存 Project。
3. bookmark 损坏时回退到 `workspacePath`。
4. 两者都无法得到可读目录时标记为 unavailable，但保留 Project 和全部对话。
5. 应用重新进入前台时刷新可用状态；重新关联成功后立即恢复对应会话的 Runtime。

去重规则：

- 使用解析符号链接后的规范路径比较 Project。
- 再次打开已有目录时复用原 Project，更新 `lastOpenedAt` 和 bookmark。
- 优先选择该 Project 下已有的空对话；没有则创建并保存新的 Project 对话。
- 重新关联到另一个 Project 已占用的目录时拒绝操作并显示中文错误，不自动合并 Project。
- 重新关联保留 Project UUID、Conversation UUID、消息和 Codex thread ID，只更新目录、名称、bookmark 与 `lastOpenedAt`。

## AppState 与 UI 流程

### AppState

新增状态：

- `projects: [ProjectSnapshot]`
- `projectAvailability: [UUID: ProjectAvailability]`
- 从 `selectedConversation.projectID` 派生当前 Project，不单独持久化 `selectedProjectID`。

新增行为：

- `openProject(at:)`
  - 解析和校验目录。
  - 去重或保存新 Project。
  - 复用同 Project 的空对话，或创建并立即保存一段空对话。
  - 选中新对话并更新 `lastOpenedAt`。
- `createConversation(projectID:)`
  - 只复用相同 `projectID` 下的空对话。
  - 无 Project 的“新建对话”只复用普通空对话，绝不误选 Project 对话。
- `reconnectProject(id:to:)`
  - 校验新目录和重复 Project。
  - 保存成功后再发布新状态。
  - 保持现有对话归属不变。
- `refreshProjectAvailability()`
  - 恢复 bookmark、刷新过期 bookmark并更新 Runtime。
- `makeRuntime(for:)`
  - 普通对话保持现有逻辑。
  - Project 对话只有在 Project 可用时才创建 Runtime。
  - Project 不可用时为对应 `ConversationStore` 配置 `nil` Runtime；正在执行的请求先停止。
  - 本阶段不把 `WorkspaceContext` 注入 `AgentRunRequest` 或 Codex DTO。

项目打开顺序为“先保存 Project，再创建并保存 Conversation”。如果对话保存失败，Project 仍然有效，UI 显示存储错误，用户可再次从 Project 新建对话。

### 目录选择与命令

- 根视图使用 `NSOpenPanel`：
  - 仅允许目录。
  - 单选。
  - 不允许创建目录。
- 侧栏标题区新增“打开项目”按钮。
- `⌘N` 保持创建普通对话。
- 新增 `⌘O` 打开 Project。
- 菜单和按钮复用同一目录选择流程，不让 `AppState` 负责展示 AppKit 面板。

### 侧栏

按以下结构渲染：

1. Project sections，按 `lastOpenedAt` 倒序。
2. 每个 Project 内的对话按 `updatedAt` 倒序。
3. 最后显示“普通对话”section，包含 `projectID == nil` 的对话。

Project section header 包含：

- Project 名称。
- 不可用状态图标。
- 新建 Project 对话按钮。
- 上下文菜单：
  - 在 Finder 中显示。
  - 重新关联目录。

本阶段不提供重命名或移除 Project。

### 对话详情

- `ChatView` 接收 `ConversationSession`，从中读取 `projectID`，而不只接收 `ConversationStore`。
- Project 对话显示紧凑的项目名称和目录路径；文案只说明对话归属，不暗示模型已经能够读取目录。
- Project unavailable 时显示：
  - “项目目录不可用，重新关联后可继续对话。”
  - “重新关联”按钮。
- Composer 同时检查服务商配置和 Project 可用性：
  - Project unavailable 时输入框和发送动作均禁用。
  - 历史消息仍可查看、复制和删除。
- 应用回到前台时刷新 Project 可用性，目录恢复后自动重新装配 Runtime。

## 测试与验收

### WorkspaceResolver

- 接受普通可读目录，不要求 Git。
- 拒绝文件、相对 URL、不存在目录和不可读目录。
- 符号链接与真实路径解析为同一规范根目录。
- bookmark 正常恢复。
- 过期 bookmark 被刷新。
- 损坏 bookmark 能回退到存储路径。
- bookmark 与路径都失效时返回 unavailable。

### 持久化

- Project 完整往返保存。
- Conversation 的 `projectID` 往返保存。
- `projectID == nil` 的普通对话正常加载。
- Project 空对话跨重启保留。
- 普通空对话仍不落盘。
- 清空 Project 对话不会丢失 Project 归属。
- 删除最后一段 Project 对话不会删除 Project。
- Project、Conversation、Message 使用同一个 SwiftData store。
- 新建数据库可以保存 Project、Conversation 和 Message，并能跨重启读取。

### AppState

- 打开新目录创建 Project、绑定空对话并选中。
- 重复打开同一目录不会创建重复 Project。
- 重复打开时复用已有空对话；没有空对话时创建新对话。
- `⌘N` 创建或复用普通空对话，不复用 Project 空对话。
- 新建 Project 对话只在对应 Project 内复用空对话。
- 启动后恢复 Project、对话归属、选中状态和空项目对话。
- 丢失目录保留 Project 与历史，并移除对应 Runtime。
- 重新关联保持 Project、Conversation 和 thread ID。
- 重新关联到其他 Project 的目录时失败且不修改原状态。
- 目录重新可用后 Runtime 恢复。
- 未知 `projectID` 的对话仍作为普通对话显示。

### UI 与回归

手动验证：

- 打开 Project、分组侧栏、新建 Project 对话、Finder 定位和重新关联。
- 删除或移动目录后的 unavailable 状态。
- 重启应用后的 Project、空对话和选中项恢复。
- 普通聊天、服务商切换、清空/删除会话不回归。

2026-08-09 已在独立 DerivedData 与隔离用户目录中完成 Project/Workspace 手工验收及聊天回归：

- 打开 Project、侧栏分组、项目/临时对话切换与 Finder 定位正常。
- Project 空对话、选中项与 workspace 路径跨重启恢复正常。
- 目录丢失后正确进入 unavailable 状态，重新关联后保留 Project 与会话并持久化新路径。
- 删除最后一个 Project 对话不会删除 Project；重新创建、清空和再次重启后仍保留 Project 归属。
- Codex 订阅连接、项目对话发送、流式完成和清空流程正常。

最终运行：

```bash
xcodebuild test \
  -project disco.xcodeproj \
  -scheme disco \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO
```

## 明确边界与后续

- 一个 Project 第一版只有一个 workspace root。
- Project 可以关联任意可读目录，不要求 Git。
- 本阶段开始前已明确放弃旧会话数据，不做迁移；正式发布前必须另行设计迁移或备份策略。
- 不实现 Project 重命名、删除、合并或对话跨 Project 移动。
- 不修改 `AgentRunRequest`、Codex wire DTO、审批、sandbox、diff、命令或文件 item。
- 不向 system prompt 注入目录路径。
- 下一阶段以这里生成的 `WorkspaceContext` 为输入，实现 Generic Runtime 的只读 Tool Host 与路径安全；后续 Codex 阶段再实现 `cwd`、sandbox policy，并处理工作区变化后 thread resume 的兼容策略。
