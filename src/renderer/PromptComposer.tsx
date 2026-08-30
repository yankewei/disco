import type { FormEvent, JSX } from "react";
import type { BackendKind, ProviderInfo, SessionInfo } from "../shared/types";

interface PromptComposerProps {
  activeSession?: SessionInfo;
  activeSessionId?: string;
  backend: BackendKind;
  draft: string;
  planMode: boolean;
  providers: ProviderInfo[];
  running: boolean;
  onAttachContext: (withDirectories: boolean) => void;
  onBackendChange: (backend: BackendKind) => void;
  onDraftChange: (draft: string) => void;
  onPlanModeChange: (enabled: boolean) => void;
  onSend: (event: FormEvent) => void;
  onStop: (sessionId: string) => void;
}

export function PromptComposer({
  activeSession,
  activeSessionId,
  backend,
  draft,
  planMode,
  providers,
  running,
  onAttachContext,
  onBackendChange,
  onDraftChange,
  onPlanModeChange,
  onSend,
  onStop,
}: PromptComposerProps): JSX.Element {
  const supportsPlan = providers.find(
    (provider) => provider.kind === activeSession?.backend,
  )?.supportsPlan;

  return (
    <form className="composer" onSubmit={onSend}>
      <label className="composer-label" htmlFor="prompt">
        发送给 Agent
      </label>
      <textarea
        id="prompt"
        value={draft}
        onChange={(event) => onDraftChange(event.target.value)}
        onKeyDown={(event) => {
          if ((event.metaKey || event.ctrlKey) && event.key === "Enter") {
            event.preventDefault();
            event.currentTarget.form?.requestSubmit();
          }
        }}
        placeholder={
          activeSession
            ? "描述你想让 Agent 完成的工作，或 @ 引用文件、命令"
            : "先选择一个本地项目，然后开始对话"
        }
        disabled={running}
        rows={3}
      />
      <div>
        <button
          type="button"
          className="attach"
          aria-label="添加上下文"
          title="添加文件或目录作为上下文"
          onClick={() => onAttachContext(true)}
        >
          +
        </button>
        <button
          type="button"
          className="context-action"
          aria-label="引用文件"
          title="引用文件"
          onClick={() => onAttachContext(false)}
        >
          @
        </button>
        <select
          className="backend-select"
          aria-label="选择 Agent"
          value={backend}
          disabled={Boolean(activeSession)}
          title={
            activeSession
              ? "当前会话已绑定该 Agent，新建对话可切换"
              : "选择用于新对话的 Agent"
          }
          onChange={(event) =>
            onBackendChange(event.target.value as BackendKind)
          }
        >
          {providers.map((provider) => (
            <option key={provider.kind} value={provider.kind}>
              {provider.name}
            </option>
          ))}
        </select>
        <label className="plan-toggle">
          <input
            type="checkbox"
            checked={planMode}
            onChange={(event) => onPlanModeChange(event.target.checked)}
            disabled={!activeSession || !supportsPlan}
          />
          <span>计划模式</span>
        </label>
        <span className="send-hint">
          {activeSession ? "⌘↵ 发送" : "选择项目后发送"}
        </span>
        {running ? (
          <button
            type="button"
            className="quiet"
            onClick={() => activeSessionId && onStop(activeSessionId)}
          >
            停止
          </button>
        ) : (
          <button type="submit" className="send" aria-label="发送">
            ↑
          </button>
        )}
      </div>
    </form>
  );
}
