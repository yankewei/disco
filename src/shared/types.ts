export type BackendKind = "codex" | "claude" | "opencode";
export type Locale = "zh-CN" | "en-US";
export type RunMode = "agent" | "plan";
export type ApprovalDecision = "approved" | "denied";
export type RunStatus = "completed" | "cancelled" | "failed";
export type ToolCallStatus = "started" | "completed" | "failed";
export type SandboxMode =
  | "read-only"
  | "workspace-write"
  | "danger-full-access";
export const defaultSandboxMode: SandboxMode = "workspace-write";
export type ReasoningEffort =
  | "minimal"
  | "low"
  | "medium"
  | "high"
  | "xhigh"
  | "max"
  | "ultra"
  | "persistent";

export interface ProjectInfo {
  id: string;
  name: string;
  path: string;
  createdAt: string;
}

export interface SessionInfo {
  sessionId: string;
  projectId: string;
  backend: BackendKind;
  modelId?: string;
  reasoningEffort?: ReasoningEffort;
  sandboxMode?: SandboxMode;
  backendSessionId?: string;
  title: string;
  updatedAt: string;
}

export interface ToolCall {
  id: string;
  name: string;
  status: ToolCallStatus;
  input?: unknown;
  output?: string;
  error?: string;
}

export type MessageItemState = "started" | "updated" | "completed";

export interface FileChange {
  path: string;
  kind: "add" | "delete" | "update";
}

export type MessageItem =
  | {
      id: string;
      type: "text";
      text: string;
      state: MessageItemState;
    }
  | {
      id: string;
      type: "reasoning";
      text: string;
      state: MessageItemState;
    }
  | {
      id: string;
      type: "command_execution";
      command: string;
      output: string;
      state: MessageItemState;
    }
  | {
      id: string;
      type: "file_change";
      changes: FileChange[];
      state: MessageItemState;
    }
  | {
      id: string;
      type: "mcp_tool_call";
      server: string;
      tool: string;
      arguments: unknown;
      result?: unknown;
      error?: string;
      state: MessageItemState;
    }
  | {
      id: string;
      type: "web_search";
      query: string;
      state: MessageItemState;
    }
  | {
      id: string;
      type: "todo_list";
      items: Array<{ text: string; completed: boolean }>;
      state: MessageItemState;
    }
  | {
      id: string;
      type: "error";
      message: string;
      state: MessageItemState;
    };

export interface StoredMessage {
  id: string;
  role: "user" | "assistant";
  text: string;
  reasoning?: string;
  toolCalls?: ToolCall[];
  items?: MessageItem[];
  status?: RunStatus;
  error?: string;
  createdAt: string;
}

export type AgentEvent =
  | { type: "run-started"; sessionId: string; runId: string }
  | { type: "text"; sessionId: string; runId: string; text: string }
  | { type: "reasoning"; sessionId: string; runId: string; text: string }
  | {
      type: "item";
      sessionId: string;
      runId: string;
      item: MessageItem;
    }
  | {
      type: "tool";
      sessionId: string;
      runId: string;
      id: string;
      title: string;
      state: ToolCallStatus;
      input?: unknown;
      output?: string;
      error?: string;
    }
  | {
      type: "approval-requested";
      sessionId: string;
      runId: string;
      approvalId: string;
      toolName: string;
      title?: string;
      input: Record<string, unknown>;
    }
  | {
      type: "approval-resolved";
      sessionId: string;
      runId: string;
      approvalId: string;
    }
  | {
      type: "run-finished";
      sessionId: string;
      runId: string;
      status: RunStatus;
      sessionTitle?: string;
      error?: string;
    };

export interface DiscoAPI {
  listProjects(): Promise<ProjectInfo[]>;
  createProject(path: string, locale?: Locale): Promise<ProjectInfo>;
  listSessions(projectId: string): Promise<SessionInfo[]>;
  createSession(
    projectId: string,
    backend: BackendKind,
    modelId?: string,
    reasoningEffort?: ReasoningEffort,
    sandboxMode?: SandboxMode,
    locale?: Locale,
  ): Promise<SessionInfo>;
  loadMessages(sessionId: string): Promise<StoredMessage[]>;
  prompt(
    sessionId: string,
    text: string,
    mode: RunMode,
    locale?: Locale,
  ): Promise<void>;
  cancel(sessionId: string): Promise<void>;
  approve(approvalId: string, decision: ApprovalDecision): Promise<void>;
  providers(locale?: Locale): Promise<ProviderInfo[]>;
  about(): Promise<AboutInfo>;
  chooseDirectory(): Promise<string | null>;
  chooseFiles(withDirectories: boolean): Promise<string[]>;
  onEvent(listener: (event: AgentEvent) => void): () => void;
}

export interface ModelInfo {
  id: string;
  name: string;
  reasoningEfforts?: ReasoningEffort[];
}

export interface ProviderInfo {
  kind: BackendKind;
  name: string;
  available: boolean;
  detail: string;
  supportsPlan: boolean;
  models: ModelInfo[];
  evidence?: string;
  hint?: string;
}

export interface AboutInfo {
  dataPath: string;
  version: string;
}

declare global {
  interface Window {
    disco: DiscoAPI;
  }
}
