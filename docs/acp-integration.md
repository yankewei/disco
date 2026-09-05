# ACP 接入设计

## 目标与边界

Disco 作为 Agent Client Protocol 客户端，通过用户已安装的本地命令启动 ACP agent。Kimi 使用 `kimi acp`，pi 使用独立安装的 `pi-acp` 适配器；后续 agent 通过配置接入，共用协议实现。

保留 Codex app-server 和 OpenCode HTTP/SSE 适配器。ACP 类型只存在于 `Sources/Providers/ACP/`，界面继续消费统一领域模型与事件。登录由 CLI 管理，不读取或复制凭据。

## 现有代码需要调整的地方

| 位置 | 现状 | 调整 |
| --- | --- | --- |
| `Domain/Models.swift` | `BackendKind` 是固定枚举，同时承担 agent 身份与展示信息 | 用稳定的 agent 标识关联配置，通信协议单独表示；兼容 `codex`、`opencode` 现有持久化值 |
| `App/AppDependencies.swift` | 按固定命令发现并构造两个适配器 | 内置适配器继续自动发现；ACP 根据命令、参数和环境配置构造通用适配器 |
| `Application/AgentHost.swift` | 后端以 `BackendKind` 为键，枚举生成服务商目录 | 使用独立 agent 标识，允许多个 ACP agent；配置刷新需比较完整启动配置，不能只比较可执行路径 |
| `Infrastructure/Transport/JSONRPC.swift` | 换行分隔 JSON-RPC，请求统一 30 秒超时 | 保留普通请求超时，为长时间 `session/prompt` 单独设置策略；取消、退出必须释放等待中的请求 |
| `Application/AgentContracts.swift` | 全局模型列表、布尔 Plan 能力、二选一审批 | 将会话能力与会话配置单独表达；权限选项必须保留 agent 返回的标识与含义 |
| `Presentation/Workspace/WorkspaceView.swift` | 没有模型列表时无法选择 agent | 始终允许选择 Agent 默认模型；按会话公布的配置提供模型和模式选择 |
| `Presentation/Settings/SettingsView.swift` | 仅扫描固定 CLI | 添加 ACP 配置入口，提供 Kimi、pi 预设与自定义启动配置 |

不能只增加一个 `.acp` 枚举值：多个 ACP agent 会共享身份，并可能在 `(agent, agent_thread_id)` 唯一约束上冲突。也不应为每个 ACP agent 复制后端实现。

## 配置与持久化

每个 agent 配置保存稳定 ID、显示名称、可执行命令和独立参数数组。命令直接交给 `Process`，不拼接 shell 字符串。如需环境覆盖，避免在界面错误或日志中输出环境值。

会话绑定 agent 配置 ID 与 ACP session ID。重命名 agent 不改变绑定；移除配置后仍可识别已有会话，并显示 agent 不可用。运行中的配置变更在运行结束后生效。

Kimi 预设：`command = kimi`，`arguments = [acp]`。pi 预设：`command = pi-acp`，`arguments = []`。Disco 不自动安装 CLI 或适配器。

## 协议生命周期

1. 启动 stdio 进程，发送 `initialize`，校验协商后的协议版本。
2. 只声明已实现的客户端能力，保存 agent 的会话恢复、内容和配置能力。
3. 新会话调用 `session/new`，提供绝对工作目录与 MCP server 数组；及时持久化返回的 session ID。
4. 恢复时根据能力调用 `session/load`，将历史回放转换为消息；发送新提示前的回放不能混入当前运行。
5. 调用 `session/prompt`，处理 `session/update`；原始 prompt 响应携带停止原因，作为该轮结束依据。
6. 取消先发送 `session/cancel`，将待处理权限请求回复为 cancelled，等待有界宽限期；超时关闭连接并终止进程。
7. 进程退出或协议错误使相关请求失败；每个运行由 `AgentHost` 恰好产生一次结束事件。

同一会话串行运行。连接中的事件按 session ID 路由，禁止跨会话串流。会话加载、提示与取消之间需要明确状态，防止迟到响应覆盖新的运行。

## 事件与权限

| ACP 更新 | Disco 语义 |
| --- | --- |
| `agent_message_chunk` | 文本增量 |
| `agent_thought_chunk` | 思考增量 |
| `tool_call` / `tool_call_update` | 按 toolCallId 合并工具状态、输入、输出和变更内容 |
| `plan` | 待办列表，不代表 agent 支持可切换的 Plan 模式 |
| `user_message_chunk` | 历史回放中的用户消息 |
| `config_option_update` / `current_mode_update` | 更新会话配置状态 |

工具更新是部分更新，缺失字段不能清空已有字段。文本优先使用协议提供的 message ID，未提供时按流顺序组织。未知可选更新不应让整轮失败。

`session/request_permission` 的选项由 agent 提供。回复必须使用提供的 optionId，不能假定存在固定的 approve/reject 字符串，也不能将一次批准升级为永久批准。简单允许/拒绝可映射现有审批界面；不能无损映射的多选项应使用统一的选项交互模型。取消时回复 cancelled outcome。

## 历史与能力降级

当前 SQLite 不缓存消息，`AgentHost.loadMessages` 委托后端恢复历史。支持 `loadSession` 的 ACP agent 可以沿用此边界，通过回放重建 `ConversationMessage`。

不支持恢复的 agent 仅能保证活跃进程中的会话连续性。不能静默创建新会话并冒充恢复成功。若产品要求这类 agent 重启后仍可查看聊天，需要另行增加本地消息存储；本地可查看不等于 agent 恢复了上下文。

模型和模式通常随会话建立返回。不能为了设置页刷新模型而不断创建远端空会话，也不能把 Codex 的 sandbox 或 reasoning 枚举直接发送给 ACP agent。先允许默认配置，再按实际返回的配置逐项展示。

首版可以不声明客户端文件系统和终端委托能力，让支持本地执行的 agent 自行操作文件和命令；需要委托能力的 agent 必须明确报告兼容性限制。后续实现这些能力时，再声明对应 capability。

## 实施顺序与验收

1. 调整 agent 身份与配置模型，验证旧数据库与多个 ACP 配置的会话隔离。
2. 实现 ACP 连接与后端，覆盖握手、流式更新、历史加载、权限、取消和退出。
3. 接入设置与模型选择，允许默认模型，并按真实能力控制可用选项。
4. 使用可控的 mock stdio agent 测试长请求、部分更新、字符串请求 ID、权限取消、进程崩溃、版本不兼容和历史回放。
5. 实际运行 macOS 应用检查 hover、点击、展开、菜单与键盘交互；使用已安装并已登录的 Kimi、pi 适配器验证多轮对话与重启恢复。

## 参考资料

- [ACP 初始化与能力协商](https://agentclientprotocol.com/protocol/v1/initialization)
- [ACP 会话创建与恢复](https://agentclientprotocol.com/protocol/v1/session-setup)
- [ACP 提示轮次与取消](https://agentclientprotocol.com/protocol/v1/prompt-turn)
- [ACP 工具调用与权限](https://agentclientprotocol.com/protocol/v1/tool-calls)
- [Kimi ACP 命令](https://www.kimi.com/code/docs/en/kimi-code-cli/reference/kimi-acp)
- [pi-acp 适配器](https://github.com/victor-software-house/pi-acp)

核对日期：2026-09-05。具体功能以启动后的协议协商结果为准。
