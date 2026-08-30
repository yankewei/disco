import { type FormEvent, type JSX, useEffect, useRef, useState } from "react";
import type {
  AgentEvent,
  BackendKind,
  ProjectInfo,
  ProviderInfo,
  SessionInfo,
  StoredMessage,
} from "../shared/types";
import {
  ConversationTimeline,
  type PendingApproval,
} from "./ConversationTimeline";
import { PromptComposer } from "./PromptComposer";
import {
  isProviderPreferencesEvent,
  loadDisabledProviders,
} from "./providerPreferences";
import { SettingsView } from "./SettingsView";
import { WorkspaceSidebar } from "./WorkspaceSidebar";

const providerNames: Record<BackendKind, string> = {
  codex: "Codex",
  claude: "Claude Code",
  opencode: "OpenCode",
};

function createAssistantMessage(): StoredMessage {
  return {
    id: crypto.randomUUID(),
    role: "assistant",
    text: "",
    createdAt: new Date().toISOString(),
  };
}

function updateLatestAssistant(
  messages: StoredMessage[],
  update: (message: StoredMessage) => void,
): StoredMessage[] {
  const lastMessage = messages.at(-1);
  const assistantMessage =
    lastMessage?.role === "assistant"
      ? {
          ...lastMessage,
          toolCalls: lastMessage.toolCalls?.map((toolCall) => ({
            ...toolCall,
          })),
        }
      : createAssistantMessage();
  update(assistantMessage);

  if (lastMessage?.role === "assistant") {
    return [...messages.slice(0, -1), assistantMessage];
  }
  return [...messages, assistantMessage];
}

export function App(): JSX.Element {
  const [showSettings, setShowSettings] = useState(false);
  if (showSettings) {
    return <SettingsView onClose={() => setShowSettings(false)} />;
  }
  return <Workspace onOpenSettings={() => setShowSettings(true)} />;
}

function Workspace({ onOpenSettings }: { onOpenSettings: () => void }): JSX.Element {
  const [projects, setProjects] = useState<ProjectInfo[]>([]);
  const [sessionsByProject, setSessionsByProject] = useState<
    Map<string, SessionInfo[]>
  >(() => new Map());
  const [providers, setProviders] = useState<ProviderInfo[]>([]);
  const [selectedProjectId, setSelectedProjectId] = useState<string>();
  const [activeSessionId, setActiveSessionId] = useState<string>();
  const [messages, setMessages] = useState<StoredMessage[]>([]);
  const [draft, setDraft] = useState("");
  const [running, setRunning] = useState(false);
  const [planMode, setPlanMode] = useState(false);
  const [backend, setBackend] = useState<BackendKind>("codex");
  const [pendingApproval, setPendingApproval] =
    useState<PendingApproval | null>(null);
  const [expandedProjects, setExpandedProjects] = useState<Set<string>>(
    () => new Set(),
  );
  const detectedProviders = useRef<ProviderInfo[]>([]);

  const selectedProjectSessions = selectedProjectId
    ? (sessionsByProject.get(selectedProjectId) ?? [])
    : [];
  const activeSession = selectedProjectSessions.find(
    (session) => session.sessionId === activeSessionId,
  );
  const activeProject = projects.find(
    (project) => project.id === selectedProjectId,
  );
  const title =
    activeSession?.title ?? (activeProject ? "新对话" : "开始使用 Disco");

  useEffect(() => {
    void refreshWorkspace();
    const handleStorage = (event: StorageEvent): void => {
      if (isProviderPreferencesEvent(event)) {
        applyProviderPreferences();
      }
    };
    window.addEventListener("storage", handleStorage);
    return () => window.removeEventListener("storage", handleStorage);
  }, []);

  useEffect(() => window.disco.onEvent(handleAgentEvent), [activeSessionId]);

  function applyProviderPreferences(): void {
    const disabledProviders = loadDisabledProviders();
    setProviders(
      detectedProviders.current.filter(
        (provider) => !disabledProviders.includes(provider.kind),
      ),
    );
  }

  async function refreshWorkspace(): Promise<void> {
    const [projectList, providerList] = await Promise.all([
      window.disco.listProjects(),
      window.disco.providers(),
    ]);
    setProjects(projectList);
    detectedProviders.current = providerList;
    applyProviderPreferences();

    const projectSessions = await Promise.all(
      projectList.map(
        async (project) =>
          [project.id, await window.disco.listSessions(project.id)] as const,
      ),
    );
    const nextSessionsByProject = new Map(projectSessions);
    setSessionsByProject(nextSessionsByProject);

    const firstProject = projectList[0];
    if (!firstProject) {
      setSelectedProjectId(undefined);
      setActiveSessionId(undefined);
      setMessages([]);
      return;
    }

    setSelectedProjectId(firstProject.id);
    setExpandedProjects(new Set([firstProject.id]));
    const firstSession = nextSessionsByProject.get(firstProject.id)?.[0];
    if (firstSession) {
      await selectSession(firstSession);
    } else {
      setActiveSessionId(undefined);
      setMessages([]);
    }
  }

  async function selectProject(selectedProjectId: string): Promise<void> {
    setSelectedProjectId(selectedProjectId);
    const projectSessions = await window.disco.listSessions(selectedProjectId);
    setSessionsByProject((current) => {
      const next = new Map(current);
      next.set(selectedProjectId, projectSessions);
      return next;
    });

    if (projectSessions[0]) {
      await selectSession(projectSessions[0]);
    } else {
      setActiveSessionId(undefined);
      setMessages([]);
    }
  }

  async function toggleProject(selectedProjectId: string): Promise<void> {
    const isExpanded = expandedProjects.has(selectedProjectId);
    setExpandedProjects((current) => {
      const next = new Set(current);
      if (isExpanded) {
        next.delete(selectedProjectId);
      } else {
        next.add(selectedProjectId);
      }
      return next;
    });
    setSelectedProjectId(selectedProjectId);

    if (isExpanded) {
      return;
    }
    const projectSessions = await window.disco.listSessions(selectedProjectId);
    setSessionsByProject((current) => {
      const next = new Map(current);
      next.set(selectedProjectId, projectSessions);
      return next;
    });
    if (projectSessions[0] && !activeSessionId) {
      await selectSession(projectSessions[0]);
    }
  }

  async function selectSession(session: SessionInfo): Promise<void> {
    setSelectedProjectId(session.projectId);
    setActiveSessionId(session.sessionId);
    setBackend(session.backend);
    setMessages(await window.disco.loadMessages(session.sessionId));
  }

  async function addProject(): Promise<ProjectInfo | undefined> {
    const selectedPath = await window.disco.chooseDirectory();
    if (!selectedPath) {
      return undefined;
    }

    const project = await window.disco.createProject(selectedPath);
    setProjects((current) => [
      project,
      ...current.filter((item) => item.id !== project.id),
    ]);
    setExpandedProjects((current) => new Set(current).add(project.id));
    await selectProject(project.id);
    return project;
  }

  async function addSession(
    selectedBackend: BackendKind = backend,
  ): Promise<SessionInfo | undefined> {
    const targetProjectId = selectedProjectId ?? (await addProject())?.id;
    if (!targetProjectId) {
      return undefined;
    }

    const session = await window.disco.createSession(
      targetProjectId,
      selectedBackend,
    );
    setSessionsByProject((current) => {
      const next = new Map(current);
      const currentSessions = next.get(targetProjectId) ?? [];
      next.set(targetProjectId, [session, ...currentSessions]);
      return next;
    });
    setExpandedProjects((current) => new Set(current).add(targetProjectId));
    await selectSession(session);
    return session;
  }

  async function addSessionForProject(
    selectedProjectId: string,
  ): Promise<void> {
    const session = await window.disco.createSession(
      selectedProjectId,
      backend,
    );
    setSessionsByProject((current) => {
      const next = new Map(current);
      const currentSessions = next.get(selectedProjectId) ?? [];
      next.set(selectedProjectId, [session, ...currentSessions]);
      return next;
    });
    setSelectedProjectId(selectedProjectId);
    setExpandedProjects((current) => new Set(current).add(selectedProjectId));
    await selectSession(session);
  }

  async function attachContext(withDirectories: boolean): Promise<void> {
    const paths = await window.disco.chooseFiles(withDirectories);
    if (paths.length === 0) {
      return;
    }
    const mention = paths.map((path) => `@${path}`).join(" ");
    setDraft((text) =>
      text.trim() ? `${text.replace(/\s+$/, "")} ${mention}` : mention,
    );
  }

  function handleAgentEvent(event: AgentEvent): void {
    if (event.sessionId !== activeSessionId) {
      return;
    }

    switch (event.type) {
      case "run-finished":
        setRunning(false);
        setPendingApproval(null);
        if (event.error) {
          appendAssistantText("text", `\n\n运行失败：${event.error}`);
        }
        break;
      case "approval-requested":
        setPendingApproval({
          approvalId: event.approvalId,
          toolName: event.toolName,
          title: event.title,
          input: event.input,
        });
        break;
      case "approval-resolved":
        setPendingApproval(null);
        break;
      case "text":
      case "reasoning":
        appendAssistantText(event.type, event.text);
        break;
      case "tool":
        setMessages((current) =>
          updateLatestAssistant(current, (assistantMessage) => {
            const toolCall = assistantMessage.toolCalls?.find(
              (item) => item.id === event.id,
            );
            if (toolCall) {
              toolCall.status = event.state;
              toolCall.output = event.output;
            } else {
              assistantMessage.toolCalls = [
                ...(assistantMessage.toolCalls ?? []),
                {
                  id: event.id,
                  name: event.title,
                  status: event.state,
                  output: event.output,
                },
              ];
            }
          }),
        );
        break;
    }
  }

  function appendAssistantText(
    field: "text" | "reasoning",
    text: string,
  ): void {
    setMessages((current) =>
      updateLatestAssistant(current, (assistantMessage) => {
        assistantMessage[field] = `${assistantMessage[field] ?? ""}${text}`;
      }),
    );
  }

  async function send(event: FormEvent): Promise<void> {
    event.preventDefault();
    if (running) {
      return;
    }

    const text = draft.trim();
    if (!text) {
      return;
    }
    const sessionId = activeSessionId ?? (await addSession())?.sessionId;
    if (!sessionId) {
      return;
    }

    setDraft("");
    setMessages((current) => [
      ...current,
      {
        id: crypto.randomUUID(),
        role: "user",
        text,
        createdAt: new Date().toISOString(),
      },
      createAssistantMessage(),
    ]);
    setRunning(true);
    await window.disco.prompt(sessionId, text, planMode ? "plan" : "agent");
  }

  let statusLabel = "准备就绪";
  if (running) {
    statusLabel = "正在处理";
  } else if (activeSession) {
    statusLabel = providerNames[activeSession.backend];
  }

  return (
    <main className="app-shell">
      <WorkspaceSidebar
        projects={projects}
        sessionsByProject={sessionsByProject}
        selectedProjectId={selectedProjectId}
        activeSessionId={activeSessionId}
        expandedProjects={expandedProjects}
        onAddProject={() => void addProject()}
        onAddSession={() => void addSession()}
        onToggleProject={(selectedProjectId) =>
          void toggleProject(selectedProjectId)
        }
        onAddSessionForProject={(selectedProjectId) =>
          void addSessionForProject(selectedProjectId)
        }
        onSelectSession={(session) => void selectSession(session)}
        onOpenSettings={onOpenSettings}
      />

      <section className="conversation">
        <header className="workspace-header">
          <div>
            <span className="crumb">{activeProject?.name ?? "工作区"}</span>
            <h1>{title}</h1>
          </div>
          <div className="header-actions">
            <span className={`status ${running ? "working" : ""}`}>
              <i />
              {statusLabel}
            </span>
          </div>
        </header>

        <ConversationTimeline
          activeSession={activeSession}
          messages={messages}
          pendingApproval={pendingApproval}
          providers={providers}
          onAddProject={() => void addProject()}
          onAddSession={(selectedBackend) => void addSession(selectedBackend)}
          onApprove={(approvalId, decision) =>
            void window.disco.approve(approvalId, decision)
          }
        />

        <PromptComposer
          activeSession={activeSession}
          activeSessionId={activeSessionId}
          backend={backend}
          draft={draft}
          planMode={planMode}
          providers={providers}
          running={running}
          onAttachContext={(withDirectories) =>
            void attachContext(withDirectories)
          }
          onBackendChange={setBackend}
          onDraftChange={setDraft}
          onPlanModeChange={setPlanMode}
          onSend={(event) => void send(event)}
          onStop={(sessionId) => void window.disco.cancel(sessionId)}
        />
      </section>
    </main>
  );
}
