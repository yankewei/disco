# Kimi Code 接入决策记录

> 状态：API Provider 路线已实现；Kimi CLI ACP 路线未实现
> 决策基线：`main@531f128`、Kimi Code API、Kimi Code CLI 0.34.0 / ACP stable v1
> 原文性质：本文件由早期调研整理而来；记录当前决策和未来 ACP 接入边界，不作为已实现能力清单。

## 1. 当前决策

Disco 当前接入的是 **Kimi Code 的 OpenAI-compatible API**，不是 Kimi Code CLI Agent：

- 使用独立的 `OpenAIChatCompletionsProvider`；
- Base URL 为 `https://api.kimi.com/coding/v1`；
- 请求端点为 `/models` 和 `/chat/completions`；
- Kimi 方言使用原生 `thinking` 和 `reasoning_content`；
- API Key 由 Disco 的 Provider 配置和 `AuthFileStore` 管理；
- 只提供模型聊天、推理和 usage，不提供 Kimi CLI 的工具循环、文件修改、命令执行、审批或 CLI session。

因此产品和 UI 文案应称为 **“Kimi Code API / Kimi Code 模型”**，不能称为“已接入 Kimi Code Agent”。

### 为什么先选 API Provider

当前 Disco 已有 Generic Runtime + `ModelProvider` seam，而没有 Project/Workspace、Tool Host、审批和通用工具循环。API Provider 能以较小改动提供 Kimi 模型聊天；直接接入 CLI Agent 则需要完整的双向 ACP transport 和 coding-agent 领域能力。

Responses API 与 Kimi Code API 也不能只通过替换 Base URL 复用：Disco 的 Responses Provider 请求 `/responses`，Kimi Code 要求 `/chat/completions`。因此本次新增独立 Chat Completions Provider，而不是修改 Responses Provider 的端点逻辑。

## 2. 已实现范围

### 2.1 Provider 行为

实现位置：`disco/Providers/OpenAIChatCompletionsProvider.swift`。

- `GET /models` 读取模型 ID 和可选 `context_length`；
- `POST /chat/completions` 使用 SSE 流式解析，也支持非 SSE JSON 响应；
- 支持任意字节分片、`[DONE]` framing 和 `choices` 为空但带 usage 的尾部 chunk；
- 映射 `content` → `ModelEvent.textDelta`；
- 映射 `reasoning_content` → `ModelEvent.reasoningDelta`；
- 发送 `stream_options.include_usage = true`；
- `thinking` 开关和 effort 使用 Kimi 原生字段；
- assistant 历史消息在启用 reasoning 且有内容时回传 `reasoning_content`；
- instructions 以首个 `system` message 注入 Chat Completions；
- Kimi 端点发送 `User-Agent: disco/<version>`；
- tool call 会显式返回 unsupported，而不会假装已经执行工具。

### 2.2 用量与上下文

Provider 解析以下 Chat Completions usage 字段：

- `prompt_tokens`；
- `completion_tokens`；
- `total_tokens`；
- `prompt_tokens_details.cached_tokens` / `cached_tokens`；
- `completion_tokens_details.reasoning_tokens` / `reasoning_tokens`。

上下文窗口优先使用模型目录返回的 `context_length`，用户也可以在设置中按模型填写覆盖值。Generic Runtime 负责上下文压缩和 overflow recovery；Provider 只负责协议解析和错误分类。

### 2.3 当前不提供的能力

以下能力仍属于未来 Kimi CLI ACP 或 Generic Agent 工作，不应在当前 Provider 上隐式实现：

- Kimi CLI OAuth 登录和本地 CLI session；
- `kimi acp` 的双向 JSON-RPC；
- Kimi 内置工具、命令、文件修改和 diff；
- 审批、AskUserQuestion、动态 mode；
- Kimi CLI session resume/load/list；
- Disco Tool Host 托管的 FS/terminal reverse-RPC；
- 多轮 Generic tool loop。

## 3. API 安全与产品边界

- API Key 不写入 UserDefaults、SwiftData 或日志，继续使用项目现有的 `AuthFileStore`。
- 请求必须使用 HTTPS Base URL 校验；不得允许用户配置带 user/password/query/fragment 的 URL。
- Kimi Code API 要求真实客户端身份标识；当前使用 `disco/<version>`，发布前仍需确认 Kimi Code 的产品集成条款和使用边界。
- Kimi Code API 与 Kimi Open Platform 是不同产品/计费边界：`api.kimi.com/coding/v1` 的 Key 不应与 `api.moonshot.cn/v1` 的 Key 混用。
- 模型 ID、上下文窗口和权益可能变化；运行时优先使用 `/models`，不应把动态权益永久固化为 Swift 枚举。

## 4. 未来路线：Kimi CLI ACP

如果 Disco 需要完整的 Kimi CLI Agent，正式候选路线是 `kimi acp` → `KimiCodeRuntime`，而不是 `kimi -p` 或在 Provider 内增加工具循环。

### 4.1 采用 ACP 的原因

Kimi ACP 为 IDE/桌面客户端提供稳定的 stdio 边界，覆盖：

- initialize 和 capability negotiation；
- auth method 与登录引导；
- session new/load/resume/list；
- prompt、文本增量和思考增量；
- tool call、plan、diff、usage；
- permission reverse-RPC；
- session cancel；
- FS/terminal reverse-RPC（由客户端声明 capability 后才启用）。

它是双向 JSON-RPC/NDJSON，不是单向通知流。等待长时间 `session/prompt` 时，Disco 必须持续处理 Agent 发来的 permission、FS 和 terminal request，否则会死锁。

### 4.2 接入前置条件

在 Disco 具备以下能力前，不应开放 Kimi ACP 的副作用操作：

1. Project/Workspace 和可靠的 workspace root 校验；
2. 可扩展 Agent item、tool status、diff 和 usage 领域模型；
3. 审批与用户问答的 pending 状态、竞态和取消收尾；
4. Tool Host 的路径、symlink、环境变量、超时、输出上限和进程树策略；
5. 双向 JSON-RPC connection 的 request ID、timeout、EOF 和多 session 路由；
6. 脚本化 ACP 合约测试，以及显式 opt-in 的真实 CLI smoke test。

推荐阶段：

- **K0**：探测绝对 executable、版本和 initialize capability；不启动 prompt。
- **K1**：只读 session、文本/reasoning、plan 和 tool card 展示；不声明 FS/terminal。
- **K2**：审批、用户问答、diff 和取消竞态。
- **K3**：完整 Tool Host 后，再声明 ACP FS/terminal capability。
- **K4**：session 恢复、多会话隔离、崩溃重连和版本降级。

### 4.3 未来模块边界

建议将来抽取或新增：

```text
AgentRuntime/
├── JSONLineProcess.swift       # 通用 LF 子进程
├── JSONRPCConnection.swift     # 双向 JSON-RPC、ID、pending、timeout
├── KimiACPProtocol.swift       # ACP stable v1 DTO 与 unknown fallback
├── KimiACPTransport.swift      # initialize/auth/session/prompt/cancel
└── KimiCodeRuntime.swift       # ACP update → AgentEvent
```

- 通用 JSON-RPC connection 不知道 Codex/Kimi method；
- ACP transport 处理 session 路由和 reverse-RPC；
- Runtime 把 ACP wire 映射为稳定领域事件；
- UI 不解析 ACP method、request ID 或原始 payload；
- 未声明的 capability 必须按“不支持”处理，未知 update 应可容错。

## 5. 方案取舍

| 路线 | 当前结论 | 原因 |
| --- | --- | --- |
| Kimi Code API → `ModelProvider` | **已采用** | 改动小，复用 Generic Runtime；只提供模型能力 |
| `kimi -p --output-format stream-json` | 不采用为正式 Runtime | 一次 prompt/进程、thinking 不完整，print mode 默认 auto 权限 |
| Kimi Agent SDK + helper | 暂不采用 | 官方 SDK 主要面向 Go/Node/Python，Disco 仍需维护 IPC helper |
| `kimi acp` → `AgentRuntime` | **未来候选** | 能力完整，但必须先完成 workspace、审批、Tool Host 和双向 RPC |

`kimi -p` 可以保留为安装探测、诊断或用户明确接受 auto 权限的一次性 smoke 工具，但不能作为 Disco 默认交互链路。

## 6. 资料来源

以下链接保留为协议升级和 ACP 实施前的复核入口；Kimi CLI/ACP 版本变化时必须重新验证，不要只依赖本记录：

- [Kimi Code API Access](https://www.kimi.com/code/docs/en/#api-access)
- [Kimi Code 模型配置](https://www.kimi.com/code/docs/en/kimi-code/models.html)
- [Kimi Code 错误参考](https://www.kimi.com/code/docs/en/kimi-code/error-reference.html)
- [Kimi ACP 官方说明](https://www.kimi.com/code/docs/en/kimi-code-cli/reference/kimi-acp.html)
- [ACP initialization](https://agentclientprotocol.com/protocol/v1/initialization)
- [ACP session setup](https://agentclientprotocol.com/protocol/v1/session-setup)
- [ACP prompt turn](https://agentclientprotocol.com/protocol/v1/prompt-turn)
- [ACP tool calls / permission](https://agentclientprotocol.com/protocol/v1/tool-calls)
- [ACP file system](https://agentclientprotocol.com/protocol/v1/file-system)
- [ACP terminals](https://agentclientprotocol.com/protocol/v1/terminals)
- [Kimi Code 官方仓库 commit `01c74e9`](https://github.com/MoonshotAI/kimi-code/tree/01c74e9372fcbbbe99614e859b53b505ed1664a8)

### 维护规则

- 修改 Kimi Provider 协议时，先更新实现范围和对应 XCTest fixture。
- 修改产品路线时，先更新“当前决策”和“当前不提供的能力”，避免把 API Provider 与 CLI Agent 混称。
- 开始 ACP 实施时，把本记录中的未来路线拆成独立实现计划，并固定实际 CLI 版本、schema 和合约测试基线。
