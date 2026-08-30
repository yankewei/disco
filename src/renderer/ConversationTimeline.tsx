import type { JSX } from "react";
import type {
  ApprovalDecision,
  BackendKind,
  ProviderInfo,
  SessionInfo,
  StoredMessage,
} from "../shared/types";

export interface PendingApproval {
  approvalId: string;
  toolName: string;
  title?: string;
  input: Record<string, unknown>;
}

interface ConversationTimelineProps {
  activeSession?: SessionInfo;
  messages: StoredMessage[];
  pendingApproval: PendingApproval | null;
  providers: ProviderInfo[];
  onAddProject: () => void;
  onAddSession: (backend: BackendKind) => void;
  onApprove: (approvalId: string, decision: ApprovalDecision) => void;
}

export function ConversationTimeline({
  activeSession,
  messages,
  pendingApproval,
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
          {message.toolCalls?.map((toolCall) => (
            <div className="tool-block" key={toolCall.id}>
              <div className="tool-block-header">
                <span className="tool-icon">
                  {toolCall.status === "completed" ? "✓" : "◌"}
                </span>
                <span className="tool-name">{toolCall.name}</span>
                <span className="tool-status">
                  {toolCall.status === "started" ? "运行中" : "完成"}
                </span>
              </div>
              {toolCall.output && <pre className="tool-output">{toolCall.output}</pre>}
            </div>
          ))}
        </article>
      ))}

      {pendingApproval && (
        <div className="approval-card">
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
      )}
    </div>
  );
}
