# disco 接入 Kimi Code 调研

> 调研日期：2026-08-09  
> 结论基线：Kimi Code CLI 0.34.0；ACP stable v1（`protocolVersion = 1`）  
> 一手资料：Kimi Code 官方文档与官方仓库、Agent Client Protocol 官方规范。仓库源码链接固定到 Kimi Code commit [`01c74e9`](https://github.com/MoonshotAI/kimi-code/tree/01c74e9372fcbbbe99614e859b53b505ed1664a8)，避免 `main` 后续变化导致结论漂移。

## 结论摘要

> 实施更新（2026-08-09）：项目已按后续决策先新增独立 `OpenAIChatCompletionsProvider`，并以 “Kimi Code” 服务商接入 `https://api.kimi.com/coding/v1`。这完成了模型聊天与推理链路；下述 ACP 推荐仍适用于未来需要 Kimi CLI 完整 Agent、工具、审批和 session 能力的阶段。

推荐把 **`kimi acp` 子进程接成新的 `KimiCodeRuntime`**，并复用/抽取现有 Codex transport 的“子进程 + JSONL + JSON-RPC + request 路由”基础设施。ACP 正是 Kimi 官方给 IDE/客户端的集成入口，覆盖初始化、鉴权、session 新建/恢复、prompt、流式文本和思考、工具状态、diff、审批、取消与动态模型/模式配置。[Kimi ACP 官方说明](https://www.kimi.com/code/docs/en/kimi-code-cli/reference/kimi-acp.html)

其他路线不适合作为 disco 当前阶段的正式 Kimi Code Runtime：

1. **直接调用 Kimi Code API** 只能得到模型推理能力，不包含 Kimi CLI 的 Agent 循环、工具、审批和本地 session。更重要的是，Kimi Code 的 OpenAI-compatible API 是 `/chat/completions`，而 disco 当前 `OpenAIResponsesProvider` 固定调用 `/responses`；官方也明确说明 Chat Completions 与 Responses 不兼容。因此它不能靠替换 Base URL 直接接入，至少要新增 Chat Completions Provider；若要成为 coding agent，还要由 disco 自己实现完整 Generic 工具循环。[Kimi Code API 端点](https://www.kimi.com/code/docs/en/#api-access)、[官方 Codex 接入说明中的协议差异](https://www.kimi.com/code/docs/en/third-party-tools/codex.html#how-it-works)
2. **`kimi -p --output-format stream-json`** 适合作为安装探测、真实 smoke test 或一次性批处理，不适合作为交互 Runtime。它在 print mode 下固定使用 auto 权限，不向用户请求审批；JSONL 不输出 thinking，工具进度仍写 stderr，机器可读事件也比 ACP 粗。[`kimi` 命令参考](https://www.kimi.com/code/docs/en/kimi-code-cli/reference/kimi-command.html#non-interactive-execution)
3. **Kimi Agent SDK** 是官方提供的程序化 Runtime 客户端，能够复用 CLI 配置、工具、Skills 和 MCP，并暴露 session、流式事件、工具与审批；但目前只提供 Go、Node.js 和 Python，没有 Swift。disco 若采用它，仍需维护一个桥接 helper 及第二套 IPC，而 ACP 已经提供面向 IDE/桌面客户端的标准 stdio 边界。[Kimi Agent SDK 官方仓库](https://github.com/MoonshotAI/kimi-agent-sdk)

建议实施顺序是：先完成 ACP 只读纵向链路，再接工具卡片/diff/审批，最后让 disco 通过 ACP 的 FS/Terminal reverse-RPC 托管文件和命令执行。不要在 UI 尚不能响应 `session/request_permission` 时开放会产生副作用的 turn。

## 与 disco 当前架构的关系

disco 已有正确的 Runtime seam：`AgentRuntime` 对 UI 暴露统一事件，`CodexRuntime` 在 seam 后消费 `codex app-server`，`GenericAgentRuntime` 则消费无状态 `ModelProvider`。Kimi Code CLI 自带完整 Agent 循环，所以它应与 Codex 一样落在 Runtime Adapter 一侧，而不是塞入 Provider。

当前有三个直接差距：

- `OpenAIResponsesProvider` 固定 POST `<baseURL>/responses`，Kimi Code API 则是 `<baseURL>/chat/completions`；现有 Responses SSE DTO 不能复用。
- 当前 `AgentEvent` 只有文本、reasoning、hosted web tool、citation 和终止事件，还没有计划、通用 tool item、命令输出、diff、审批、usage。这正好对应 `coding-agent-implementation-plan.md` Phase A/B 要补的领域能力。
- `CodexAppServerTransport` 已解决任意字节分片的 LF framing、pending request、超时、EOF 和重连，但 envelope 目前把 request ID 固定为 `Int`，并且 DTO 是 Codex 专用。ACP/JSON-RPC 允许数字或字符串 ID，且 Agent 会反向向 Client 发 request，不能只处理单向 notification。

实现前应继续遵守项目已有的不变量：每个 `start(request:)` 恰好发射一个 `runCompleted` / `runFailed` / `runCancelled`，随后流结束；任何 ACP method、request ID 和 wire discriminator 都不得进入 SwiftUI 分支。

## 主要路线比较

| 维度 | Kimi Code API → `ModelProvider` | `kimi -p` 非交互子进程 | Kimi Agent SDK + helper | `kimi acp` → `AgentRuntime` |
| --- | --- | --- | --- | --- |
| 得到的能力 | 模型推理 | Kimi 完整 Agent，但一次 prompt/进程 | Kimi 完整 Runtime，事件语义最丰富 | Kimi 完整、长连接、多 session Agent |
| 协议 | OpenAI-compatible Chat Completions | stdout/stderr + 可选 JSONL | Go/Node/Python SDK；disco 还需自定义 IPC | 双向 JSON-RPC 2.0 / NDJSON stdio |
| Swift 支持 | disco 自行实现 | 直接用 `Process` | **无官方 Swift SDK** | 直接用 `Process` + `Codable` |
| 鉴权 | Kimi Code Console API Key | 复用 CLI OAuth 或 CLI provider 配置 | 复用 CLI 配置与凭据 | 复用 CLI OAuth/provider 配置，握手返回 auth method |
| 会话 | disco 自己保存消息 | `-r/--session`、`-c/--continue` | create/resume/list/history | `session/new/load/resume/list`，能力门控 |
| 文本流 | Chat Completions SSE | JSONL 是按 Assistant/Tool message 输出，不是细粒度文本 delta | SDK 原生流式事件 | `agent_message_chunk` delta |
| reasoning | 要自行解析 `reasoning_content` | stream-json 明确不输出 thinking | SDK 原生事件 | `agent_thought_chunk` |
| 工具与 diff | 仅模型 tool call，执行循环由 disco 自建 | Agent 自动执行，但 JSONL 展示信息较粗 | 工具、审批和自定义工具均可编排 | `tool_call*`、结构化 diff、locations/raw input/output |
| 用户审批 | disco 自建 | 不支持；print mode 固定 auto | SDK approval handler | `session/request_permission` reverse-RPC |
| 取消 | 取消 URLSession 请求 | 发 signal，进程结束 | SDK context/session cancel | `session/cancel`，等待原 prompt 返回 `cancelled` |
| 适合用途 | 普通聊天/未来 Generic Runtime | smoke test、脚本、降级诊断 | 非 Swift 宿主、服务端自动化或未来 helper | **原生 disco 正式集成（推荐）** |

## 路线一：Kimi Code API 作为 ModelProvider

### 接口、认证与计费边界

Kimi Code API 的 OpenAI-compatible Base URL 是 `https://api.kimi.com/coding/v1`，常用完整端点是 `https://api.kimi.com/coding/v1/chat/completions`；API Key 从 Kimi Code Console 创建，按 Kimi 会员权益和限流计量。Kimi Open Platform 则使用 `https://api.moonshot.cn/v1` 和另一套 Key，按量付费；两套 Key/Base URL 不能互换。[Kimi Code 概览与平台对比](https://www.kimi.com/code/docs/en/#platform-comparison)、[认证错误说明](https://www.kimi.com/code/docs/en/kimi-code/error-reference.html#invalid-authentication)

截至调研日，Kimi Code 对外提供 `k3`、`k3-256k`、`kimi-for-coding`、`kimi-for-coding-highspeed` 等模型 ID，具体可用性、上下文和速度取决于会员层级；Kimi Chat Completions 使用顶层 `thinking: { type, effort }` 控制思考，K3 的 effort 档位包括 `low/high/max`。模型列表和权益会变化，应动态获取或由用户配置，不要固化在 Swift enum 中。[模型配置](https://www.kimi.com/code/docs/en/kimi-code/models.html)

官方要求第三方工具保留真实客户端身份标识，篡改 User-Agent 可能导致会员权益被暂停。若 disco 直接调用会员 API，应使用真实的 `disco/<version>` 标识，并在发布前确认 Kimi Code 的产品集成条款；官方把 Kimi Code 定位为终端/IDE coding agent 权益，把“自己的产品/企业调用”引导到 Kimi Platform。[Kimi Code API Access](https://www.kimi.com/code/docs/en/#api-access)

### 在 disco 中需要做什么

不能修改现有 `OpenAIResponsesProvider` 的 Base URL 就宣称完成接入。若保留这条路线，应新增独立 `OpenAIChatCompletionsProvider`（或更窄的 `KimiChatCompletionsProvider`），实现：

- `/models` 与 `/chat/completions` 请求；
- Chat Completions SSE `[DONE]` framing；
- `content`、`reasoning_content`、streamed `tool_calls`、finish reason 和错误体；
- thinking turn 中 assistant tool-call message 必须回传 `reasoning_content`，否则 Kimi 会返回 400。[Kimi 错误参考](https://www.kimi.com/code/docs/en/kimi-code/error-reference.html#missing-reasoning-content-field)

即便完成 Provider，它仍只是 transport。要获得代码读写/命令能力，disco 还必须按蓝图实现 Generic Agent Runtime、Tool Host、审批、workspace policy、工具结果回灌与多 step 终止判定。这条路线的长期价值是支持不安装 CLI 的 API-Key 模式，但它不是最快获得“Kimi Code 产品能力”的路径。

## 路线二：启动 `kimi` CLI 非交互模式

### 安装与发现

官方推荐 macOS/Linux 安装脚本：

```bash
curl -fsSL https://code.kimi.com/kimi-code/install.sh | bash
```

也可在 Node.js 22.19+ 下全局安装 `@moonshot-ai/kimi-code`。安装后以 `kimi --version` 验证。[官方安装说明](https://www.kimi.com/code/docs/en/kimi-code-cli/guides/getting-started.html#installation)、[官方仓库 README](https://github.com/MoonshotAI/kimi-code/blob/01c74e9372fcbbbe99614e859b53b505ed1664a8/apps/kimi-code/README.md)

macOS GUI App 通常不会继承 terminal shell 的完整 PATH，Kimi 官方也要求 IDE 在这种情况下使用 `which kimi` 得到的绝对路径。disco 的发现顺序建议是：用户显式配置路径 → 当前进程 PATH → `~/.kimi-code/bin/kimi` → `~/.local/bin/kimi` → `/opt/homebrew/bin/kimi` → `/usr/local/bin/kimi`；找到后运行 `--version`，不要用“文件存在”代替可执行与协议探测。[Kimi IDE 路径提示](https://www.kimi.com/code/docs/kimi-code-cli/guides/ides.html)

本机核对结果是 `~/.kimi-code/bin/kimi`、版本 `0.34.0`。这是环境事实，不应硬编码为所有用户的路径。

### 会话、输出、取消与限制

一次性运行方式为：

```bash
kimi -p "分析这个仓库" --output-format stream-json
kimi -r <session-id> -p "继续修改" --output-format stream-json
```

CLI 支持 `--session/-r` 恢复指定 session、`--continue` 恢复当前 cwd 最近 session、`--model` 覆盖模型；stream-json stdout 会输出 Assistant message、带 `tool_calls` 的 Assistant message、Tool message，以及 session resume hint 等 meta 行。[`kimi` 命令参考](https://www.kimi.com/code/docs/en/kimi-code-cli/reference/kimi-command.html)

源码显示 stream-json 的 wire 更接近“可机器读取的 transcript”，不是完整事件总线：Assistant 文本先缓存再按消息 flush；thinking 被丢弃；工具调用和结果有结构化行；provider retry 与 resume hint 是 meta 行。[stream-json renderer 源码](https://github.com/MoonshotAI/kimi-code/blob/01c74e9372fcbbbe99614e859b53b505ed1664a8/apps/kimi-code/src/cli/prompt-render.ts)

这条路线最大的产品阻断是权限：`-p` 创建/恢复 session 后会强制设置 `auto` permission，approval handler 直接批准，question handler 直接 dismiss；官方命令文档也明确 `--prompt` 不能与 `--auto/--yolo/--plan` 组合。[print mode 源码](https://github.com/MoonshotAI/kimi-code/blob/01c74e9372fcbbbe99614e859b53b505ed1664a8/apps/kimi-code/src/cli/run-prompt.ts)、[`kimi` flag 冲突规则](https://www.kimi.com/code/docs/en/kimi-code-cli/reference/kimi-command.html#flag-conflict-rules)

取消只能终止这次 CLI 进程：SIGINT/SIGHUP/SIGTERM 分别映射 130/129/143，并在退出前做清理；这不如 ACP 的 session 级 cancel，且一进程一 prompt 会反复初始化运行时。[signal 清理源码](https://github.com/MoonshotAI/kimi-code/blob/01c74e9372fcbbbe99614e859b53b505ed1664a8/apps/kimi-code/src/cli/run-prompt.ts#L422-L461)

因此建议只把它用于：

- 安装后验证 `kimi` 能调用模型；
- opt-in 真实 smoke test；
- ACP 协议异常时的诊断命令；
- 用户明确接受 auto 权限的一次性批处理，而不是 disco 默认交互链路。

## 路线三：`kimi acp` 作为 AgentRuntime（推荐）

### 进程与 framing

`kimi acp` 不输出 banner，启动后等待 `initialize`；协议消息只走 stdout，日志写 stderr 和 `~/.kimi-code/logs/`。[Kimi ACP 入口](https://www.kimi.com/code/docs/en/kimi-code-cli/reference/kimi-acp.html)

ACP stable v1 的 stdio transport 是 UTF-8、单行 JSON-RPC 2.0、LF (`\n`) 分帧，消息内部不得含实际换行；Client 启动 Agent 子进程，写 stdin、读 stdout，stderr 可单独捕获日志。[ACP transport 规范](https://agentclientprotocol.com/protocol/v1/transports)

这与当前 Codex `LineProcess` 很接近，但 ACP 是真正双向 RPC：等待 `session/prompt` response 时，Kimi 可能向 disco 发 `session/request_permission`、`fs/*`、`terminal/*`。读循环必须持续排空，写入必须串行；否则 await prompt 时会和审批互相死锁。

### 初始化与能力协商

首包应为：

```json
{
  "jsonrpc": "2.0",
  "id": 0,
  "method": "initialize",
  "params": {
    "protocolVersion": 1,
    "clientCapabilities": {},
    "clientInfo": {
      "name": "disco",
      "title": "Disco",
      "version": "0.1.0"
    }
  }
}
```

Client 发自己支持的最新版本；若 Agent 返回 disco 不支持的版本，必须关闭连接并提示升级。所有未出现的 capability 都按“不支持”处理；新增 capability 是非 breaking change，因此绝不能仅根据某个 CLI 版本硬编码能力。[ACP initialization 规范](https://agentclientprotocol.com/protocol/v1/initialization)

这个要求对 Kimi 尤其重要：官网当前 capability matrix 仍描述较旧的 adapter（例如 `session/close`、`logout`、terminal reverse-RPC 尚未连接），但 0.34.0 默认使用新的 `packages/acp-server`。本机实际 initialize 与对应官方源码均显示 `protocolVersion=1`，并声明 `loadSession`，以及 list/resume/close/delete/fork/additionalDirectories、auth.logout 等能力。[0.34.0 initialize 源码](https://github.com/MoonshotAI/kimi-code/blob/01c74e9372fcbbbe99614e859b53b505ed1664a8/packages/acp-server/src/server.ts#L177-L226)

实现策略应是“stable v1 DTO + 动态 capability gate + unknown update/raw JSON 容错”，不要照抄官网矩阵生成静态 feature flag。

### 鉴权

Kimi CLI 首次使用可运行 `kimi login`，通过 RFC 8628 device-code flow 登录；凭据写入 CLI 自己的数据目录。`KIMI_CODE_HOME` 默认是 `~/.kimi-code`，其中 OAuth credentials 目录为 0700、文件为 0600。[登录命令](https://www.kimi.com/code/docs/en/kimi-code-cli/reference/kimi-command.html#kimi-login)、[数据目录](https://www.kimi.com/code/docs/en/kimi-code-cli/configuration/data-locations.html)

ACP initialize 会返回 terminal 类型的 `login` auth method；0.34.0 的 first-class 路径是把 `--login` 追加到已配置的 `kimi acp` 命令，legacy `_meta['terminal-auth']` 则给出绝对 `kimi` 路径和 `login` 参数。`authenticate(methodId: "login")` 只重新验证磁盘上是否已有可用凭据，不会在无 TTY 的 ACP stdio 内部发起交互登录。[Kimi terminal auth 源码](https://github.com/MoonshotAI/kimi-code/blob/01c74e9372fcbbbe99614e859b53b505ed1664a8/packages/acp-server/src/auth-methods.ts)

disco 不应读取或复制 Kimi credential 文件。建议 UI 在收到 JSON-RPC `authRequired (-32000)` 时提供“登录 Kimi Code”动作：用同一绝对 executable 和同一 `KIMI_CODE_HOME` 启动 `kimi login`（最好在可见 Terminal 中），成功后调用 `authenticate("login")` 并重试 session 操作。高级用户若用 Kimi Platform API Key，应让 CLI 自己管理 `config.toml`，disco 仍只消费 ACP 状态。

### Session 新建与恢复

新会话：

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "session/new",
  "params": {
    "cwd": "/absolute/workspace/path",
    "mcpServers": []
  }
}
```

`cwd` 必须是绝对路径，`mcpServers` 必须提供数组（可为空）。响应至少有 `sessionId`，通常还带 `configOptions`。恢复时：

- `session/load` 会在 response 前通过 `session/update` 重放完整历史；适合 UI 没有本地 transcript 的客户端。
- `session/resume` 恢复上下文但不重放历史；disco 已持久化会话消息时更合适，可避免重复渲染。
- 两者都必须先检查 initialize capabilities；不存在 resume capability 时回退 load，并在 load 期间去重历史事件。

[ACP Session Setup](https://agentclientprotocol.com/protocol/v1/session-setup)、[Kimi session 持久化](https://www.kimi.com/code/docs/en/kimi-code-cli/guides/sessions.html)

每个 disco conversation 应保存 Kimi `sessionId`，含义类似当前 codex thread ID，但最终应收回 Runtime 专有配置而不是继续扩展 `AgentRunRequest.resumeThreadID`。一条 `kimi acp` 连接可以承载多个 session，建议由 `AppState` 共享 transport、每个 conversation 持有自己的 `KimiCodeRuntime` 和 session ID；进程重启后按 generation 逐个 resume。

### Prompt、流式事件与终止

`session/prompt` 是长时 request；用户内容放入 `prompt: ContentBlock[]`。文本和 `resource_link` 是 baseline，image/resource 等必须按 `promptCapabilities` 发送。过程事件都通过并发 `session/update` notification 到达，最终 `session/prompt` response 的 `stopReason` 才是 turn 终止信号。[ACP Prompt Turn](https://agentclientprotocol.com/protocol/v1/prompt-turn)

Kimi 当前映射的核心 update 包括：

| ACP update | disco 领域映射 |
| --- | --- |
| `agent_message_chunk` | `messageDelta` |
| `agent_thought_chunk` | `reasoningDelta` |
| `tool_call` / `tool_call_update` | `AgentItemSnapshot` / `itemOutput` |
| `plan` | `PlanSnapshot` |
| `config_option_update` | Runtime 配置状态 |
| `available_commands_update` | slash command 能力（后续） |
| `session_info_update` | 会话标题等元数据 |
| `usage_update` | `UsageSnapshot` |

Kimi 0.34.0 新 ACP server 会在 turn 结束后尽力发送 `usage_update`（context used/size，不含 cost）；解析应容忍缺失。[Kimi usage update 源码](https://github.com/MoonshotAI/kimi-code/blob/01c74e9372fcbbbe99614e859b53b505ed1664a8/packages/acp-server/src/session.ts#L916-L944)

`stopReason` 映射建议：`end_turn → completed`，`cancelled → cancelled`，`refusal/max_tokens/max_turn_requests → failed`（给出用户可读原因）。需要注意 Kimi 当前源码会把非鉴权的内部 `turn.ended(reason: failed)` 映射为 `end_turn` 并只写日志；因此“有部分文本后失败”可能在 ACP 上看起来像正常结束。这是上游可观测性缺口，disco 应 pin 已测试 CLI 版本、保留脱敏 stderr 尾部用于诊断，并通过合约测试防止误判扩大。[Kimi stopReason 映射源码](https://github.com/MoonshotAI/kimi-code/blob/01c74e9372fcbbbe99614e859b53b505ed1664a8/packages/acp-server/src/events-map.ts#L39-L70)

### 工具、diff 与审批

工具卡片通过 `tool_call` 创建、`tool_call_update` patch；状态包括 pending/in_progress/completed/failed，内容可包含文本、结构化 diff 或 terminal 引用，另有 locations、rawInput/rawOutput。[ACP Tool Calls](https://agentclientprotocol.com/protocol/v1/tool-calls)

Kimi 会把 `Write/Edit` 的 diff/file_io display 转成 ACP diff：`path + oldText + newText`；这是“已经/正在由 Agent 工具执行的展示数据”，disco 不能收到 diff 后再自行应用一次。[Kimi diff 转换源码](https://github.com/MoonshotAI/kimi-code/blob/01c74e9372fcbbbe99614e859b53b505ed1664a8/packages/acp-server/src/convert.ts)

有副作用的工具会反向请求：

```json
{
  "jsonrpc": "2.0",
  "id": 42,
  "method": "session/request_permission",
  "params": {
    "sessionId": "...",
    "toolCall": { "toolCallId": "..." },
    "options": [
      { "optionId": "approve_once", "name": "Approve once", "kind": "allow_once" },
      { "optionId": "approve_always", "name": "Approve for this session", "kind": "allow_always" },
      { "optionId": "reject", "name": "Reject", "kind": "reject_once" }
    ]
  }
}
```

Client 必须回同一 request ID，并返回 Agent 提供的 opaque `optionId`，不能自行构造“看起来等价”的值。Kimi 还复用同一通道承载 plan review 和 AskUserQuestion；因此 `coding-agent-implementation-plan.md` 当前只含固定 `ApprovalDecision` 的草案不够完整，领域层至少要保留 provider option ID、label、kind，或把“权限决策”和“用户问题选择”建成可扩展 choice 模型。[Kimi approval 映射源码](https://github.com/MoonshotAI/kimi-code/blob/01c74e9372fcbbbe99614e859b53b505ed1664a8/packages/acp-server/src/approval.ts)、[ACP permission 规范](https://agentclientprotocol.com/protocol/v1/tool-calls#requesting-permission)

如果 disco 尚未实现审批 UI，最安全行为是立即返回 cancelled/reject 并让 turn 继续收束，不能忽略 request；忽略会让 Kimi 永久等待。

### 取消

取消正在运行的 prompt 要发送无 ID notification：

```json
{
  "jsonrpc": "2.0",
  "method": "session/cancel",
  "params": { "sessionId": "..." }
}
```

同时要把本轮所有 pending `session/request_permission` 响应为 `{ outcome: { outcome: "cancelled" } }`，继续接收尾部 update，并等待原 `session/prompt` 返回 `stopReason: cancelled` 后才发 `runCancelled`。ACP 明确允许 cancel 后、prompt response 前仍有 update；提前关闭流会丢终态并破坏“一次终止事件”不变量。[ACP cancellation 规范](https://agentclientprotocol.com/protocol/v1/prompt-turn#cancellation)

若取消超时或子进程失联，Runtime 才以 transport failure 兜底。不要把用户取消映射成 `runFailed`。

### 文件与命令执行边界

ACP Client 可在 initialize 声明：

```json
{
  "clientCapabilities": {
    "fs": { "readTextFile": true, "writeTextFile": true },
    "terminal": true
  }
}
```

声明 FS 后，Agent 可反向调用 `fs/read_text_file`、`fs/write_text_file`，disco 就能在 Tool Host 内做标准化路径、真实路径、workspace root 和写权限校验；未声明 capability 时 Kimi 在本进程本地文件系统执行。[ACP File System](https://agentclientprotocol.com/protocol/v1/file-system)

这里存在明显版本差异：官网较旧矩阵写 terminal reverse-RPC 未连接，但 Kimi 0.34.0 默认的新 ACP server 已实现 capability-gated terminal bridge。Client 声明 `terminal: true` 后，Bash 会走 `terminal/create → output polling → wait_for_exit/kill/release`；不声明时回退 Kimi 子进程本地 spawn。[Kimi 0.34 terminal bridge](https://github.com/MoonshotAI/kimi-code/blob/01c74e9372fcbbbe99614e859b53b505ed1664a8/packages/acp-server/src/acp-terminal/acpTerminalRunner.ts)、[ACP Terminal 规范](https://agentclientprotocol.com/protocol/v1/terminals)

建议：

1. Phase A 明确不声明 FS/terminal，模式设为 `plan`，并拒绝一切副作用审批，用于先打通只读分析；这不是强 sandbox，read-only 工具仍由本地 Kimi 进程执行。
2. Tool Host 的路径/进程/输出上限完成后，分别声明受支持的 capability。ACP terminal 是“声明即承诺全部 terminal 方法”，不能只实现 create 而省略 kill/release。
3. 开放写与命令前做真实根目录校验、环境变量 allowlist、4 MiB 之外的自身输出上限、取消/释放竞态测试；不要仅依赖模型传入的 cwd 或审批文字。

Kimi 内置默认规则是 Read/Grep/Glob 自动允许，Write/Edit/Bash 要审批；Plan mode 限制 Write/Edit 只能写 plan file，但 Bash 仍按普通权限规则，因此 Plan mode 不能替代 Tool Host 或审批。[Kimi 内置工具与 Plan mode](https://www.kimi.com/code/docs/en/kimi-code-cli/reference/tools.html)

### 模型、thinking 与模式

不要在启动 `kimi acp` 时传 `-m`；ACP session 的可选配置来自 `session/new/load/resume` response 的 `configOptions`，再用 `session/set_config_option` 设置。Kimi 当前使用三个 select：

- `configId = model`：动态模型 alias；
- `configId = thinking`：off/on 或具体 effort；
- `configId = mode`：default/plan/auto/yolo。

[Kimi configOptions 源码](https://github.com/MoonshotAI/kimi-code/blob/01c74e9372fcbbbe99614e859b53b505ed1664a8/packages/acp-server/src/config-options.ts)

disco 应按返回 options 渲染并保存选择值，session 建立后按顺序设置 model/thinking/mode，再开始 prompt；收到 `config_option_update` 时以完整 snapshot 覆盖本地状态。首期只允许 `default`（有审批）和 `plan`，不要暴露 auto/yolo，直到产品明确呈现其风险。

### 错误、EOF 与进程退出

ACP 使用标准 JSON-RPC error，并定义 `-32000 auth required`、`-32800 request cancelled`、`-32002 resource not found` 等；解析器必须允许未知整数 code。[ACP schema](https://github.com/agentclientprotocol/agent-client-protocol/blob/main/schema/v1/schema.json)、[ACP error handling](https://agentclientprotocol.com/protocol/v1/overview#error-handling)

建议错误边界：

- `-32000` → 需要登录，不做自动重试风暴；
- `-32602` → 配置/session 参数错误，展示可修复信息；
- prompt `refusal/max_*` → 本轮失败；
- stdout 非法行、EOF、子进程 exit → connection failure，一次性失败所有 pending requests/runs，清理 permission continuation，generation + 1；
- stderr 与 `~/.kimi-code/logs` 只用于诊断，展示前截断和脱敏，不自动上传；
- 重连后重新 initialize，并按 conversation 持久化 session ID resume。

ACP v1 没有统一 shutdown RPC。正常退出时应停止新 request，取消 active prompt，给 pending reverse-RPC 收尾，关闭 stdin，短暂等待，再 terminate；异常 EOF 不能把 pending continuation 留悬挂。

## 推荐实现形态

建议新增/调整（名称供实现阶段采用，不是本次代码改动）：

```text
AgentRuntime/
├── JSONLineProcess.swift          # 从 Codex transport 抽出的通用 LF 子进程
├── JSONRPCConnection.swift        # 双向 envelope、ID、pending、timeout、reverse request
├── KimiACPProtocol.swift          # ACP stable v1 DTO + unknown/raw fallback
├── KimiACPTransport.swift         # initialize/auth/session/prompt/cancel/capability gate
└── KimiCodeRuntime.swift          # ACP update → AgentEvent、终止事件不变量
```

模块边界：

- `JSONRPCConnection` 不知道 Codex/Kimi method；只负责完整 duplex RPC。
- `KimiACPTransport` 保存一条进程连接和 `sessionId → active prompt` 路由，处理 reverse-RPC。
- `KimiCodeRuntime` 每 conversation 一个，保存 session ID、connection generation、模型/模式配置，并将 wire 事件翻译成领域事件。
- `AppState` 连接级共享 transport；会话删除只释放自己的 session/runtime，App 退出才杀共享进程。
- 协议 DTO 声明已测试 CLI 版本 `0.34.0`、ACP protocol 1、对应官方 SDK `0.23.0`；升级 CLI 时先跑合约 fixtures，再更新能力基线。[Kimi protocol version 源码](https://github.com/MoonshotAI/kimi-code/blob/01c74e9372fcbbbe99614e859b53b505ed1664a8/packages/acp-server/src/version.ts)

`kimi web` 还提供本地 REST + WebSocket/OpenAPI/AsyncAPI，但它需要动态端口发现和 bearer token 管理，并暴露更大的本地 HTTP 攻击面；官方已有专门面向 IDE 的 `kimi acp`，所以 web 模式不应作为首选。可保留为未来跨进程/远程 UI 需求的备选。[`kimi web` 官方参考](https://www.kimi.com/code/docs/en/kimi-code-cli/reference/kimi-command.html#kimi-web)

## 分阶段交付建议

### Phase K0：探测与连接合约

- CLI 路径选择、`--version` 与最低/已测版本提示。
- 启动 `kimi acp`，完成 initialize，保存实际 agentInfo/capabilities/authMethods。
- 未登录时展示登录引导；不启动 prompt。
- 脚本化 LineProcess 测 framing、双向 ID、非法 stdout、stderr 隔离、EOF 清理。

完成标准：0.34.0 实机握手成功；返回未知 capability/update 不崩溃；进程退出无悬挂 continuation。

### Phase K1：只读 Agent 纵向链路

- Project/Workspace 先按 `coding-agent-implementation-plan.md` Phase A 落地。
- `session/new/resume`、text/reasoning、plan、tool card（只展示）。
- 模式强制 plan；permission reverse request 一律显式拒绝；不声明 FS/terminal。
- 持久化 session ID；重启后 resume；取消等待 `stopReason: cancelled`。

完成标准：在指定 cwd 概括仓库、显示 Read/Grep/Glob 活动；写/命令请求不会执行；取消恰好一个 cancelled。

### Phase K2：原生审批与 diff

- 扩展领域 `AgentItemSnapshot`、Approval choice、`AgentRuntime.respond`。
- 渲染 tool status、locations、raw args 摘要、结构化 diff。
- approve once/session/reject/cancel；plan review 和 AskUserQuestion 不能被误当成固定三选一。
- pending permission 与 cancel/shutdown/EOF 全部有确定收尾。

完成标准：Write/Edit/Bash 执行前有准确审批；拒绝不产生副作用；重复点击不重复响应 request ID。

### Phase K3：disco Tool Host 托管

- 实现 ACP FS reverse-RPC 并声明精确能力。
- 实现完整 terminal reverse-RPC 后才声明 `terminal: true`。
- 路径 realpath/root policy、env allowlist、输出截断、timeout、kill/release、进程树清理。
- 对比“不声明 capability 的 Kimi 本地执行”与“声明后的 disco 托管”行为。

完成标准：文件和命令都在 disco 的 Workspace/ExecutionPolicy 下执行；越界路径拒绝；取消无孤儿进程。

### Phase K4：稳定性与发布

- session list/load/replay、进程崩溃重连、多 conversation 路由。
- dynamic config options、usage、MCP forwarding（按 capability）。
- opt-in 真实 smoke；记录 CLI/version/capabilities，升级做 schema/fixture diff。
- 明确自动更新策略：Kimi CLI 默认可能升级，disco 必须在未知版本下以握手能力和宽松解码降级，而不是崩溃或自动开放权限。

## 测试建议

### 单元/合约测试（默认 CI，无真实登录）

用类似 `CodexAppServerTestSupport` 的脚本化双向 `LineProcess`，至少覆盖：

1. stdout 任意字节分片、CRLF/LF、多个 JSON 行同 chunk、EOF 剩余半行。
2. initialize 版本相同/不兼容、capability 缺失/未知字段。
3. response 与 notification 交错；Agent reverse request 与 prompt pending 同时发生。
4. new/load/resume；load history updates 先于 response；多 session 事件隔离。
5. agent text/thought delta，tool create/patch，diff，plan，usage，unknown update。
6. permission approve/reject/cancel、重复响应、未知 option、plan/question choice。
7. cancel 时先收束 permission，再等 prompt cancelled；cancel 后尾部 update 仍接收。
8. prompt error、authRequired、invalid params、无文本 end_turn、EOF/非法行/进程退出。
9. terminal/FS capability 未声明时绝不接受对应 reverse-RPC；声明后所有方法与路径策略。
10. Runtime 的每个路径都恰好一个终止 AgentEvent。

fixtures 应来自 Kimi 官方 ACP schema/源码形态并固定 CLI 版本，不依赖真实 `~/.kimi-code`。

### opt-in 真实 smoke

建议新增独立开关，例如：

```bash
DISCO_KIMI_INTEGRATION_TESTS=1 xcodebuild test \
  -project disco.xcodeproj \
  -scheme disco \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO
```

最少验证：

1. executable + version；
2. initialize + capability snapshot；
3. auth status / 未登录错误；
4. session/new 指定临时 cwd；
5. 只读 prompt 和 text/thought/tool update；
6. 一个需要审批的写或 Bash，先 reject；
7. 长 turn cancel；
8. 进程重启 + session/resume；
9. 若启用 Tool Host，再测一项 FS write 和 terminal command 的越界拒绝。

真实测试必须使用临时 workspace，默认不在 CI 运行，不读取或打印 credential，不依赖固定模型 entitlement。

## 最终决策

正式产品路线选择 **ACP**。第一版交付边界应是“已登录 Kimi CLI + 指定 workspace + 只读 session + 流式文本/reasoning/tool 展示 + 可取消 + 可恢复”，而不是直接开放写入。审批领域模型和 Tool Host 就绪后，再分两步开放 Kimi 本地执行审批、ACP FS/terminal 托管。

API Provider 可以作为后续补充，但必须新增 Chat Completions 协议实现，并应被命名为“使用 Kimi Code/Kimi Platform 模型”，不能把它描述成已接入 Kimi Code CLI Agent。`kimi -p` 保留为 smoke/诊断工具即可。
