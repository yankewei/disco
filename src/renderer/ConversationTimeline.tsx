import type { JSX } from "react";
import type {
  ApprovalDecision,
  BackendKind,
  ProviderInfo,
  SessionInfo,
  MessageItem,
  StoredMessage,
  ToolCallStatus,
} from "../shared/types";

export interface PendingApproval {
  sessionId: string;
  runId: string;
  approvalId: string;
  toolName: string;
  title?: string;
  input: Record<string, unknown>;
}

interface ConversationTimelineProps {
  activeSession?: SessionInfo;
  messages: StoredMessage[];
  pendingApprovals: PendingApproval[];
  providers: ProviderInfo[];
  onAddProject: () => void;
  onAddSession: (backend: BackendKind) => void;
  onApprove: (approvalId: string, decision: ApprovalDecision) => void;
}

function itemStateLabel(state: MessageItem["state"]): string {
  switch (state) {
    case "started":
      return "运行中";
    case "updated":
      return "更新中";
    case "completed":
      return "完成";
  }
}

function toolStatusLabel(status: ToolCallStatus): string {
  switch (status) {
    case "started":
      return "运行中";
    case "completed":
      return "完成";
    case "failed":
      return "失败";
  }
}

function toolStatusIcon(status: ToolCallStatus): string {
  switch (status) {
    case "started":
      return "◌";
    case "completed":
      return "✓";
    case "failed":
      return "×";
  }
}

function formatPayload(payload: unknown): string {
  if (payload === undefined) {
    return "暂无数据";
  }
  try {
    return JSON.stringify(payload, null, 2) ?? String(payload);
  } catch {
    return String(payload);
  }
}

function renderMessageItem(item: MessageItem): JSX.Element {
  switch (item.type) {
    case "text":
      return (
        <div className="timeline-item timeline-item-text">
          <div className="timeline-item-meta">
            <span>回复</span>
            <span>{itemStateLabel(item.state)}</span>
          </div>
          {item.text && <div className="message-text">{item.text}</div>}
        </div>
      );
    case "reasoning":
      return (
        <details className="timeline-item reasoning-block" open>
          <summary>
            <span>分析过程</span>
            <span>{itemStateLabel(item.state)}</span>
          </summary>
          {item.text && <pre>{item.text}</pre>}
        </details>
      );
    case "command_execution":
      return (
        <div className="timeline-item tool-block">
          <div className="tool-block-header">
            <span className="tool-icon">
              {item.state === "completed" ? "✓" : "◌"}
            </span>
            <span className="tool-name">{item.command}</span>
            <span className="tool-status">{itemStateLabel(item.state)}</span>
          </div>
          {item.output && <pre className="tool-output">{item.output}</pre>}
        </div>
      );
    case "file_change":
      return (
        <details className="timeline-item item-block file-change-block" open>
          <summary>
            <span>文件变更</span>
            <span>{itemStateLabel(item.state)}</span>
          </summary>
          <ul className="item-list">
            {item.changes.map((change, index) => (
              <li key={`${change.path}-${index}`}>
                <span className={`change-kind ${change.kind}`}>
                  {change.kind === "add"
                    ? "新增"
                    : change.kind === "delete"
                      ? "删除"
                      : "修改"}
                </span>
                <code>{change.path}</code>
              </li>
            ))}
          </ul>
        </details>
      );
    case "mcp_tool_call":
      return (
        <details className="timeline-item item-block" open>
          <summary>
            <span>MCP · {item.server} / {item.tool}</span>
            <span>{itemStateLabel(item.state)}</span>
          </summary>
          <div className="item-detail-grid">
            <div>
              <span className="item-detail-label">参数</span>
              <pre>{formatPayload(item.arguments)}</pre>
            </div>
            {item.result !== undefined && (
              <div>
                <span className="item-detail-label">结果</span>
                <pre>{formatPayload(item.result)}</pre>
              </div>
            )}
            {item.error && (
              <div className="item-error-text">{item.error}</div>
            )}
          </div>
        </details>
      );
    case "web_search":
      return (
        <div className="timeline-item item-block">
          <div className="timeline-item-meta">
            <span>网页搜索</span>
            <span>{itemStateLabel(item.state)}</span>
          </div>
          <div className="item-inline-value">{item.query}</div>
        </div>
      );
    case "todo_list":
      return (
        <details className="timeline-item item-block" open>
          <summary>
            <span>任务清单</span>
            <span>{itemStateLabel(item.state)}</span>
          </summary>
          <ul className="item-list todo-list">
            {item.items.map((todo, index) => (
              <li key={`${todo.text}-${index}`}>
                <span className={todo.completed ? "todo-done" : "todo-open"}>
                  {todo.completed ? "✓" : "○"}
                </span>
                <span>{todo.text}</span>
              </li>
            ))}
          </ul>
        </details>
      );
    case "error":
      return (
        <div className="timeline-item item-block item-error-block">
          <div className="timeline-item-meta">
            <span>项目错误</span>
            <span>{itemStateLabel(item.state)}</span>
          </div>
          <div className="item-error-text">{item.message}</div>
        </div>
      );
  }
}

export function ConversationTimeline({
  activeSession,
  messages,
  pendingApprovals,
  providers,
  onAddProject,
  onAddSession,
  onApprove,
}: ConversationTimelineProps): JSX.Element {
  return (
    <div className="timeline">
      {!activeSession && (
        <section className="start-panel">
          <div className="agent-mark">✦</div>
          <p className="start-kicker">Disco workspace</p>
          <h2>让 coding agent 帮你完成工作</h2>
          <p>
            连接一个本地代码目录，然后让 agent
            分析、规划并执行下一步。所有上下文都留在你的工作区里。
          </p>
          <div className="start-actions">
            <button className="primary-action" onClick={onAddProject}>
              选择本地文件夹
            </button>
          </div>
          <div className="provider-strip">
            {providers.map((provider) => (
              <button
                key={provider.kind}
                onClick={() => onAddSession(provider.kind)}
              >
                <strong>{provider.name}</strong>
                <small>{provider.detail}</small>
              </button>
            ))}
          </div>
        </section>
      )}

      {messages.map((message) => (
        <article className={`message ${message.role}`} key={message.id}>
          {message.reasoning && (
            <details className="reasoning-block">
              <summary>分析过程</summary>
              <pre>{message.reasoning}</pre>
            </details>
          )}
          {message.text && <div className="message-text">{message.text}</div>}
          {message.items && (
            <div className="timeline-items">
              {message.items.map((item) => (
                <div key={item.id}>{renderMessageItem(item)}</div>
              ))}
            </div>
          )}
          {message.toolCalls?.map((toolCall) => (
            <div className="tool-block" key={toolCall.id}>
              <div className="tool-block-header">
                <span className={`tool-icon ${toolCall.status}`}>
                  {toolStatusIcon(toolCall.status)}
                </span>
                <span className="tool-name">{toolCall.name}</span>
                <span className="tool-status">
                  {toolStatusLabel(toolCall.status)}
                </span>
              </div>
              {toolCall.error && (
                <div className="item-error-text">{toolCall.error}</div>
              )}
              {toolCall.output && (
                <pre className="tool-output">{toolCall.output}</pre>
              )}
            </div>
          ))}
          {message.error && (
            <div className="message-run-error">运行失败：{message.error}</div>
          )}
          {message.status === "cancelled" && (
            <div className="message-run-cancelled">运行已取消</div>
          )}
        </article>
      ))}

      {pendingApprovals.map((pendingApproval) => (
        <div className="approval-card" key={pendingApproval.approvalId}>
          <div className="approval-head">
            <span className="approval-icon">⚠</span>
            <strong>{pendingApproval.title ?? pendingApproval.toolName}</strong>
          </div>
          <pre className="approval-input">
            {JSON.stringify(pendingApproval.input, null, 2)}
          </pre>
          <div className="approval-actions">
            <button
              className="approval-approve"
              onClick={() => onApprove(pendingApproval.approvalId, "approved")}
            >
              批准
            </button>
            <button
              className="approval-deny"
              onClick={() => onApprove(pendingApproval.approvalId, "denied")}
            >
              拒绝
            </button>
          </div>
        </div>
      ))}
    </div>
  );
}
