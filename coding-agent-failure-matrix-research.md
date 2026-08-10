# Coding Agent 工具循环失败矩阵调研

> 调研日期：2026-08-10
>
> 目的：为 Disco G2-2「失败矩阵加固」确定可测试的运行语义。
>
> 来源边界：只使用 OpenAI、Anthropic、Google 和 Aider 官方文档或官方 GitHub 源码。GitHub 链接固定到本次调研时的 commit；带“推断”字样的内容不是上游项目的明示保证。

## 1. 结论先行

主流 coding agent 的实现细节差异很大，但可以提炼出一个共同安全原则：

> **模型请求可以在 commit point 之前重试；工具一旦可能产生副作用，就不能靠重跑整个 agent round 恢复。**

Claude Code 的官方错误文档直接说明：如果流已经完成一个 text block 或 tool call，mid-stream failure 不会自动重试，因为这可能让工具执行两次。Codex 把唯一明确的工具重试限制在工具内部：首次执行被 sandbox 拒绝、策略允许升级且重新经过审批后，再做一次升级执行，而不是重放整个模型 round。Gemini CLI 虽然允许模型流重试，但工具执行与模型流由独立 scheduler 隔开；Aider 则把模型 API 重试放在 `apply_updates()` 之前，因此网络重试不会重复应用文件编辑。

对 Disco 最重要的不是复制某个产品的所有状态，而是建立三个互不混淆的边界：

1. **Expected tool result**：工具确实完成并得到 `success / failure / declined / cancelled / timed_out`，均应作为结果回给模型；`isTruncated` 是正交标记。
2. **Thrown infrastructure error**：Executor 崩溃、IPC 断开、结果无法编码、协议不可信等，表示没有可靠结果，终止 run；不得伪装成业务失败后让模型继续。
3. **Run cancellation**：用户停止整个 run 时发 `runCancelled`；它不同于某个工具自己的 `cancelled` 结果。后者仍可让模型选择替代方案。

G2-2 建议先采取保守策略：**Runtime 不自动重试任何 ToolExecutor 调用；工具执行后的 follow-up 如果 overflow 或断流，失败但不重放工具。** 对只读、天然幂等工具的局部重试可留给 G3 Tool Host，并且必须限定在同一 call ID、同一次 Executor 调用内部。

## 2. 对比矩阵

| 维度 | OpenAI Codex | Claude Code | Gemini CLI | Aider |
| --- | --- | --- | --- | --- |
| 工具结果 | `FunctionCallOutputPayload` 带正文与可选 `success`；普通工具错误通常转换成失败 output，fatal error 才终止 | Anthropic `tool_result` 以 `tool_use_id` 关联，可用 `is_error` 表示失败 | 内部状态为 validating/scheduled/awaiting approval/executing/success/error/cancelled；回模型统一是 `functionResponse` | 不是通用原生 tool loop；编辑解析/应用错误被转成 reflection 消息 |
| denied/cancelled | 审批拒绝是 `ToolError::Rejected`；turn interrupt 是独立 `TurnAborted` | 权限系统/PreToolUse 可阻止执行并把原因反馈给 Claude；run interrupt 与 tool result 分离 | 用户拒绝转成 cancelled call 和含 error 的 `functionResponse`；run abort 使用 `AbortSignal`/`UserCancelled` | 拒绝创建或编辑未加入 chat 的文件时跳过该 edit；Ctrl-C 保留 partial response 并结束本轮 |
| timeout | 各工具输出自行携带 exit/duration 等；没有统一 `timed_out` tool-result 枚举 | Bash 和 hooks 有独立 timeout 配置；通用 `tool_result` 仍主要靠 `is_error + content` 表达 | scheduler 没有独立 timed-out terminal status；具体工具把 timeout 转成 error/cancelled 内容 | 模型请求有 timeout；API 错误按异常分类处理 |
| truncation | 输出按 token/byte policy 截断，并在文本中插入明确 marker | tool result 是内容块；产品文档未给统一 `truncated` 布尔协议 | shell 输出超阈值保存到文件，模型收到截断内容；`outputFile/contentLength` 留在内部结果 | 主要在上下文与 repo map 层控制大小，没有通用 tool-result 标志 |
| 模型流故障 | Responses 流有有界 retry；新版本还把已尝试工具元数据附到重试 prompt | 连接前/尚无完成 block 可重试；完成 text block 或 tool call 后不重试 | connection phase 指数退避；mid-stream 最多 4 attempts，并重发同一模型 request/history | 可重试 LiteLLM 异常按 0.25、0.5…秒退避，超过 60 秒停止 |
| 工具副作用重放 | sandbox denial 的重试只在 orchestrator 内、至多一次并受审批约束；不是任意 tool retry | 明确避免在 tool-call commit 后重试模型流 | 未发现通用 call-ID 幂等去重；prompt 要求拒绝后不要重新尝试相同行为 | API retry 完成后才 `apply_updates()`，所以网络 retry 不会重放编辑 |
| 循环上限 | 主要由模型/provider/上下文/turn 生命周期约束；未发现统一公开的 max tool calls 配置 | 官方公开资料未发现统一 max tool calls 配置 | `maxSessionTurns` 产生 `MAX_TURNS_EXCEEDED`；另有 loop detector | reflection 最多 3 次；不是通用 max tool calls |
| context overflow | 主动 auto-compaction；tool output 在历史中截断；流 retry prompt 可附已执行工具元数据 | 支持 compact；tool-use/tool-result 必须保持配对 | 请求前压缩/mask tool output；保持 functionCall/functionResponse 相邻；仍超窗就发 overflow 事件并停止该 turn | context exceeded 不重试，展示 exhausted 错误；后台总结历史用于后续轮次 |
| 单一终止 | turn 以 `TurnComplete` 或 `TurnAborted` 收束，任务生命周期统一发出 | SDK/result 消息区分成功、错误、interrupt；公开资料未提供内部 exactly-once guard | `_agentEndEmitted` guard 确保单个 `agent_end`，reason 可为 completed/failed/aborted/max_turns | 没有统一事件协议；Python 控制流通过 return/break 收束一次 send |

矩阵中的“未发现”只表示本次检索的官方公开资料没有足够证据，不代表产品内部绝对没有该能力。

## 3. OpenAI Codex

### 3.1 工具结果与失败分层

**源码事实。** Codex 的 `function_tool_response` 把工具正文编码成 `FunctionCallOutputPayload`，其中有可选 `success`；普通 function-call error 在 tool router 中转换成模型可见的失败 response，只有 `FunctionCallError::Fatal` 上升为 turn-level fatal error。[Codex `tools/context.rs`](https://github.com/openai/codex/blob/d109393270432531ac0010542ae7973801e0d9d7/codex-rs/core/src/tools/context.rs)，[Codex `tools/parallel.rs`](https://github.com/openai/codex/blob/d109393270432531ac0010542ae7973801e0d9d7/codex-rs/core/src/tools/parallel.rs)

**源码事实。** 输出截断不是静默行为：统一 exec 输出保留原始 token 数，截断正文并写入 `Warning: truncated output` 或 `… tokens truncated …` marker；历史中的 function output 也会按模型的 truncation policy 再裁剪。[Codex `tools/context.rs`](https://github.com/openai/codex/blob/d109393270432531ac0010542ae7973801e0d9d7/codex-rs/core/src/tools/context.rs)，[Codex `context_manager/history.rs`](https://github.com/openai/codex/blob/d109393270432531ac0010542ae7973801e0d9d7/codex-rs/core/src/context_manager/history.rs)

**对 Disco 的推断。** 这支持把 `isTruncated` 保持为与 status 正交的字段：成功输出也可能被截断，失败输出同样可能很大。

### 3.2 审批、sandbox denial 与唯一受控重试

**源码事实。** `ToolOrchestrator` 明确集中管理“approval → sandbox → attempt → sandbox denial 后升级重试”。只有错误被识别为 `SandboxErr::Denied`、工具允许 escalation、权限策略允许且必要审批通过时，才创建第二个 attempt；其他工具错误直接返回。严格 auto-review 的首次批准不自动覆盖 unsandboxed retry，后者要重新经过 guardian review。[Codex `tools/orchestrator.rs`](https://github.com/openai/codex/blob/d109393270432531ac0010542ae7973801e0d9d7/codex-rs/core/src/tools/orchestrator.rs)

**源码事实。** 审批策略明确拒绝时返回 `ToolError::Rejected`，不会执行工具。turn 级 interrupt 则走独立 `TurnAborted` 事件，并在事件前持久化 interrupted-turn marker。[Codex `tools/sandboxing.rs`](https://github.com/openai/codex/blob/d109393270432531ac0010542ae7973801e0d9d7/codex-rs/core/src/tools/sandboxing.rs)，[Codex `tasks/mod.rs`](https://github.com/openai/codex/blob/d109393270432531ac0010542ae7973801e0d9d7/codex-rs/core/src/tasks/mod.rs)

**对 Disco 的推断。** “retry tool”必须是 Tool Host 能证明安全的特例，而不是 Runtime 遇到任意错误后的默认行为。G2-2 不应实现泛化重试。

### 3.3 模型流 retry 与已执行工具记录

**源码事实。** Codex 的 sampling request 按 provider `stream_max_retries` 重试 retryable stream error。当前源码维护 `ExecutedToolCallRecorder`：工具调度前记录 call，发生 sampling retry 时将 pending/retained 的已执行工具 metadata 附到新 prompt，并对数量和参数字节设上限。[Codex `session/turn.rs`](https://github.com/openai/codex/blob/d109393270432531ac0010542ae7973801e0d9d7/codex-rs/core/src/session/turn.rs)，[Codex `tools/executed_tool_calls.rs`](https://github.com/openai/codex/blob/d109393270432531ac0010542ae7973801e0d9d7/codex-rs/core/src/tools/executed_tool_calls.rs)

**源码事实。** recorder 自己标注为 best-effort attempted-tool metadata；取消、压缩等场景可能留下未报告记录。它是在重试时告知模型“已尝试过什么”，不是一个可依赖的 exactly-once 执行事务。[Codex `tools/executed_tool_calls.rs`](https://github.com/openai/codex/blob/d109393270432531ac0010542ae7973801e0d9d7/codex-rs/core/src/tools/executed_tool_calls.rs)

**对 Disco 的推断。** Disco G2-2 无需复制这套复杂恢复。当前 opaque continuation 已经足以完成正常 follow-up；故障时先采用 fail-closed + executor invocation count 测试，避免把 best-effort metadata 误当幂等机制。

## 4. Claude Code

### 4.1 tool result 与权限拒绝

**官方协议事实。** Anthropic client tool use 使用 `tool_use`/`tool_result` 配对，`tool_result.tool_use_id` 必须对应调用 ID，`is_error: true` 表示工具失败。一个 assistant 消息里若有多个 tool use，下一条 user 消息必须一起提供对应结果。[Anthropic Tool use overview](https://platform.claude.com/docs/en/agents-and-tools/tool-use/overview)

**官方文档事实。** Claude Code 权限规则把 tool invocation 判为 allow、ask 或 deny；PreToolUse hook 也可以在执行前允许、拒绝或要求审批。被拒绝的工具不会执行，拒绝原因会反馈给 Claude。[Claude Code permissions](https://code.claude.com/docs/en/permissions)，[Claude Code hooks](https://code.claude.com/docs/en/hooks)

**对 Disco 的推断。** `declined` 应是模型可见的 expected result，而不是 `runCancelled`。否则用户拒绝一个写操作会错误地中止所有后续只读替代方案。

### 4.2 stream failure 的 commit point

**官方文档事实。** Claude Code 默认对瞬时失败做最多 10 次指数退避，但按响应进度设置 commit point：若已经完成 text block 或 tool call，或在 thinking 后已经开始其中之一，流错误不会自动重试，因为重发可能让同一工具调用执行两次。它保留已完成 block、丢弃被中断的最后 block，并仍会执行已经完成的 tool calls、从其结果继续本轮。[Claude Code error reference](https://code.claude.com/docs/en/errors#automatic-retries)

**对 Disco 的推断。** 对 Generic Runtime 来说，`toolCallCompleted` 应立即把本轮标成不可重放；更保守地说，只要 Provider 已发出可见 delta 或任何 tool-call delta，就不应自动重发整个模型 round。

### 4.3 timeout 与 cancellation

**官方文档事实。** Claude Code 的 Bash tool 和 command hooks 各自有 timeout；hook timeout/非零退出按 hook 规则转为阻断、非阻断错误或继续执行。Ctrl-C/interrupt 是 session/run 控制面行为，不等同于 client tool 的 `is_error` result。[Claude Code hooks](https://code.claude.com/docs/en/hooks)，[Claude Code settings](https://code.claude.com/docs/en/configuration)

**对 Disco 的推断。** timeout 应在 Executor 内形成 `.timedOut` expected result；只有 Tool Host 通道失效或 Runtime 自己取消任务时才抛错。

## 5. Gemini CLI

### 5.1 显式工具状态机

**源码事实。** Gemini CLI 定义 `Validating → Scheduled/AwaitingApproval → Executing → Success/Error/Cancelled` 状态；只有 success、error、cancelled 属于 completed call。结果同时保存 `responseParts`、可选 `error/errorType`、UI display、`outputFile` 和 `contentLength`。[Gemini CLI `scheduler/types.ts`](https://github.com/google-gemini/gemini-cli/blob/cf22ac7e86f3dcf528e3ae591fec1c03090a49f8/packages/core/src/scheduler/types.ts)

**源码事实。** 工具正常报错被编码成 `{ error: message }` 的 `functionResponse`；执行抛异常变成 `UNHANDLED_EXCEPTION`；AbortError 或 signal abort 变成 Cancelled。用户拒绝审批同样生成 cancelled response，因此模型可以看到拒绝而不是误以为工具没有返回。[Gemini CLI `scheduler/tool-executor.ts`](https://github.com/google-gemini/gemini-cli/blob/cf22ac7e86f3dcf528e3ae591fec1c03090a49f8/packages/core/src/scheduler/tool-executor.ts)，[Gemini CLI `scheduler/state-manager.ts`](https://github.com/google-gemini/gemini-cli/blob/cf22ac7e86f3dcf528e3ae591fec1c03090a49f8/packages/core/src/scheduler/state-manager.ts)

**源码事实。** Gemini 的 system prompt 还明确要求：工具被 declined/cancelled 后应立即尊重决定，不要重新尝试或“谈判”，除非用户明确要求。[Gemini CLI `prompts/snippets.ts`](https://github.com/google-gemini/gemini-cli/blob/cf22ac7e86f3dcf528e3ae591fec1c03090a49f8/packages/core/src/prompts/snippets.ts)

### 5.2 模型流 retry

**源码事实。** connection phase 通过 `retryWithBackoff` 对 429、部分 5xx 和网络错误做指数退避与 jitter，默认最多 10 attempts；AbortSignal 会立即停止等待。mid-stream retry 另有更小上限，注释明确为 3 retries/4 attempts，并重建同一个 request history。[Gemini CLI `utils/retry.ts`](https://github.com/google-gemini/gemini-cli/blob/cf22ac7e86f3dcf528e3ae591fec1c03090a49f8/packages/core/src/utils/retry.ts)，[Gemini CLI `core/geminiChat.ts`](https://github.com/google-gemini/gemini-cli/blob/cf22ac7e86f3dcf528e3ae591fec1c03090a49f8/packages/core/src/core/geminiChat.ts)

**源码事实。** agent loop 是“完整消费模型流并收集 tool calls → scheduler 执行 → 仅把 function responses 作为下一轮 request”。公开 SDK 的 `sendStream()` 也是相同结构。[Gemini CLI `agent/legacy-agent-session.ts`](https://github.com/google-gemini/gemini-cli/blob/cf22ac7e86f3dcf528e3ae591fec1c03090a49f8/packages/core/src/agent/legacy-agent-session.ts)，[Gemini CLI SDK `session.ts`](https://github.com/google-gemini/gemini-cli/blob/cf22ac7e86f3dcf528e3ae591fec1c03090a49f8/packages/sdk/src/session.ts)

**对 Disco 的推断。** Gemini 的流 retry 说明“只重发模型 request”与“重跑工具”是两件事，但它没有给 Disco 可直接复用的 call-ID exactly-once 事务。Disco 应保持更严格的 commit point。

### 5.3 限额、overflow 与唯一终止

**源码事实。** `maxSessionTurns` 超限产生 `MAX_TURNS_EXCEEDED`；loop detector 可提前中断重复循环。`LegacyAgentSession` 用 `_agentEndEmitted` guard，确保 completed/failed/aborted/max_turns 中只发一个 `agent_end`。[Gemini CLI `agent/legacy-agent-session.ts`](https://github.com/google-gemini/gemini-cli/blob/cf22ac7e86f3dcf528e3ae591fec1c03090a49f8/packages/core/src/agent/legacy-agent-session.ts)

**源码事实。** 每次请求前先压缩历史、mask bulky tool outputs，再估算 pending request；仍超过剩余窗口时发 `ContextWindowWillOverflow` 并停止。压缩边界会避免切断 functionCall/functionResponse 配对；最近工具输出可保留，较老或超预算输出可截断/替换为引用。[Gemini CLI `core/client.ts`](https://github.com/google-gemini/gemini-cli/blob/cf22ac7e86f3dcf528e3ae591fec1c03090a49f8/packages/core/src/core/client.ts)，[Gemini CLI `context/chatCompressionService.ts`](https://github.com/google-gemini/gemini-cli/blob/cf22ac7e86f3dcf528e3ae591fec1c03090a49f8/packages/core/src/context/chatCompressionService.ts)，[Gemini CLI `context/toolOutputMaskingService.ts`](https://github.com/google-gemini/gemini-cli/blob/cf22ac7e86f3dcf528e3ae591fec1c03090a49f8/packages/core/src/context/toolOutputMaskingService.ts)

## 6. Aider

Aider 是有价值的对照组，但不能被当成完整 function-tool runtime：它主要让模型生成编辑格式，然后本地解析并一次性应用。

### 6.1 API retry 在副作用之前

**源码事实。** Aider 对 LiteLLM 标为 retryable 的异常从 0.125 秒开始翻倍等待，下一次实际为 0.25 秒；delay 超过 `RETRY_TIMEOUT = 60` 秒后停止。`ContextWindowExceededError` 不进入此 retry。[Aider `coders/base_coder.py`](https://github.com/Aider-AI/aider/blob/5dc9490bb35f9729ef2c95d00a19ccd30c26339c/aider/coders/base_coder.py)，[Aider `models.py`](https://github.com/Aider-AI/aider/blob/5dc9490bb35f9729ef2c95d00a19ccd30c26339c/aider/models.py)

**源码事实。** `send()` 完整结束后才执行 `apply_updates()`；因此模型 API retry 不会重复写文件。格式错误或应用异常会设置 `reflected_message`，再请求模型修正；reflection 上限为 3。[Aider `coders/base_coder.py`](https://github.com/Aider-AI/aider/blob/5dc9490bb35f9729ef2c95d00a19ccd30c26339c/aider/coders/base_coder.py)

**对 Disco 的推断。** 这再次支持两阶段设计：先获得完整、可校验调用，再跨越副作用 seam；跨越后不可回到“重发原模型响应”的路径。

### 6.2 拒绝、取消和 overflow

**源码事实。** 模型要创建新文件或编辑未加入 chat 的文件时，Aider 先询问；用户拒绝后该编辑被跳过。应用成功后才显示 `Applied edit`；`--dry-run` 明确显示未应用。[Aider `coders/base_coder.py`](https://github.com/Aider-AI/aider/blob/5dc9490bb35f9729ef2c95d00a19ccd30c26339c/aider/coders/base_coder.py)

**官方文档事实。** Ctrl-C 可以中断生成，partial response 会保留在 conversation 中，供下一条消息引用。[Aider usage tips](https://aider.chat/docs/usage/tips.html)

**源码事实。** context exceeded 会展示 exhausted error 并结束本次 send；历史过大时另行后台 summarization，为后续消息缩短上下文，而不是在编辑已经应用后自动重放原请求。[Aider `coders/base_coder.py`](https://github.com/Aider-AI/aider/blob/5dc9490bb35f9729ef2c95d00a19ccd30c26339c/aider/coders/base_coder.py)，[Aider token limits](https://aider.chat/docs/troubleshooting/token-limits.html)

## 7. Disco G2-2 建议语义

### 7.1 把 commit point 写进 Runtime 状态

建议在 `GenericAgentRuntime` 内维护不持久化的 round 状态：

```text
requestingModel
  → streamingModel
  → toolCallCommitted(callID, continuation)
  → executingTool(callID)
  → toolResultCommitted(callID, result)
  → requestingFollowUp
```

约束：

- `toolCallCommitted` 之后永远不能重发产生该 call 的模型 request。
- `executingTool` 开始后，Runtime 永远不能再次调用同一 call ID。
- `toolResultCommitted` 后只能发送相同 continuation + 相同 result；不能重新执行工具来重建结果。
- G2-2 不需要持久化 ledger；单 run 内用 `Set<callID>` 防重复执行已经足够。G3 如果加入进程恢复，再设计 durable invocation record。

### 7.2 明确 result 与 throw 的契约

保留现有 `ToolExecutionResult`，语义建议如下：

| 状态 | 含义 | Runtime 行为 |
| --- | --- | --- |
| `success` | 工具完成预期工作 | 回传模型，继续 loop |
| `failure` | 工具可靠地完成尝试，但业务/命令失败 | 回传模型，允许修正参数或换方案 |
| `declined` | 用户或静态 policy 明确拒绝，工具未执行 | 回传模型，禁止 Runtime 自动重试 |
| `cancelled` | 单个工具被局部取消，run 本身仍有效 | 回传模型，允许换方案 |
| `timed_out` | 工具达到本地 deadline，Executor 已完成清理 | 回传模型，是否再尝试由模型提出并重新走 policy |
| `isTruncated` | output 被裁剪，和上述任意状态组合 | 保持为正交字段；output 应提示如何获取剩余内容 |

`ToolExecutor.execute` 只应在以下情况 throw：Tool Host/IPC 失联、结果协议损坏、Executor 内部 invariant 破坏、Runtime Task cancellation。前三类映射唯一 `runFailed`；最后一类映射唯一 `runCancelled`。

特别注意：如果用户点击“停止 run”，即使 Executor 恰好返回 `.cancelled`，Runtime 也应优先依据 run cancellation token 发 `runCancelled`，不能再发送 follow-up。

### 7.3 retry policy

- **Provider 建连/HTTP 请求尚未产生任何事件**：可由 Provider 做有界 retry + backoff。
- **已经产生文本、reasoning、tool-call delta 或 completed call**：Runtime 不重发该模型 round。
- **Executor expected failure**：不由 Runtime 重试；作为 result 回模型。
- **Executor throw**：不重试，runFailed。
- **sandbox denial**：G2-2 不做 Codex 式升级重试；未来 G3 必须在 Executor 内重新走 approval，并限定一次。
- **tool result 后的 follow-up overflow**：G2-2 直接 `runFailed(contextOverflow)`；必须断言 Executor 只调用一次。以后若恢复，压缩只能改写早期历史，且必须保留原 continuation/result，不得重新执行工具。
- **tool result 后的 follow-up 网络错误**：只有 Provider 能证明 request 未被服务端接受时才可重发相同 follow-up；G2-2 先 fail closed。

### 7.4 预算

现有 `maximumModelRounds = 8`、`maximumToolCalls = 16` 是合理的第一版双重保险。建议 G2-2 再加：

- 单工具 wall-clock deadline，由 Executor 配置，不由模型参数覆盖；
- 单次 output byte/token 上限，截断发生在 Executor seam 内；
- 单 run 累计 tool output budget，避免 16 个各自合法的大结果挤爆 follow-up；
- 上限检查必须发生在下一次网络请求或工具调用之前，边界测试断言计数恰好。

不要把失败/拒绝排除在 tool-call budget 外，否则模型可通过反复无效调用绕过上限。

## 8. G2-2 可执行测试矩阵

所有测试都从公开 seam `AgentRuntime.start` 观察，并同时记录 Provider request 次数、Executor invocation 次数和终止事件数。

| 场景 | 预期 |
| --- | --- |
| Provider 首轮在任何可见事件前 throw | 一个 `runFailed`；Executor 0 次 |
| Provider 发 text/reasoning 后 throw | 保留已发 delta；一个 `runFailed`；不重试请求 |
| tool call 缺 continuation | `runFailed`；Executor 0 次 |
| Executor 返回五种 status | 每种均生成一次 follow-up；不是 `runFailed/runCancelled`；Executor 1 次 |
| Executor 返回 truncated success/failure | follow-up JSON 保留 `is_truncated: true` |
| Executor throw 普通 error | 一个 `runFailed`；follow-up 0 次 |
| Executor throw `CancellationError`，run 已由用户停止 | 一个 `runCancelled`；无 follow-up |
| 工具局部 `.cancelled`，run 未停止 | follow-up 1 次，模型可继续；最终正常 terminal |
| 用户在 waitingForTool 时停止 | 调 `executor.cancel(runID:)` 一次；一个 `runCancelled`；终止后无事件 |
| follow-up 返回 context overflow | 一个稳定 `runFailed`；Executor 仍恰好 1 次；不得发起原 call 的第二次执行 |
| follow-up mid-stream 断开 | 一个 `runFailed`；Executor 1 次；不重放原 round |
| 重复 call ID 出现在后续 completion | 在 Executor 前失败；已执行 call 不再执行 |
| maximumModelRounds 边界 | 请求数不超过配置；唯一 `runFailed` |
| maximumToolCalls 边界 | Executor 次数不超过配置；拒绝/失败调用也计数 |
| terminal race：cancel 与 executor 完成同时发生 | 只出现一个 terminal；terminal 后流结束 |

建议实现顺序：

1. 先补五种 expected result、Executor throw、follow-up overflow 不重放三组测试。
2. 再补 run cancellation 与 tool-local cancelled 的竞态测试。
3. 最后加入 executed call-ID set、累计 output budget 和 deadline；每项先写失败测试。

完成 G2-2 的判定标准不是“所有错误都能自动恢复”，而是：**每个失败都有唯一、稳定、可解释的落点，且任何恢复路径都不会重复副作用。**
