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
  providerPreferencesChangedEventName,
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
          items: lastMessage.items?.map((item) => ({ ...item })),
        }
      : createAssistantMessage();
  update(assistantMessage);

  if (lastMessage?.role === "assistant") {
    return [...messages.slice(0, -1), assistantMessage];
  }
  return [...messages, assistantMessage];
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : "操作失败";
}

export function App(): JSX.Element {
  const [showSettings, setShowSettings] = useState(false);
  return (
    <>
      <div hidden={showSettings}>
        <Workspace onOpenSettings={() => setShowSettings(true)} />
      </div>
      {showSettings && <SettingsView onClose={() => setShowSettings(false)} />}
    </>
  );
}

function Workspace({
  onOpenSettings,
}: {
  onOpenSettings: () => void;
}): JSX.Element {
  const [projects, setProjects] = useState<ProjectInfo[]>([]);
  const [sessionsByProject, setSessionsByProject] = useState<
    Map<string, SessionInfo[]>
  >(() => new Map());
  const [providers, setProviders] = useState<ProviderInfo[]>([]);
  const [selectedProjectId, setSelectedProjectId] = useState<string>();
  const [activeSessionId, setActiveSessionId] = useState<string>();
  const [messages, setMessages] = useState<StoredMessage[]>([]);
  const [draft, setDraft] = useState("");
  const [runningSessionIds, setRunningSessionIds] = useState<Set<string>>(
    () => new Set(),
  );
  const [planMode, setPlanMode] = useState(false);
  const [backend, setBackend] = useState<BackendKind>("codex");
  const [pendingApprovals, setPendingApprovals] = useState<
    Map<string, PendingApproval>
  >(() => new Map());
  const [workspaceError, setWorkspaceError] = useState<string>();
  const [expandedProjects, setExpandedProjects] = useState<Set<string>>(
    () => new Set(),
  );
  const detectedProviders = useRef<ProviderInfo[]>([]);
  const activeSessionIdRef = useRef<string>();
  const backendRef = useRef(backend);
  const activeRunIdBySession = useRef<Map<string, string>>(new Map());
  const sessionSelectionVersion = useRef(0);

  activeSessionIdRef.current = activeSessionId;
  backendRef.current = backend;

  const selectedProjectSessions = selectedProjectId
    ? (sessionsByProject.get(selectedProjectId) ?? [])
    : [];
  const activeSession = selectedProjectSessions.find(
    (session) => session.sessionId === activeSessionId,
  );
  const activeProject = projects.find(
    (project) => project.id === selectedProjectId,
  );
  const running = activeSessionId
    ? runningSessionIds.has(activeSessionId)
    : false;
  const activePendingApprovals = activeSessionId
    ? [...pendingApprovals.values()].filter(
        (approval) => approval.sessionId === activeSessionId,
      )
    : [];
  const title =
    activeSession?.title ??
    (activeProject ? "新对话" : "开始使用 Disco");

  useEffect(() => {
    let isMounted = true;
    void refreshWorkspace().catch((error: unknown) => {
      if (isMounted) {
        setWorkspaceError(errorMessage(error));
      }
    });
    const handlePreferenceChange = (event: Event): void => {
      if (isProviderPreferencesEvent(event)) {
        applyProviderPreferences();
      }
    };
    window.addEventListener("storage", handlePreferenceChange);
    window.addEventListener(
      providerPreferencesChangedEventName,
      handlePreferenceChange,
    );
    return () => {
      isMounted = false;
      window.removeEventListener("storage", handlePreferenceChange);
      window.removeEventListener(
        providerPreferencesChangedEventName,
        handlePreferenceChange,
      );
    };
  }, []);

  useEffect(() => window.disco.onEvent(handleAgentEvent), []);

  function applyProviderPreferences(): void {
    const disabledProviders = loadDisabledProviders();
    const availableProviders = detectedProviders.current.filter(
      (provider) =>
        provider.available && !disabledProviders.includes(provider.kind),
    );
    setProviders(availableProviders);
    if (
      !activeSessionIdRef.current &&
      !availableProviders.some(
        (provider) => provider.kind === backendRef.current,
      )
    ) {
      setBackend(availableProviders[0]?.kind ?? "codex");
    }
  }

  async function refreshWorkspace(): Promise<void> {
    const selectionVersion = ++sessionSelectionVersion.current;
    setWorkspaceError(undefined);
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
    if (selectionVersion !== sessionSelectionVersion.current) {
      return;
    }
    const nextSessionsByProject = new Map(projectSessions);
    setSessionsByProject(nextSessionsByProject);

    const firstProject = projectList[0];
    if (!firstProject) {
      setSelectedProjectId(undefined);
      setActiveSessionId(undefined);
      setPlanMode(false);
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
      setPlanMode(false);
      setMessages([]);
    }
  }

  async function selectProject(projectId: string): Promise<void> {
    const selectionVersion = ++sessionSelectionVersion.current;
    try {
      setWorkspaceError(undefined);
      setSelectedProjectId(projectId);
      const projectSessions = await window.disco.listSessions(projectId);
      if (selectionVersion !== sessionSelectionVersion.current) {
        return;
      }
      setSessionsByProject((current) => {
        const next = new Map(current);
        next.set(projectId, projectSessions);
        return next;
      });

      if (projectSessions[0]) {
        await selectSession(projectSessions[0]);
      } else {
        setActiveSessionId(undefined);
        setPlanMode(false);
        setMessages([]);
      }
    } catch (error) {
      if (selectionVersion === sessionSelectionVersion.current) {
        setWorkspaceError(errorMessage(error));
      }
    }
  }

  async function toggleProject(projectId: string): Promise<void> {
    const isExpanded = expandedProjects.has(projectId);
    setExpandedProjects((current) => {
      const next = new Set(current);
      if (isExpanded) {
        next.delete(projectId);
      } else {
        next.add(projectId);
      }
      return next;
    });
    setSelectedProjectId(projectId);

    if (isExpanded) {
      return;
    }
    await selectProject(projectId);
  }

  async function selectSession(session: SessionInfo): Promise<void> {
    const selectionVersion = ++sessionSelectionVersion.current;
    try {
      setWorkspaceError(undefined);
      setSelectedProjectId(session.projectId);
      setActiveSessionId(session.sessionId);
      setBackend(session.backend);
      setPlanMode(false);
      setMessages([]);
      const loadedMessages = await window.disco.loadMessages(session.sessionId);
      if (selectionVersion !== sessionSelectionVersion.current) {
        return;
      }
      setMessages(loadedMessages);
    } catch (error) {
      if (selectionVersion === sessionSelectionVersion.current) {
        setWorkspaceError(errorMessage(error));
      }
    }
  }

  async function addProject(): Promise<ProjectInfo | undefined> {
    try {
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
    } catch (error) {
      setWorkspaceError(errorMessage(error));
      return undefined;
    }
  }

  async function addSession(
    selectedBackend: BackendKind = backend,
  ): Promise<SessionInfo | undefined> {
    try {
      const targetProjectId = selectedProjectId ?? (await addProject())?.id;
      if (!targetProjectId) {
        return undefined;
      }
      const usableBackend = providers.some(
        (provider) => provider.kind === selectedBackend,
      )
        ? selectedBackend
        : providers[0]?.kind;
      if (!usableBackend) {
        throw new Error("没有可用的 Agent，请先完成登录或安装配置");
      }

      const session = await window.disco.createSession(
        targetProjectId,
        usableBackend,
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
    } catch (error) {
      setWorkspaceError(errorMessage(error));
      return undefined;
    }
  }

  async function addSessionForProject(projectId: string): Promise<void> {
    try {
      const usableBackend = providers.some(
        (provider) => provider.kind === backend,
      )
        ? backend
        : providers[0]?.kind;
      if (!usableBackend) {
        throw new Error("没有可用的 Agent，请先完成登录或安装配置");
      }
      const session = await window.disco.createSession(
        projectId,
        usableBackend,
      );
      setSessionsByProject((current) => {
        const next = new Map(current);
        const currentSessions = next.get(projectId) ?? [];
        next.set(projectId, [session, ...currentSessions]);
        return next;
      });
      setSelectedProjectId(projectId);
      setExpandedProjects((current) => new Set(current).add(projectId));
      await selectSession(session);
    } catch (error) {
      setWorkspaceError(errorMessage(error));
    }
  }

  async function attachContext(withDirectories: boolean): Promise<void> {
    try {
      const paths = await window.disco.chooseFiles(withDirectories);
      if (paths.length === 0) {
        return;
      }
      const mention = paths.map((path) => `@${path}`).join(" ");
      setDraft((text) =>
        text.trim() ? `${text.replace(/\s+$/, "")} ${mention}` : mention,
      );
    } catch (error) {
      setWorkspaceError(errorMessage(error));
    }
  }

  function handleAgentEvent(event: AgentEvent): void {
    switch (event.type) {
      case "run-started":
        activeRunIdBySession.current.set(event.sessionId, event.runId);
        setRunningSessionIds((current) => {
          const next = new Set(current);
          next.add(event.sessionId);
          return next;
        });
        if (event.sessionId === activeSessionIdRef.current) {
          setMessages((current) =>
            current.at(-1)?.role === "assistant"
              ? current
              : [...current, createAssistantMessage()],
          );
        }
        return;
      case "run-finished": {
        const isCurrentRun =
          activeRunIdBySession.current.get(event.sessionId) === event.runId;
        if (isCurrentRun) {
          activeRunIdBySession.current.delete(event.sessionId);
          setRunningSessionIds((current) => {
            const next = new Set(current);
            next.delete(event.sessionId);
            return next;
          });
          setPendingApprovals((current) => {
            const next = new Map(current);
            for (const [approvalId, approval] of next) {
              if (
                approval.sessionId === event.sessionId &&
                approval.runId === event.runId
              ) {
                next.delete(approvalId);
              }
            }
            return next;
          });
        }
        if (event.sessionTitle) {
          setSessionsByProject((current) => {
            const next = new Map(current);
            for (const [projectId, sessions] of next) {
              const updatedSessions = sessions.map((session) =>
                session.sessionId === event.sessionId
                  ? { ...session, title: event.sessionTitle ?? session.title }
                  : session,
              );
              next.set(projectId, updatedSessions);
            }
            return next;
          });
        }
        if (
          event.sessionId === activeSessionIdRef.current &&
          isCurrentRun
        ) {
          setMessages((current) =>
            updateLatestAssistant(current, (assistantMessage) => {
              assistantMessage.status =
                event.status === "completed" ? undefined : event.status;
              assistantMessage.error = event.error;
            }),
          );
        }
        return;
      }
      case "approval-requested":
        setPendingApprovals((current) => {
          const next = new Map(current);
          next.set(event.approvalId, {
            sessionId: event.sessionId,
            runId: event.runId,
            approvalId: event.approvalId,
            toolName: event.toolName,
            title: event.title,
            input: event.input,
          });
          return next;
        });
        return;
      case "approval-resolved":
        setPendingApprovals((current) => {
          if (!current.has(event.approvalId)) {
            return current;
          }
          const next = new Map(current);
          next.delete(event.approvalId);
          return next;
        });
        return;
      default:
        break;
    }

    if (
      event.sessionId !== activeSessionIdRef.current ||
      activeRunIdBySession.current.get(event.sessionId) !== event.runId
    ) {
      return;
    }

    switch (event.type) {
      case "text":
      case "reasoning":
        appendAssistantText(event.type, event.text);
        break;
      case "item":
        setMessages((current) =>
          updateLatestAssistant(current, (assistantMessage) => {
            const itemIndex =
              assistantMessage.items?.findIndex(
                (item) => item.id === event.item.id,
              ) ?? -1;
            if (itemIndex === -1) {
              assistantMessage.items = [
                ...(assistantMessage.items ?? []),
                event.item,
              ];
            } else {
              assistantMessage.items = assistantMessage.items?.map(
                (item, index) => (index === itemIndex ? event.item : item),
              );
            }
          }),
        );
        break;
      case "tool":
        setMessages((current) =>
          updateLatestAssistant(current, (assistantMessage) => {
            const toolCall = assistantMessage.toolCalls?.find(
              (item) => item.id === event.id,
            );
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
              assistantMessage.toolCalls = [
                ...(assistantMessage.toolCalls ?? []),
                {
                  id: event.id,
                  name: event.title,
                  status: event.state,
                  input: event.input,
                  output: event.output,
                  error: event.error,
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

    setWorkspaceError(undefined);
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
    setRunningSessionIds((current) => {
      const next = new Set(current);
      next.add(sessionId);
      return next;
    });

    const activeProvider = providers.find(
      (provider) => provider.kind === activeSession?.backend,
    );
    const requestedMode =
      activeSession && planMode && activeProvider?.supportsPlan
        ? "plan"
        : "agent";
    try {
      await window.disco.prompt(sessionId, text, requestedMode);
    } catch (error) {
      const runWasStarted = activeRunIdBySession.current.has(sessionId);
      if (runWasStarted) {
        void window.disco.cancel(sessionId).catch(() => {});
      }
      setRunningSessionIds((current) => {
        const next = new Set(current);
        next.delete(sessionId);
        return next;
      });
      if (activeRunIdBySession.current.get(sessionId)) {
        activeRunIdBySession.current.delete(sessionId);
      }
      if (activeSessionIdRef.current === sessionId) {
        setMessages((current) =>
          updateLatestAssistant(current, (assistantMessage) => {
            assistantMessage.status = "failed";
            assistantMessage.error = errorMessage(error);
          }),
        );
      }
      setWorkspaceError(errorMessage(error));
    }
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
        onToggleProject={(projectId) => void toggleProject(projectId)}
        onAddSessionForProject={(projectId) =>
          void addSessionForProject(projectId)
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

        <div className="workspace-error-slot">
          {workspaceError && (
            <div className="workspace-error" role="alert">
              {workspaceError}
            </div>
          )}
        </div>

        <ConversationTimeline
          activeSession={activeSession}
          messages={messages}
          pendingApprovals={activePendingApprovals}
          providers={providers}
          onAddProject={() => void addProject()}
          onAddSession={(selectedBackend) => void addSession(selectedBackend)}
          onApprove={(approvalId, decision) => {
            void window.disco
              .approve(approvalId, decision)
              .catch((error: unknown) => setWorkspaceError(errorMessage(error)));
          }}
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
          onSend={(formEvent) => void send(formEvent)}
          onStop={(sessionId) => {
            void window.disco.cancel(sessionId).catch((error: unknown) =>
              setWorkspaceError(errorMessage(error)),
            );
          }}
        />
      </section>
    </main>
  );
}
