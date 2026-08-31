import type {
  ApprovalDecision,
  MessageItem,
  RunMode,
  ToolCallStatus,
} from "../../shared/types.js";

export type BackendEvent =
  | { type: "text"; text: string }
  | { type: "reasoning"; text: string }
  | { type: "item"; item: MessageItem }
  | {
      type: "tool";
      id: string;
      title: string;
      state: ToolCallStatus;
      input?: unknown;
      output?: string;
      error?: string;
    };

export type RequestApproval = (
  toolName: string,
  title: string | undefined,
  input: Record<string, unknown>,
) => Promise<ApprovalDecision>;

export interface BackendRunContext {
  backendSessionId?: string;
  onBackendSessionId?: (backendSessionId: string) => void;
  workingDirectory: string;
  prompt: string;
  mode: RunMode;
  emit: (event: BackendEvent) => void;
  signal: AbortSignal;
  requestApproval: RequestApproval;
}

export interface AgentBackend {
  readonly supportsPlan: boolean;
  run(context: BackendRunContext): Promise<string>;
  shutdown?(): Promise<void>;
}
