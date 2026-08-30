import { existsSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { basename, join, resolve } from "node:path";
import { randomUUID } from "node:crypto";
import type { AgentEvent, BackendKind, ProjectInfo, ProviderInfo, RunMode, SessionInfo, StoredMessage } from "../shared/types.js";
import { ClaudeBackend, CodexBackend, OpenCodeBackend, type AgentBackend, type RequestApproval } from "./backends.js";
import { DiscoStore } from "./store.js";

export class AgentHost {
  private readonly backends: Record<BackendKind, AgentBackend> = { codex: new CodexBackend(), claude: new ClaudeBackend(), opencode: new OpenCodeBackend() };
  private readonly runs = new Map<string, AbortController>();
  private readonly pendingApprovals = new Map<string, { resolve: (decision: "approved" | "denied") => void; sessionId: string }>();

  constructor(private readonly store: DiscoStore, private readonly emit: (event: AgentEvent) => void) {}

  listProjects() { return this.store.listProjects(); }
  createProject(path: string): ProjectInfo {
    const normalized = resolve(path);
    if (!existsSync(normalized) || !statSync(normalized).isDirectory()) throw new Error("工作区路径无效或不可访问");
    const existing = this.store.projectByPath(normalized);
    if (existing) return existing;
    const project = { id: randomUUID(), name: basename(normalized) || normalized, path: normalized, createdAt: new Date().toISOString() };
    this.store.createProject(project); return project;
  }
  deleteProject(id: string) { this.store.deleteProject(id); }
  listSessions(projectId?: string) { return this.store.listSessions(projectId); }
  createSession(projectId: string, backend: BackendKind): SessionInfo {
    if (!this.store.getProject(projectId)) throw new Error("项目不存在");
    const session = { sessionId: randomUUID(), projectId, backend, title: "新对话", updatedAt: new Date().toISOString() };
    this.store.createSession(session); return session;
  }
  deleteSession(id: string) { this.cancel(id); this.store.deleteSession(id); }
  messages(id: string) { return this.store.messages(id); }

  async prompt(id: string, text: string, mode: RunMode) {
    const session = this.store.getSession(id);
    if (!session) throw new Error("会话不存在");
    const project = this.store.getProject(session.projectId);
    if (!project) throw new Error("项目不存在");
    if (this.runs.has(id)) throw new Error("该会话正在运行");
    const now = new Date().toISOString();
    this.store.appendMessage(id, { id: randomUUID(), role: "user", text, createdAt: now });
    const controller = new AbortController(); this.runs.set(id, controller);
    let assistantText = ""; let reasoning = ""; const tools: NonNullable<StoredMessage["toolCalls"]> = [];
    const onEvent = (event: import("./backends.js").AgentEvent) => {
      if (event.type === "text") assistantText += event.text;
      if (event.type === "reasoning") reasoning += event.text;
      if (event.type === "tool") {
        const current = tools.find((tool) => tool.id === event.id);
        if (current) { current.status = event.state; current.output = event.output; } else tools.push({ id: event.id, name: event.title, status: event.state, output: event.output });
      }
      if (event.type === "text" || event.type === "reasoning" || event.type === "tool" || event.type === "usage") this.emit({ ...event, sessionId: id });
    };
    const requestApproval: RequestApproval = (_approvalId, toolName, title, input) => {
      const approvalId = randomUUID();
      return new Promise<"approved" | "denied">((resolvePromise) => {
        this.pendingApprovals.set(approvalId, { resolve: resolvePromise, sessionId: id });
        this.emit({ type: "approval-requested", sessionId: id, approvalId, toolName, title, input });
        const onAbort = () => { const entry = this.pendingApprovals.get(approvalId); if (entry) { this.pendingApprovals.delete(approvalId); entry.resolve("denied"); this.emit({ type: "approval-resolved", sessionId: id, approvalId, decision: "denied" }); } };
        if (controller.signal.aborted) { onAbort(); return; }
        controller.signal.addEventListener("abort", onAbort, { once: true });
      });
    };
    try {
      const backendSessionId = await this.backends[session.backend].run(session.backendSessionId, project.path, text, mode, onEvent, controller.signal, requestApproval);
      this.store.updateSession(id, backendSessionId);
      if (assistantText || reasoning || tools.length) this.store.appendMessage(id, { id: randomUUID(), role: "assistant", text: assistantText, reasoning: reasoning || undefined, toolCalls: tools.length ? tools : undefined, createdAt: new Date().toISOString() });
      this.emit({ type: "run-finished", sessionId: id });
    } catch (error) {
      const message = error instanceof Error ? error.message : "运行失败";
      this.emit({ type: "run-finished", sessionId: id, error: controller.signal.aborted ? undefined : message });
    } finally { this.clearApprovals(id); this.runs.delete(id); }
  }
  approve(approvalId: string, decision: "approved" | "denied") { const entry = this.pendingApprovals.get(approvalId); if (entry) { this.pendingApprovals.delete(approvalId); entry.resolve(decision); this.emit({ type: "approval-resolved", sessionId: entry.sessionId, approvalId, decision }); } }
  cancel(id: string) { this.runs.get(id)?.abort(); this.clearApprovals(id); }
  private clearApprovals(sessionId: string) { for (const [approvalId, entry] of this.pendingApprovals) { if (entry.sessionId === sessionId) { this.pendingApprovals.delete(approvalId); entry.resolve("denied"); this.emit({ type: "approval-resolved", sessionId, approvalId, decision: "denied" }); } } }
  providers(): ProviderInfo[] {
    const home = homedir();
    const codexAuth = join(home, ".codex", "auth.json");
    const claudeCreds = [join(home, ".claude", ".credentials.json"), join(home, ".claude.json")].find((file) => existsSync(file));
    const claudeReady = Boolean(process.env.ANTHROPIC_API_KEY) || Boolean(claudeCreds);
    const opencodeConfig = [join(home, ".config", "opencode", "opencode.json"), join(home, ".opencode", "opencode.json")].find((file) => existsSync(file));
    const codexReady = existsSync(codexAuth);
    return [
      { kind: "codex", name: "Codex", available: codexReady, detail: codexReady ? "已检测到 codex 登录态" : "未检测到登录态，先在终端完成登录后重新检测", evidence: codexReady ? codexAuth : undefined, hint: "codex login", supportsPlan: true, supportsApproval: true },
      { kind: "claude", name: "Claude Code", available: claudeReady, detail: claudeReady ? "已检测到 Claude Code 登录态或 API Key" : "未检测到登录态，先在终端登录或设置 ANTHROPIC_API_KEY 后重新检测", evidence: claudeReady ? (claudeCreds ?? "ANTHROPIC_API_KEY") : undefined, hint: "claude", supportsPlan: true, supportsApproval: true },
      { kind: "opencode", name: "OpenCode", available: Boolean(opencodeConfig), detail: opencodeConfig ? "已检测到 OpenCode 配置" : "未检测到配置，先在终端完成 provider 配置后重新检测", evidence: opencodeConfig, hint: "opencode", supportsPlan: false, supportsApproval: false },
    ];
  }
}
