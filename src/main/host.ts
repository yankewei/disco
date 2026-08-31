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
  RunStatus,
  SessionInfo,
  StoredMessage,
  ToolCall,
} from "../shared/types.js";
import {
  ClaudeBackend,
  CodexBackend,
  OpenCodeBackend,
  type AgentBackend,
  type BackendEvent,
  type RequestApproval,
} from "./backends/index.js";
import { findExecutable } from "./backends/executable.js";
import { DiscoStore } from "./store.js";

interface ActiveRun {
  runId: string;
  controller: AbortController;
}

interface PendingApproval {
  resolve: (decision: ApprovalDecision) => void;
  sessionId: string;
  runId: string;
  signal: AbortSignal;
  abortHandler: () => void;
}

export class AgentHost {
  private readonly runs = new Map<string, ActiveRun>();
  private readonly pendingApprovals = new Map<string, PendingApproval>();
  private readonly activePromptCompletions = new Set<Promise<void>>();
  private readonly backends: Record<BackendKind, AgentBackend>;
  private isShuttingDown = false;

  constructor(
    private readonly store: DiscoStore,
    private readonly emit: (event: AgentEvent) => void,
    backends: Record<BackendKind, AgentBackend> = {
      codex: new CodexBackend(),
      claude: new ClaudeBackend(),
      opencode: new OpenCodeBackend(),
    },
  ) {
    this.backends = backends;
  }

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
    if (this.isShuttingDown) {
      throw new Error("Disco 正在关闭");
    }
    const session = this.store.getSession(sessionId);
    if (!session) {
      throw new Error("会话不存在");
    }
    const project = this.store.getProject(session.projectId);
    if (!project) {
      throw new Error("项目不存在");
    }
    const backend = this.backends[session.backend];
    if (!backend) {
      throw new Error("会话绑定的 Agent 不可用");
    }
    if (mode === "plan" && !backend.supportsPlan) {
      throw new Error(`${session.backend} 不支持计划模式`);
    }
    if (this.runs.has(sessionId)) {
      throw new Error("该会话正在运行");
    }

    const runId = randomUUID();
    const controller = new AbortController();
    let resolvePromptCompletion: () => void = () => {};
    const promptCompletion = new Promise<void>((resolveCompletion) => {
      resolvePromptCompletion = resolveCompletion;
    });
    this.activePromptCompletions.add(promptCompletion);
    this.runs.set(sessionId, { runId, controller });
    this.notify({ type: "run-started", sessionId, runId });

    let assistantText = "";
    let reasoning = "";
    const toolCalls: ToolCall[] = [];
    const items: NonNullable<StoredMessage["items"]> = [];
    let runStatus: RunStatus = "completed";
    let runError: string | undefined;
    let sessionTitle: string | undefined;

    const handleBackendEvent = (event: BackendEvent): void => {
      if (event.type === "text") {
        assistantText += event.text;
      } else if (event.type === "reasoning") {
        reasoning += event.text;
      } else if (event.type === "item") {
        const itemIndex = items.findIndex((item) => item.id === event.item.id);
        if (itemIndex === -1) {
          items.push(event.item);
        } else {
          items[itemIndex] = event.item;
        }
      } else {
        const toolCall = toolCalls.find((item) => item.id === event.id);
        if (toolCall) {
          if (toolCall.status === "started" || event.state !== "started") {
            toolCall.status = event.state;
          }
          if (event.input !== undefined) {
            toolCall.input = event.input;
          }
          if (event.output !== undefined) {
            toolCall.output = event.output;
          }
          if (event.error !== undefined) {
            toolCall.error = event.error;
          }
        } else {
          toolCalls.push({
            id: event.id,
            name: event.title,
            status: event.state,
            input: event.input,
            output: event.output,
            error: event.error,
          });
        }
      }
      this.notify({ ...event, sessionId, runId });
    };

    const registerBackendSessionId = (backendSessionId: string): void => {
      if (session.backendSessionId === backendSessionId) {
        return;
      }
      session.backendSessionId = backendSessionId;
      this.store.updateSession(sessionId, backendSessionId);
    };

    const requestApproval: RequestApproval = (toolName, title, input) => {
      const approvalId = randomUUID();
      return new Promise<ApprovalDecision>((resolveApproval) => {
        const abortHandler = (): void => {
          this.resolveApproval(approvalId, "denied");
        };
        this.pendingApprovals.set(approvalId, {
          resolve: resolveApproval,
          sessionId,
          runId,
          signal: controller.signal,
          abortHandler,
        });
        this.notify({
          type: "approval-requested",
          sessionId,
          runId,
          approvalId,
          toolName,
          title,
          input,
        });
        if (controller.signal.aborted) {
          abortHandler();
        } else {
          controller.signal.addEventListener("abort", abortHandler, {
            once: true,
          });
        }
      });
    };

    try {
      const userMessage = {
        id: randomUUID(),
        role: "user" as const,
        text,
        createdAt: new Date().toISOString(),
      };
      this.store.appendMessage(sessionId, userMessage);
      if (session.title === "新对话") {
        sessionTitle = titleFromPrompt(text);
        this.store.updateSessionTitle(sessionId, sessionTitle);
      }

      const backendSessionId = await backend.run({
        backendSessionId: session.backendSessionId,
        workingDirectory: project.path,
        prompt: text,
        mode,
        emit: handleBackendEvent,
        signal: controller.signal,
        requestApproval,
        onBackendSessionId: registerBackendSessionId,
      });
      registerBackendSessionId(backendSessionId);
    } catch (error) {
      runStatus = controller.signal.aborted ? "cancelled" : "failed";
      if (runStatus === "failed") {
        runError = error instanceof Error ? error.message : "运行失败";
      }
    } finally {
      if (
        assistantText ||
        reasoning ||
        toolCalls.length > 0 ||
        items.length > 0 ||
        runStatus !== "completed"
      ) {
        try {
          this.store.appendMessage(sessionId, {
            id: randomUUID(),
            role: "assistant",
            text: assistantText,
            reasoning: reasoning || undefined,
            toolCalls: toolCalls.length > 0 ? toolCalls : undefined,
            items: items.length > 0 ? items : undefined,
            status: runStatus === "completed" ? undefined : runStatus,
            error: runError,
            createdAt: new Date().toISOString(),
          });
        } catch (error) {
          runStatus = "failed";
          runError = error instanceof Error ? error.message : "保存运行结果失败";
        }
      }

      this.clearApprovals(sessionId, runId);
      if (this.runs.get(sessionId)?.runId === runId) {
        this.runs.delete(sessionId);
      }
      try {
        this.notify({
          type: "run-finished",
          sessionId,
          runId,
          status: runStatus,
          sessionTitle,
          error: runError,
        });
      } finally {
        resolvePromptCompletion();
        this.activePromptCompletions.delete(promptCompletion);
      }
    }
  }

  approve(approvalId: string, decision: ApprovalDecision): void {
    this.resolveApproval(approvalId, decision);
  }

  cancel(sessionId: string): void {
    const activeRun = this.runs.get(sessionId);
    if (!activeRun) {
      return;
    }
    activeRun.controller.abort();
    this.clearApprovals(sessionId, activeRun.runId);
  }

  async shutdown(): Promise<void> {
    this.isShuttingDown = true;
    for (const activeRun of this.runs.values()) {
      activeRun.controller.abort();
    }
    for (const approvalId of this.pendingApprovals.keys()) {
      this.resolveApproval(approvalId, "denied");
    }
    await Promise.all(this.activePromptCompletions);
    await Promise.allSettled(
      [...new Set(Object.values(this.backends))].map((backend) =>
        backend.shutdown?.(),
      ),
    );
  }

  private notify(event: AgentEvent): void {
    try {
      this.emit(event);
    } catch {
      // A renderer can disappear while a backend is still finishing.
    }
  }

  private resolveApproval(
    approvalId: string,
    decision: ApprovalDecision,
  ): void {
    const pendingApproval = this.pendingApprovals.get(approvalId);
    if (!pendingApproval) {
      return;
    }
    this.pendingApprovals.delete(approvalId);
    pendingApproval.signal.removeEventListener(
      "abort",
      pendingApproval.abortHandler,
    );
    pendingApproval.resolve(decision);
    this.notify({
      type: "approval-resolved",
      sessionId: pendingApproval.sessionId,
      runId: pendingApproval.runId,
      approvalId,
    });
  }

  private clearApprovals(sessionId: string, runId: string): void {
    for (const [approvalId, pendingApproval] of this.pendingApprovals) {
      if (
        pendingApproval.sessionId === sessionId &&
        pendingApproval.runId === runId
      ) {
        this.resolveApproval(approvalId, "denied");
      }
    }
  }

  providers(): ProviderInfo[] {
    const homeDirectory = homedir();
    const claudeCredentialsPath = [
      join(homeDirectory, ".claude", ".credentials.json"),
      join(homeDirectory, ".claude.json"),
    ].find((file) => existsSync(file));
    const openCodeConfigPath = [
      join(homeDirectory, ".config", "opencode", "opencode.json"),
      join(homeDirectory, ".opencode", "opencode.json"),
    ].find((file) => existsSync(file));
    const codexExecutable = findExecutable("codex");
    const openCodeExecutable = findExecutable("opencode");
    const isCodexAvailable = Boolean(codexExecutable);
    const isClaudeAvailable =
      Boolean(process.env.ANTHROPIC_API_KEY) || Boolean(claudeCredentialsPath);
    const isOpenCodeAvailable = Boolean(openCodeExecutable);
    let openCodeDetail = "未找到 opencode 命令，请先安装 OpenCode";
    if (openCodeExecutable && !openCodeConfigPath) {
      openCodeDetail = "已检测到 opencode 命令，将使用 OpenCode 当前配置";
    } else if (isOpenCodeAvailable) {
      openCodeDetail = "已检测到 OpenCode 配置和命令";
    }

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
          ? "已检测到本地 Codex CLI；未登录时请在终端运行 codex login"
          : "未找到 codex 命令，请先安装 Codex CLI",
        evidence: codexExecutable,
        hint: "codex login",
        supportsPlan: this.backends.codex.supportsPlan,
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
        supportsPlan: this.backends.claude.supportsPlan,
        models: claudeModels,
      },
      {
        kind: "opencode",
        name: "OpenCode",
        available: isOpenCodeAvailable,
        detail: openCodeDetail,
        evidence: openCodeConfigPath ?? openCodeExecutable,
        hint: "opencode",
        supportsPlan: this.backends.opencode.supportsPlan,
        models: openCodeModels,
      },
    ];
  }

  private readOpenCodeModels(
    configPath: string | undefined,
  ): ProviderInfo["models"] {
    if (!configPath) {
      return [];
    }
    try {
      const config = JSON.parse(readFileSync(configPath, "utf8")) as unknown;
      const configRecord = recordValue(config);
      const providers =
        recordValue(configRecord?.provider) ??
        recordValue(configRecord?.providers);
      if (!providers) {
        return [];
      }
      const models: ProviderInfo["models"] = [];
      for (const provider of Object.values(providers)) {
        const providerModels = recordValue(provider)?.models;
        if (Array.isArray(providerModels)) {
          for (const model of providerModels) {
            const modelRecord = recordValue(model);
            const id = stringValue(modelRecord?.id);
            if (id) {
              models.push({ id, name: stringValue(modelRecord?.name) ?? id });
            }
          }
        } else {
          const modelsById = recordValue(providerModels);
          if (!modelsById) {
            continue;
          }
          for (const [id, model] of Object.entries(modelsById)) {
            const modelRecord = recordValue(model);
            models.push({
              id,
              name: stringValue(modelRecord?.name) ?? id,
            });
          }
        }
      }
      return models;
    } catch {
      return [];
    }
  }
}

function titleFromPrompt(prompt: string): string {
  const compactPrompt = prompt.replace(/\s+/g, " ").trim();
  return compactPrompt.length > 40
    ? `${compactPrompt.slice(0, 40)}…`
    : compactPrompt;
}

function recordValue(value: unknown): Record<string, unknown> | undefined {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    return undefined;
  }
  return value as Record<string, unknown>;
}

function stringValue(value: unknown): string | undefined {
  return typeof value === "string" ? value : undefined;
}
