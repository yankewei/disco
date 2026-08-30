import { randomUUID } from "node:crypto";
import { existsSync, readFileSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { basename, join, resolve } from "node:path";
import type {
  AgentEvent,
  ApprovalDecision,
  BackendKind,
  ProjectInfo,
  ProviderInfo,
  RunMode,
  SessionInfo,
  StoredMessage,
} from "../shared/types.js";
import {
  ClaudeBackend,
  CodexBackend,
  OpenCodeBackend,
  type AgentBackend,
  type BackendEvent,
  type RequestApproval,
} from "./backends/index.js";
import { DiscoStore } from "./store.js";

interface PendingApproval {
  resolve: (decision: ApprovalDecision) => void;
  sessionId: string;
}

export class AgentHost {
  private readonly backends: Record<BackendKind, AgentBackend> = {
    codex: new CodexBackend(),
    claude: new ClaudeBackend(),
    opencode: new OpenCodeBackend(),
  };
  private readonly runs = new Map<string, AbortController>();
  private readonly pendingApprovals = new Map<string, PendingApproval>();

  constructor(
    private readonly store: DiscoStore,
    private readonly emit: (event: AgentEvent) => void,
  ) {}

  listProjects(): ProjectInfo[] {
    return this.store.listProjects();
  }

  createProject(path: string): ProjectInfo {
    const normalizedPath = resolve(path);
    if (
      !existsSync(normalizedPath) ||
      !statSync(normalizedPath).isDirectory()
    ) {
      throw new Error("工作区路径无效或不可访问");
    }

    const existingProject = this.store.projectByPath(normalizedPath);
    if (existingProject) {
      return existingProject;
    }

    const project = {
      id: randomUUID(),
      name: basename(normalizedPath) || normalizedPath,
      path: normalizedPath,
      createdAt: new Date().toISOString(),
    };
    this.store.createProject(project);
    return project;
  }

  listSessions(projectId: string): SessionInfo[] {
    return this.store.listSessions(projectId);
  }

  createSession(projectId: string, backend: BackendKind): SessionInfo {
    if (!this.store.getProject(projectId)) {
      throw new Error("项目不存在");
    }

    const session = {
      sessionId: randomUUID(),
      projectId,
      backend,
      title: "新对话",
      updatedAt: new Date().toISOString(),
    };
    this.store.createSession(session);
    return session;
  }

  messages(sessionId: string): StoredMessage[] {
    return this.store.messages(sessionId);
  }

  async prompt(sessionId: string, text: string, mode: RunMode): Promise<void> {
    const session = this.store.getSession(sessionId);
    if (!session) {
      throw new Error("会话不存在");
    }
    const project = this.store.getProject(session.projectId);
    if (!project) {
      throw new Error("项目不存在");
    }
    if (this.runs.has(sessionId)) {
      throw new Error("该会话正在运行");
    }

    this.store.appendMessage(sessionId, {
      id: randomUUID(),
      role: "user",
      text,
      createdAt: new Date().toISOString(),
    });

    const controller = new AbortController();
    this.runs.set(sessionId, controller);
    let assistantText = "";
    let reasoning = "";
    const toolCalls: NonNullable<StoredMessage["toolCalls"]> = [];

    const handleBackendEvent = (event: BackendEvent): void => {
      if (event.type === "text") {
        assistantText += event.text;
      } else if (event.type === "reasoning") {
        reasoning += event.text;
      } else {
        const toolCall = toolCalls.find((item) => item.id === event.id);
        if (toolCall) {
          toolCall.status = event.state;
          toolCall.output = event.output;
        } else {
          toolCalls.push({
            id: event.id,
            name: event.title,
            status: event.state,
            output: event.output,
          });
        }
      }
      this.emit({ ...event, sessionId });
    };

    const requestApproval: RequestApproval = (toolName, title, input) => {
      const approvalId = randomUUID();
      return new Promise<ApprovalDecision>((resolveApproval) => {
        this.pendingApprovals.set(approvalId, {
          resolve: resolveApproval,
          sessionId,
        });
        this.emit({
          type: "approval-requested",
          sessionId,
          approvalId,
          toolName,
          title,
          input,
        });

        const denyOnAbort = (): void => {
          const pendingApproval = this.pendingApprovals.get(approvalId);
          if (!pendingApproval) {
            return;
          }
          this.pendingApprovals.delete(approvalId);
          pendingApproval.resolve("denied");
          this.emit({
            type: "approval-resolved",
            sessionId,
          });
        };
        if (controller.signal.aborted) {
          denyOnAbort();
          return;
        }
        controller.signal.addEventListener("abort", denyOnAbort, {
          once: true,
        });
      });
    };

    try {
      const backendSessionId = await this.backends[session.backend].run({
        backendSessionId: session.backendSessionId,
        workingDirectory: project.path,
        prompt: text,
        mode,
        emit: handleBackendEvent,
        signal: controller.signal,
        requestApproval,
      });
      this.store.updateSession(sessionId, backendSessionId);

      if (assistantText || reasoning || toolCalls.length > 0) {
        this.store.appendMessage(sessionId, {
          id: randomUUID(),
          role: "assistant",
          text: assistantText,
          reasoning: reasoning || undefined,
          toolCalls: toolCalls.length > 0 ? toolCalls : undefined,
          createdAt: new Date().toISOString(),
        });
      }
      this.emit({ type: "run-finished", sessionId });
    } catch (error) {
      const message = error instanceof Error ? error.message : "运行失败";
      this.emit({
        type: "run-finished",
        sessionId,
        error: controller.signal.aborted ? undefined : message,
      });
    } finally {
      this.clearApprovals(sessionId);
      this.runs.delete(sessionId);
    }
  }

  approve(approvalId: string, decision: ApprovalDecision): void {
    const pendingApproval = this.pendingApprovals.get(approvalId);
    if (!pendingApproval) {
      return;
    }
    this.pendingApprovals.delete(approvalId);
    pendingApproval.resolve(decision);
    this.emit({
      type: "approval-resolved",
      sessionId: pendingApproval.sessionId,
    });
  }

  cancel(sessionId: string): void {
    this.runs.get(sessionId)?.abort();
    this.clearApprovals(sessionId);
  }

  private clearApprovals(sessionId: string): void {
    for (const [approvalId, pendingApproval] of this.pendingApprovals) {
      if (pendingApproval.sessionId !== sessionId) {
        continue;
      }
      this.pendingApprovals.delete(approvalId);
      pendingApproval.resolve("denied");
      this.emit({
        type: "approval-resolved",
        sessionId,
      });
    }
  }

  providers(): ProviderInfo[] {
    const homeDirectory = homedir();
    const codexAuthPath = join(homeDirectory, ".codex", "auth.json");
    const claudeCredentialsPath = [
      join(homeDirectory, ".claude", ".credentials.json"),
      join(homeDirectory, ".claude.json"),
    ].find((file) => existsSync(file));
    const openCodeConfigPath = [
      join(homeDirectory, ".config", "opencode", "opencode.json"),
      join(homeDirectory, ".opencode", "opencode.json"),
    ].find((file) => existsSync(file));
    const isCodexAvailable = existsSync(codexAuthPath);
    const isClaudeAvailable =
      Boolean(process.env.ANTHROPIC_API_KEY) || Boolean(claudeCredentialsPath);

    const codexModels = [
      { id: "o4-mini", name: "o4-mini" },
      { id: "o3", name: "o3" },
      { id: "o4-mini-high", name: "o4-mini (high reasoning)" },
    ];

    const claudeModels = [
      { id: "claude-sonnet-4-20250514", name: "Claude Sonnet 4" },
      { id: "claude-opus-4-20250514", name: "Claude Opus 4" },
      { id: "claude-3-7-sonnet-20250219", name: "Claude 3.7 Sonnet" },
      { id: "claude-3-5-sonnet-20241022", name: "Claude 3.5 Sonnet" },
      { id: "claude-3-5-haiku-20241022", name: "Claude 3.5 Haiku" },
    ];

    const openCodeModels = this.readOpenCodeModels(openCodeConfigPath);

    return [
      {
        kind: "codex",
        name: "Codex",
        available: isCodexAvailable,
        detail: isCodexAvailable
          ? "已检测到 codex 登录态"
          : "未检测到登录态，先在终端完成登录后重新检测",
        evidence: isCodexAvailable ? codexAuthPath : undefined,
        hint: "codex login",
        supportsPlan: true,
        models: codexModels,
      },
      {
        kind: "claude",
        name: "Claude Code",
        available: isClaudeAvailable,
        detail: isClaudeAvailable
          ? "已检测到 Claude Code 登录态或 API Key"
          : "未检测到登录态，先在终端登录或设置 ANTHROPIC_API_KEY 后重新检测",
        evidence: isClaudeAvailable
          ? (claudeCredentialsPath ?? "ANTHROPIC_API_KEY")
          : undefined,
        hint: "claude",
        supportsPlan: true,
        models: claudeModels,
      },
      {
        kind: "opencode",
        name: "OpenCode",
        available: Boolean(openCodeConfigPath),
        detail: openCodeConfigPath
          ? "已检测到 OpenCode 配置"
          : "未检测到配置，先在终端完成 provider 配置后重新检测",
        evidence: openCodeConfigPath,
        hint: "opencode",
        supportsPlan: false,
        models: openCodeModels,
      },
    ];
  }

  private readOpenCodeModels(configPath: string | undefined): ProviderInfo["models"] {
    if (!configPath) return [];
    try {
      const config = JSON.parse(readFileSync(configPath, "utf8")) as {
        providers?: Record<string, { models?: Array<{ id: string; name?: string }> }>;
      };
      if (!config.providers) return [];
      const models: ProviderInfo["models"] = [];
      for (const provider of Object.values(config.providers)) {
        if (!provider.models) continue;
        for (const model of provider.models) {
          models.push({ id: model.id, name: model.name ?? model.id });
        }
      }
      return models;
    } catch {
      return [];
    }
  }
}
