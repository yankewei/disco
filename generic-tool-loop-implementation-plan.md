# Generic tool call 与工具循环实施计划

> 状态：G1、G2-1、G2-2 已完成；已落地 Provider 无关的用户交互合约、OpenAI Generic
> `request_user_input` 暂停/续传、统一问答 UI，以及由脚本化 ToolExecutor 验证的
> Generic 单工具循环和失败矩阵。生产只读 Tool Host 尚未开始，因此 App 当前不广告本地文件工具。

## 目标

优先让 API Key / Generic Runtime 路径形成 coding-agent 闭环：

1. Provider 能发送结构化工具定义并可靠解析流式 tool call。
2. Generic Runtime 能执行受控工具、回传结果并继续模型请求，直到得到最终文本。
3. 第一批生产工具只读 Project workspace，执行发生在独立 Tool Host 中。
4. UI 使用统一 Agent 事件展示工具状态，不暴露 Provider 私有协议。

Codex cwd、command/file item 与审批接入延后；已完成的 Codex schema 结论保留，不进入当前实现队列。

## 交付顺序

### G1. Model contract 与 OpenAI Responses function call

先只打通 OpenAI 原生 Responses 方言，不同时修改 Chat Completions：

- `ModelRequest` 增加结构化工具定义、并行调用策略、上一轮 continuation 与工具结果。
- `ModelEvent` 增加 tool call delta、tool call completed 和显式 completed。
- OpenAI Responses 请求发送 `type: "function"`、严格 JSON schema、`tool_choice: "auto"`，并显式关闭并行工具调用。
- Provider 按 `output_index`、item ID 与 `call_id` 合并 `response.function_call_arguments.delta`。
- Provider 在 `response.output_item.done` / `response.completed` 收敛完整调用并去重。
- 下一轮请求回放上一轮全部 output item，并追加与原 `call_id` 匹配的 `function_call_output`。
- 继续保持 `store: false`。

完成后再分别接入：

1. 明确声明支持 function tools 的 Responses 兼容方言。
2. Kimi Code Chat Completions 的 `tool_calls` / `tool` message 方言。

两套 wire DTO 各自留在 Provider 内，不做共享原始协议结构。

### G2. Generic 单工具循环

给 `GenericAgentRuntime` 注入 `ToolExecutor`，先使用脚本化内存 Adapter 验证循环：

#### G2-1. ToolExecutor seam 与单工具闭环（已完成）

- 每轮最多接受一个 client-owned function call；请求显式关闭 parallel tool calls。
- Runtime 校验调用属于已广告工具，arguments 是合法 JSON object 后才跨越 ToolExecutor seam。
- 工具自己的 Adapter 在产生副作用前做严格参数校验；非法参数不得执行。
- 工具成功、失败、拒绝、取消、超时和输出截断都以结构化结果回传模型。
- 回传工具结果后继续调用 Provider，直至得到最终文本。
- 默认最多 8 个模型轮次、16 次工具调用；测试可注入更小限制。
- 达到限制时返回稳定中文失败，不伪造最终回答。
- 取消在模型流和工具执行两处都生效，并保持一次 run 恰好一个终止事件。
- 工具已经执行后若发生上下文溢出，不自动重放该工具；避免重复副作用。

本片只注入脚本化内存 Executor；`WorkspaceContext` 已在 Runtime 创建时锁定并随执行请求
跨越 seam，但没有生产工具实现，不改变用户可见能力。

#### G2-2. 失败矩阵加固（已完成）

- success、failure、declined、cancelled、timed out 与 truncated 均按结构化结果续传；
  expected failure 不升级成 Runtime failure。
- Executor 基础设施异常映射为唯一 `runFailed`；只有 Runtime Task 确实被取消时才映射
  `runCancelled`，即使 Executor 同时返回 cancelled 或报告其他异常也由 run cancellation 获胜。
- 工具调用拿到完整 continuation 后进入单 run commit ledger；后续 completion 重复同一
  `call_id` 时在 Executor 前失败，已执行调用不得重放。
- 工具结果续传发生 context overflow 时使用稳定、不可直接重试的失败；续传中途断流时
  保留已发出的 delta。两者都不重新执行工具。
- Provider 在首个事件前或流式输出后失败均 fail closed；Runtime 不自动重发模型 round。
- 缺失 continuation、非法参数、未知/并行工具、模型轮数与工具调用数边界继续在副作用前失败。
- 研究依据、竞品行为与完整测试矩阵见
  [`coding-agent-failure-matrix-research.md`](coding-agent-failure-matrix-research.md)。

单工具 wall-clock timeout、单次输出裁剪和 helper 崩溃清理仍属于 G3 Executor/IPC seam；
G2-2 不在 Runtime 外层用超时重放一个可能已经提交副作用的调用。

### G2a. Client-owned 用户问答（已完成首片）

- `request_user_input` 是 Runtime 保留的 function tool，不进入 ToolExecutor。
- 首批只由 OpenAI 原生 Responses 方言广告；DeepSeek、compatible 与 Chat Completions
  等各自 Provider 完成 tool calling adapter 后再复用同一 Runtime/UI。
- Runtime 只在拿到完整 tool call 与 opaque continuation 后发出用户输入请求；
  回答按 request/question ID 校验并编码为 `function_call_output` 续传。
- 单次 1～3 个问题，选择题 2～3 个选项；候选项不自动成为默认答案。
- Generic v1 不允许模型请求密码、API Key、验证码等敏感信息。
- 每个 run 最多连续询问 4 轮；停止、清空或 shutdown 会解除悬挂 continuation。
- Store 使用内存队列和 request-scoped 草稿；答案不进入 ChatMessage、日志或持久化。
- UI 使用统一“需要你的操作”卡片与 Sheet；审批与问答共享外壳但保持不同领域语义。

### G3. 只读 Tool Host

实现独立 helper process 与结构化 IPC，第一批只提供：

1. `filesystem.list`
2. `filesystem.read`
3. `filesystem.search`
4. `git.status`

这一片不提供 patch、任意 shell 或网络：

- Tool Host 每次调用都接收规范化 `WorkspaceContext` 与只读策略。
- 路径必须是绝对路径或相对 workspace 的路径；标准化并解析 symlink 后仍须位于授权根目录。
- 主 App 和 Provider 都不直接读文件或执行命令。
- IPC 有请求 ID、超时、输出字节限制、截断标记和取消。
- helper 退出时所有 pending call 明确失败，不能让 UI 永久运行中。

### G4. 工具活动 UI

- `AgentEvent` 增加统一的工具活动快照。
- ConversationStore 按 call ID 原位更新状态，不把 delta 追加成重复卡片。
- 现有 `ChatMessage.Part.toolCall` 只作为简单展示占位；若状态、输出和恢复需求超过它，使用独立 `AgentItemSnapshot`，不继续膨胀消息文本。
- 第一阶段展示工具名、目标路径/查询、状态、有限输出摘要和错误。
- UI 不解析 arguments JSON 来推断权限或影响范围。

### G5. 写入、shell 与审批

只读闭环稳定后再进入：

- `filesystem.apply_patch`
- `shell.execute`
- `git.diff`
- 原生审批与策略判断
- 进程树取消、命令超时和完整 diff 展示

未完成 G5 前不得向模型广告写入或 shell 工具。

## 模块与 interface 决策

### Provider continuation

Responses 在 `store: false` 下继续 function call 时，需要回放上一轮所有 output item，包括 reasoning item。领域层使用 run 内、不可持久化的 opaque `ModelContinuation`：

- Provider 创建并消费自己的 continuation。
- Runtime 只能原样回传，不能解析或修改 payload。
- continuation 带 provider identity，禁止传给另一个 Provider。
- Provider 原始 DTO 不进入 UI、SwiftData 或日志。

这让 Provider 保持无状态，同时避免把 OpenAI/Kimi 的原始 item 联合类型泄漏到公共模型。

### ToolExecutor seam

`ToolExecutor` 是 Generic Runtime 与实际执行之间唯一 seam：

- 生产 Adapter：独立 Tool Host 进程。
- 测试 Adapter：脚本化内存执行器。
- Runtime 测试只观察 interface 的调用、事件、结果与取消，不检查 Adapter 内部状态。
- workspace 校验、参数校验、timeout 和 output limit 隐藏在执行模块中，调用方不逐层转发这些规则。

### Workspace 所有权

- `WorkspaceContext` 固定在 `GenericAgentRuntime.Configuration`，因为同一 Conversation 的工具不能跨 Project。
- 只有绑定且当前可用的 Project 会话广告本地工具。
- 临时对话与 Project unavailable 状态仍可纯文本聊天，但不发送本地 function tool schema。
- Project 重新关联后重建受影响会话的 Runtime，旧调用立即取消。

## 领域类型草案

命名可在实现时微调，但保持以下语义：

- `ModelToolDefinition`：稳定名称、中文/英文说明、严格 input JSON schema。
- `ModelToolCall`：provider call ID、工具名、完整 arguments JSON。
- `ModelToolResult`：call ID、结构化状态、有限文本或 JSON 输出。
- `ModelContinuation`：Provider 私有、run 内回放载荷。
- `ModelCompletion`：本轮 continuation、完整 tool calls、finish 状态。
- `ToolExecutionContext`：workspace、锁定策略、run/call ID。
- `ToolExecutionEvent`：started、output delta、completed。

Hosted web search 继续使用现有 `HostedToolSnapshot`，不进入本地 ToolExecutor。

## G1 自动化测试

### 请求编码

- function schema 使用 `strict: true` 与 `additionalProperties: false`。
- function tools 与 hosted web search 可同时编码，类型不混淆。
- `parallel_tool_calls` 明确为 false。
- 第二轮输入包含上一轮 output items 和匹配 call ID 的 `function_call_output`。
- `store` 始终为 false。

### 流解析

- arguments 在任意 SSE/字节分片下合并一致。
- 多个 output index、重复 done、delta 后完整 item 均不重复发调用。
- complete JSON response 与 SSE 得到相同的领域事件。
- 缺少 call ID、工具名或结束事件时明确失败。
- usage 与 completed 各自只发一次。
- function call 本轮没有文本时不再错误映射为 `noTextOutput`。
- hosted web search、citation、reasoning 和 function call 混合事件不回归。

## G2 自动化测试

- 完整路径：模型请求工具、Fake Executor 成功、结果回传、模型输出最终文本。
- arguments 非法 JSON 时 Fake Executor 调用次数为 0。
- 未广告工具调用时 Fake Executor 调用次数为 0。
- 工具失败结果可回传模型并生成可恢复回答。
- 多工具调用在第一阶段明确失败且不执行任何一个。
- 最大轮数与最大调用数分别触发稳定失败。
- 模型流中取消、工具执行中取消都只产生一个 cancelled。
- Provider 失败、Executor 失败和 continuation provider mismatch 都只产生一个 failed。
- 工具执行后的 context overflow 不会重放已经完成的 call ID。
- 现有上下文压缩、usage、hosted web search 与纯文本对话测试全部通过。

## G3 安全测试

- `..`、绝对越界路径、symlink escape、父目录 symlink、新建路径逃逸全部拒绝。
- 读取 workspace 内文件、列目录、文本搜索和 `git status` 正常。
- 不存在、不可读、非目录 workspace 明确失败。
- 超时终止 helper 操作；取消后不再输出事件。
- 大输出按 UTF-8 安全边界截断并带标记。
- helper 崩溃完成所有 pending continuation。
- IPC 和日志不包含 API Key、完整环境变量或未请求的文件内容。

## 手工验收

1. 在 Project 会话中让 Generic 模型列出仓库顶层文件并概括结构。
2. 搜索一个已知符号，确认路径和摘要来自正确 Project。
3. 打开另一个 Project 重复操作，不能读取前一个 Project。
4. 在临时对话请求读取本地文件，模型不得获得本地工具。
5. 请求修改文件或运行任意 shell，当前阶段不得执行。
6. 工具运行中停止，UI 结束运行态且没有残留 helper 操作。
7. 普通文本、推理、web search、context compaction 与会话持久化不回归。

每个 G 阶段都运行完整 `xcodebuild test`。G1 与 G2 通过 scripted fixture；G3 再进行隔离临时仓库的真实 helper smoke test。

## 明确不做

- 当前不修改 Codex app-server DTO 或 Runtime。
- 不把 Provider 私有 output item 持久化。
- 不让主 App 直接执行 shell。
- 不在只读阶段提供 patch、write、delete、网络或 Git 写操作。
- 不用自然语言工具说明替代结构化 schema。
- 不为尚未接入的 Provider 猜测 tool calling 兼容性。
