export type BackendKind = "codex" | "claude" | "opencode";
export type RunMode = "agent" | "plan";

export interface ProjectInfo { id: string; name: string; path: string; createdAt: string; }

export interface SessionInfo {
  sessionId: string;
  projectId: string;
  backend: BackendKind;
  backendSessionId?: string;
  title: string;
  updatedAt: string;
}

export interface StoredMessage {
  id: string;
  role: "user" | "assistant";
  text: string;
  reasoning?: string;
  toolCalls?: Array<{ id: string; name: string; status: "started" | "completed"; output?: string }>;
  createdAt: string;
}

export type AgentEvent =
  | { type: "text"; sessionId: string; text: string }
  | { type: "reasoning"; sessionId: string; text: string }
  | { type: "tool"; sessionId: string; id: string; title: string; state: "started" | "completed"; output?: string }
  | { type: "usage"; sessionId: string; input: number; output: number }
  | { type: "approval-requested"; sessionId: string; approvalId: string; toolName: string; title?: string; input: Record<string, unknown> }
  | { type: "approval-resolved"; sessionId: string; approvalId: string; decision: "approved" | "denied" }
  | { type: "run-finished"; sessionId: string; error?: string };

export interface DiscoAPI {
  listProjects(): Promise<ProjectInfo[]>;
  createProject(path: string): Promise<ProjectInfo>;
  deleteProject(id: string): Promise<void>;
  listSessions(projectId?: string): Promise<SessionInfo[]>;
  createSession(projectId: string, backend: BackendKind): Promise<SessionInfo>;
  deleteSession(sessionId: string): Promise<void>;
  loadMessages(sessionId: string): Promise<StoredMessage[]>;
  prompt(sessionId: string, text: string, mode: RunMode): Promise<void>;
  cancel(sessionId: string): Promise<void>;
  approve(approvalId: string, decision: "approved" | "denied"): Promise<void>;
  providers(): Promise<ProviderInfo[]>;
  about(): Promise<AboutInfo>;
  openSettings(): Promise<void>;
  chooseDirectory(): Promise<string | null>;
  chooseFiles(withDirectories?: boolean): Promise<string[]>;
  onEvent(listener: (event: AgentEvent) => void): () => void;
}

export interface ProviderInfo { kind: BackendKind; name: string; available: boolean; detail: string; supportsPlan: boolean; supportsApproval: boolean; evidence?: string; hint?: string; }

export interface AboutInfo { dataPath: string; version: string; }

declare global {
  interface Window { disco: DiscoAPI }
}
