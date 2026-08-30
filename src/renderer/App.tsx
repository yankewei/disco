import { FormEvent, useEffect, useMemo, useRef, useState } from "react";
import type { AboutInfo, AgentEvent, BackendKind, ProjectInfo, ProviderInfo, SessionInfo, StoredMessage } from "../shared/types";

type LiveMessage = StoredMessage & { tools?: NonNullable<StoredMessage["toolCalls"]> };
const providerNames: Record<BackendKind, string> = { codex: "Codex", claude: "Claude Code", opencode: "OpenCode" };
const disabledKey = "disco.disabledProviders";
function loadDisabled(): BackendKind[] {
  try {
    const parsed: unknown = JSON.parse(localStorage.getItem(disabledKey) ?? "[]");
    return Array.isArray(parsed) ? parsed.filter((kind): kind is BackendKind => kind === "codex" || kind === "claude" || kind === "opencode") : [];
  } catch { return []; }
}
const providerIcons: Record<BackendKind, { glyph: string; tint: string }> = {
  codex: { glyph: "❋", tint: "#272725" },
  claude: { glyph: "✳", tint: "#d9774b" },
  opencode: { glyph: "◆", tint: "#6f6d69" },
};

export function App() {
  const [settingsOnly] = useState(() => location.hash === "#settings");
  const [projects, setProjects] = useState<ProjectInfo[]>([]); const [sessionsByProject, setSessionsByProject] = useState<Map<string, SessionInfo[]>>(() => new Map()); const [providers, setProviders] = useState<ProviderInfo[]>([]);
  const [projectId, setProjectId] = useState<string>(); const [activeId, setActiveId] = useState<string>(); const [messages, setMessages] = useState<LiveMessage[]>([]); const [draft, setDraft] = useState(""); const [running, setRunning] = useState(false); const [plan, setPlan] = useState(false); const [backend, setBackend] = useState<BackendKind>("codex"); const [about, setAbout] = useState<AboutInfo>(); const [copied, setCopied] = useState<string>(); const [settingsTab, setSettingsTab] = useState<"providers" | "general">("providers"); const [query, setQuery] = useState(""); const [disabled, setDisabled] = useState<BackendKind[]>(() => loadDisabled()); const [fixOpen, setFixOpen] = useState<BackendKind>(); const [checkedAt, setCheckedAt] = useState<number>(); const [pendingApproval, setPendingApproval] = useState<{ approvalId: string; toolName: string; title?: string; input: Record<string, unknown> } | null>(null); const [showSettings, setShowSettings] = useState(false); const [expandedProjects, setExpandedProjects] = useState<Set<string>>(() => new Set());
  const sessions = sessionsByProject.get(projectId) ?? []; const active = sessions.find((session) => session.sessionId === activeId); const project = projects.find((item) => item.id === projectId);
  const rawProviders = useRef<ProviderInfo[]>([]);
  useEffect(() => {
    const unsubscribe = window.disco.onEvent(handleEvent);
    if (settingsOnly) {
      document.body.classList.add("settings-window");
      history.replaceState(null, "", location.pathname + location.search);
      void redetect();
    } else {
      void refresh();
      const onStorage = (event: StorageEvent) => { if (event.key === disabledKey) applyProviders(); };
      window.addEventListener("storage", onStorage);
      return () => { unsubscribe(); window.removeEventListener("storage", onStorage); };
    }
    return unsubscribe;
  }, [settingsOnly]);
  function applyProviders() { const off = loadDisabled(); setProviders(rawProviders.current.filter((item) => !off.includes(item.kind))); }
  async function refresh() { const [items, configured] = await Promise.all([window.disco.listProjects(), window.disco.providers()]); setProjects(items); rawProviders.current = configured; applyProviders(); const allSessions = await Promise.all(items.map(async (p) => [p.id, await window.disco.listSessions(p.id)] as const)); const map = new Map(allSessions); setSessionsByProject(map); if (items[0]) { setProjectId(items[0].id); setExpandedProjects(new Set([items[0].id])); const projectSessions = map.get(items[0].id) ?? []; if (projectSessions[0]) await select(projectSessions[0]); else { setActiveId(undefined); setMessages([]); } } }
  async function selectProject(id: string) { setProjectId(id); const items = await window.disco.listSessions(id); setSessionsByProject((prev) => { const next = new Map(prev); next.set(id, items); return next; }); if (items[0]) await select(items[0]); else { setActiveId(undefined); setMessages([]); } }
  async function toggleProject(id: string) { setExpandedProjects((prev) => { const next = new Set(prev); if (next.has(id)) { next.delete(id); } else { next.add(id); void window.disco.listSessions(id).then((items) => { setSessionsByProject((p) => { const m = new Map(p); m.set(id, items); return m; }); if (items[0] && !activeId) void select(items[0]); }); } return next; }); if (projectId !== id) setProjectId(id); }
  async function select(session: SessionInfo) { setActiveId(session.sessionId); setBackend(session.backend); setMessages(await window.disco.loadMessages(session.sessionId)); }
  async function addProject() { const path = await window.disco.chooseDirectory(); if (!path) return; const item = await window.disco.createProject(path); setProjects((all) => [item, ...all]); await selectProject(item.id); }
  async function redetect() { const [items, info] = await Promise.all([window.disco.providers(), window.disco.about()]); setProviders(items); setAbout(info); setCheckedAt(Date.now()); }
  function toggleProvider(kind: BackendKind) { const next = disabled.includes(kind) ? disabled.filter((item) => item !== kind) : [...disabled, kind]; localStorage.setItem(disabledKey, JSON.stringify(next)); setDisabled(next); }
  function copyHint(hint: string) { void navigator.clipboard?.writeText(hint).then(() => { setCopied(hint); setTimeout(() => setCopied(undefined), 1500); }).catch(() => {}); }
  async function attachContext(withDirectories: boolean) { const paths = await window.disco.chooseFiles(withDirectories); if (!paths.length) return; const mention = paths.map((path) => `@${path}`).join(" "); setDraft((text) => (text.trim() ? `${text.replace(/\s+$/, "")} ${mention}` : mention)); }
  async function addSession(kind: BackendKind = backend) { if (!projectId) { await addProject(); return; } const item = await window.disco.createSession(projectId, kind); setSessionsByProject((prev) => { const next = new Map(prev); const existing = next.get(projectId) ?? []; next.set(projectId, [item, ...existing]); return next; }); await select(item); }
  async function addSessionForProject(targetProjectId: string) { if (targetProjectId !== projectId) await selectProject(targetProjectId); const item = await window.disco.createSession(targetProjectId, backend); setSessionsByProject((prev) => { const next = new Map(prev); const existing = next.get(targetProjectId) ?? []; next.set(targetProjectId, [item, ...existing]); return next; }); await select(item); }
  function assistant(): LiveMessage { return { id: crypto.randomUUID(), role: "assistant", text: "", createdAt: new Date().toISOString(), tools: [] }; }
  function handleEvent(event: AgentEvent) { if (event.sessionId !== activeId) return; if (event.type === "run-finished") { setRunning(false); setPendingApproval(null); if (event.error) append("text", `\n\n运行失败：${event.error}`); return; } if (event.type === "approval-requested") { setPendingApproval({ approvalId: event.approvalId, toolName: event.toolName, title: event.title, input: event.input }); return; } if (event.type === "approval-resolved") { setPendingApproval(null); return; } if (event.type === "text" || event.type === "reasoning") append(event.type, event.text); if (event.type === "tool") setMessages((all) => { const next = [...all]; if (!next.at(-1) || next.at(-1)?.role !== "assistant") next.push(assistant()); const target = next.at(-1)!; const tool = target.tools?.find((item) => item.id === event.id); if (tool) { tool.status = event.state; tool.output = event.output; } else target.tools = [...(target.tools ?? []), { id: event.id, name: event.title, status: event.state, output: event.output }]; return next; }); }
  function append(field: "text" | "reasoning", text: string) { setMessages((all) => { const next = [...all]; if (!next.at(-1) || next.at(-1)?.role !== "assistant") next.push(assistant()); const target = next.at(-1)!; target[field] = `${target[field] ?? ""}${text}`; return next; }); }
  async function send(event: FormEvent) { event.preventDefault(); if (running) return; if (!activeId) { await addSession(); return; } const text = draft.trim(); if (!text) return; setDraft(""); setMessages((all) => [...all, { id: crypto.randomUUID(), role: "user", text, createdAt: new Date().toISOString() }, assistant()]); setRunning(true); await window.disco.prompt(activeId, text, plan ? "plan" : "agent"); }
  const title = useMemo(() => active?.title ?? (project ? "新对话" : "开始使用 Disco"), [active, project]);

  if (settingsOnly) {
    const q = query.trim().toLowerCase();
    const visibleProviders = providers.filter((item) => !q || item.name.toLowerCase().includes(q));
    const navSections = [
      { key: "providers" as const, label: "服务商", icon: "☁" },
      { key: "general" as const, label: "通用", icon: "⚙" },
    ].filter((section) => !q || section.label.includes(query.trim()));
    const checkedLabel = checkedAt === undefined ? undefined : Date.now() - checkedAt < 60_000 ? "刚刚检查过" : `${Math.max(1, Math.round((Date.now() - checkedAt) / 60_000))} 分钟前检查`;
    return <div className="settings standalone">
      <div className="settings-body">
        <nav className="settings-nav" aria-label="设置导航">
          <button className="settings-back" onClick={() => window.close()}>← 返回</button>
          <input className="settings-search" type="search" placeholder="搜索设置" value={query} onChange={(event) => setQuery(event.target.value)}/>
          {navSections.map((section) => <button key={section.key} className={`nav-item${settingsTab === section.key ? " active" : ""}`} onClick={() => setSettingsTab(section.key)}><span className="nav-icon" aria-hidden="true">{section.icon}</span><span>{section.label}</span></button>)}
        </nav>
        {settingsTab === "providers" ? <div className="panel-card">
          <header className="panel-head">
            <div><h3>编程智能体</h3><p className="panel-sub">Disco 调用安装在这台电脑上的智能体命令行工具。请先安装相应工具或完成登录，然后刷新。</p></div>
            <div className="panel-refresh"><button className="quiet" onClick={() => void redetect()}>⟳ 刷新</button>{checkedLabel && <small>{checkedLabel}</small>}</div>
          </header>
          <div className="agent-list">
            {visibleProviders.map((item) => <div className="agent-item" key={item.kind}>
              <div className="agent-row">
                <span className="agent-icon" style={{ color: providerIcons[item.kind].tint }} aria-hidden="true">{providerIcons[item.kind].glyph}</span>
                <div className="agent-meta">
                  <strong>{item.name}{disabled.includes(item.kind) && <em className="agent-off">已停用</em>}</strong>
                  {item.available ? <span className="agent-status"><i className="dot ready" />{item.evidence && <code>{item.evidence}</code>}</span> : <span className="agent-status"><i className="dot missing" />未检测到登录态或工具</span>}
                </div>
                {item.available ? <label className="switch" title={disabled.includes(item.kind) ? "启用该智能体" : "停用该智能体"}><input type="checkbox" checked={!disabled.includes(item.kind)} onChange={() => toggleProvider(item.kind)} aria-label={`启用 ${item.name}`}/><span aria-hidden="true" /></label> : item.hint && <button type="button" className="agent-fix-toggle" onClick={() => setFixOpen(fixOpen === item.kind ? undefined : item.kind)}>安装指引 ›</button>}
              </div>
              {!item.available && fixOpen === item.kind && item.hint && <div className="agent-fix"><span>在终端运行</span><code>{item.hint}</code><button type="button" onClick={() => copyHint(item.hint!)}>{copied === item.hint ? "已复制" : "复制"}</button></div>}
            </div>)}
            {visibleProviders.length === 0 && <p className="panel-empty">没有匹配「{query.trim()}」的设置项</p>}
          </div>
        </div> : <div className="panel-card">
          <header className="panel-head"><div><h3>数据与应用</h3><p className="panel-sub">所有项目、会话与消息都保存在本机 SQLite 数据库中，不会上传。</p></div></header>
          <div className="data-card">
            <div><span>会话记录</span><code title={about?.dataPath}>{about?.dataPath}</code></div>
            <div><span>版本</span><code>{about?.version}</code></div>
          </div>
        </div>}
      </div>
    </div>;
  }

  return <main className="app-shell">
    <aside className="sidebar">
      <div className="brand"><span>Disco</span><span className="brand-caret">⌄</span><button aria-label="搜索会话" className="icon-button">⌕</button></div>
      <button className="new-session" onClick={() => void addSession()}>新对话</button>
      <button className="add-project" onClick={() => void addProject()}>添加项目</button>
      <div className="sidebar-scroll">
        {projects.map((item) => { const expanded = expandedProjects.has(item.id); return <div key={item.id} className="project-tree"><div className="project-item"><button className={`project-row ${projectId === item.id ? "active" : ""}`} onClick={() => void toggleProject(item.id)}><span className={`project-caret${expanded ? " open" : ""}`}>▸</span><span>{item.name}</span></button><button className="project-add" aria-label="新建会话" title="新建会话" onClick={(event) => { event.stopPropagation(); void addSessionForProject(item.id); }}>+</button></div>{expanded && <nav className="session-tree">{(sessionsByProject.get(item.id) ?? []).map((s) => <button key={s.sessionId} className={`session-tree-item ${activeId === s.sessionId ? "active" : ""}`} onClick={() => void select(s)}><span>{s.title}</span></button>)}</nav>}</div>; })}
        {projects.length === 0 && <button className="sidebar-hint" onClick={() => void addProject()}>选择一个本地文件夹</button>}
      </div>
      <div className="sidebar-footer"><button className="settings-button" aria-label="Agent 设置" title="Agent 设置" onClick={() => { setShowSettings(true); void redetect(); }}>⚙</button></div>
    </aside>

    <section className="conversation">
      <header className="workspace-header">
          <div><span className="crumb">{project?.name ?? "工作区"}</span><h1>{title}</h1><button className="more" aria-label="更多操作">•••</button></div>
          <div className="header-actions"><span className={`status ${running ? "working" : ""}`}><i />{running ? "正在处理" : active ? providerNames[active.backend] : "准备就绪"}</span><button className="share" type="button">分享</button></div>
        </header>
        <div className="timeline">
          {!active && <section className="start-panel"><div className="agent-mark">✦</div><p className="start-kicker">Disco workspace</p><h2>让 coding agent 帮你完成工作</h2><p>连接一个本地代码目录，然后让 agent 分析、规划并执行下一步。所有上下文都留在你的工作区里。</p><div className="start-actions"><button className="primary-action" onClick={() => void addProject()}>选择本地文件夹</button><span>或将文件夹拖到此处</span></div><div className="provider-strip">{providers.map((item) => <button key={item.kind} onClick={() => void addSession(item.kind)}><strong>{item.name}</strong><small>{item.detail}</small></button>)}</div></section>}
          {messages.map((message) => <article className={`message ${message.role}`} key={message.id}>
            {message.role === "assistant" && (message.text || message.tools?.length) && <div className="agent-heading"><span>✦</span> Agent</div>}
            {message.reasoning && <details><summary>分析过程</summary><pre>{message.reasoning}</pre></details>}
            {message.text && <div className="message-text">{message.text}</div>}
            {message.tools?.length ? <section className="tool-group"><div className="tool-group-title">工具调用</div>{message.tools.map((tool) => <details className="tool" key={tool.id}><summary><span>{tool.name}</span><em>{tool.status === "started" ? "运行中" : "完成"}</em></summary>{tool.output && <pre>{tool.output}</pre>}</details>)}</section> : null}
          </article>)}
          {pendingApproval && <div className="approval-card">
            <div className="approval-head"><span className="approval-icon">⚠</span><strong>{pendingApproval.title ?? pendingApproval.toolName}</strong></div>
            <pre className="approval-input">{JSON.stringify(pendingApproval.input, null, 2)}</pre>
            <div className="approval-actions">
              <button className="approval-approve" onClick={() => void window.disco.approve(pendingApproval.approvalId, "approved")}>批准</button>
              <button className="approval-deny" onClick={() => void window.disco.approve(pendingApproval.approvalId, "denied")}>拒绝</button>
            </div>
          </div>}
        </div>
        <form className="composer" onSubmit={send}>
          <label className="composer-label" htmlFor="prompt">发送给 Agent</label>
          <textarea id="prompt" value={draft} onChange={(event) => setDraft(event.target.value)} onKeyDown={(event) => { if ((event.metaKey || event.ctrlKey) && event.key === "Enter") { event.preventDefault(); event.currentTarget.form?.requestSubmit(); } }} placeholder={active ? "描述你想让 Agent 完成的工作，或 @ 引用文件、命令" : "先选择一个本地项目，然后开始对话"} disabled={running} rows={3}/>
          <div><button type="button" className="attach" aria-label="添加上下文" title="添加文件或目录作为上下文" onClick={() => void attachContext(true)}>+</button><button type="button" className="context-action" aria-label="引用文件" title="引用文件" onClick={() => void attachContext(false)}>@</button><select className="backend-select" aria-label="选择 Agent" value={backend} disabled={!!active} title={active ? "当前会话已绑定该 Agent，新建对话可切换" : "选择用于新对话的 Agent"} onChange={(event) => setBackend(event.target.value as BackendKind)}>{providers.map((item) => <option key={item.kind} value={item.kind}>{item.name}</option>)}</select><label className="plan-toggle"><input type="checkbox" checked={plan} onChange={(event) => setPlan(event.target.checked)} disabled={!active || !providers.find((item) => item.kind === active?.backend)?.supportsPlan}/><span>计划模式</span></label><span className="send-hint">{active ? "⌘↵ 发送" : "选择项目后发送"}</span>{running ? <button type="button" className="quiet" onClick={() => activeId && void window.disco.cancel(activeId)}>停止</button> : <button type="submit" className="send" aria-label="发送">↑</button>}</div>
        </form>
    </section>
    {showSettings && <div className="settings-overlay" onClick={(event) => { if (event.target === event.currentTarget) setShowSettings(false); }}>
      <div className="settings-modal">
        <button className="settings-close" onClick={() => setShowSettings(false)}>✕</button>
        <div className="settings-body">
          <nav className="settings-nav" aria-label="设置导航">
            <input className="settings-search" type="search" placeholder="搜索设置" value={query} onChange={(event) => setQuery(event.target.value)}/>
            {[{ key: "providers" as const, label: "服务商", icon: "☁" }, { key: "general" as const, label: "通用", icon: "⚙" }].filter((section) => !query.trim() || section.label.includes(query.trim())).map((section) => <button key={section.key} className={`nav-item${settingsTab === section.key ? " active" : ""}`} onClick={() => setSettingsTab(section.key)}><span className="nav-icon" aria-hidden="true">{section.icon}</span><span>{section.label}</span></button>)}
          </nav>
          {settingsTab === "providers" ? <div className="panel-card">
            <header className="panel-head">
              <div><h3>编程智能体</h3><p className="panel-sub">Disco 调用安装在这台电脑上的智能体命令行工具。请先安装相应工具或完成登录，然后刷新。</p></div>
              <div className="panel-refresh"><button className="quiet" onClick={() => void redetect()}>⟳ 刷新</button>{(() => { const label = checkedAt === undefined ? undefined : Date.now() - checkedAt < 60_000 ? "刚刚检查过" : `${Math.max(1, Math.round((Date.now() - checkedAt) / 60_000))} 分钟前检查`; return label && <small>{label}</small>; })()}</div>
            </header>
            <div className="agent-list">
              {providers.filter((item) => !query.trim() || item.name.toLowerCase().includes(query.trim().toLowerCase())).map((item) => <div className="agent-item" key={item.kind}>
                <div className="agent-row">
                  <span className="agent-icon" style={{ color: providerIcons[item.kind].tint }} aria-hidden="true">{providerIcons[item.kind].glyph}</span>
                  <div className="agent-meta">
                    <strong>{item.name}{disabled.includes(item.kind) && <em className="agent-off">已停用</em>}</strong>
                    {item.available ? <span className="agent-status"><i className="dot ready" />{item.evidence && <code>{item.evidence}</code>}</span> : <span className="agent-status"><i className="dot missing" />未检测到登录态或工具</span>}
                  </div>
                  {item.available ? <label className="switch" title={disabled.includes(item.kind) ? "启用该智能体" : "停用该智能体"}><input type="checkbox" checked={!disabled.includes(item.kind)} onChange={() => toggleProvider(item.kind)} aria-label={`启用 ${item.name}`}/><span aria-hidden="true" /></label> : item.hint && <button type="button" className="agent-fix-toggle" onClick={() => setFixOpen(fixOpen === item.kind ? undefined : item.kind)}>安装指引 ›</button>}
                </div>
                {!item.available && fixOpen === item.kind && item.hint && <div className="agent-fix"><span>在终端运行</span><code>{item.hint}</code><button type="button" onClick={() => copyHint(item.hint!)}>{copied === item.hint ? "已复制" : "复制"}</button></div>}
              </div>)}
              {providers.filter((item) => !query.trim() || item.name.toLowerCase().includes(query.trim().toLowerCase())).length === 0 && <p className="panel-empty">没有匹配「{query.trim()}」的设置项</p>}
            </div>
          </div> : <div className="panel-card">
            <header className="panel-head"><div><h3>数据与应用</h3><p className="panel-sub">所有项目、会话与消息都保存在本机 SQLite 数据库中，不会上传。</p></div></header>
            <div className="data-card">
              <div><span>会话记录</span><code title={about?.dataPath}>{about?.dataPath}</code></div>
              <div><span>版本</span><code>{about?.version}</code></div>
            </div>
          </div>}
        </div>
      </div>
    </div>}
  </main>;
}
