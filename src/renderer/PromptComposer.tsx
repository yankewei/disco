import {
  type FormEvent,
  type JSX,
  useEffect,
  useRef,
  useState,
} from "react";
import type {
  BackendKind,
  SandboxMode,
  ProviderInfo,
  ReasoningEffort,
  SessionInfo,
} from "../shared/types";
import { defaultSandboxMode } from "../shared/types";
import type { TranslationKey } from "../shared/i18n";
import { useI18n } from "./i18n";
import { providerIcons } from "./providerIcons";

const reasoningEffortKeys: Record<ReasoningEffort, TranslationKey> = {
  minimal: "minimal",
  low: "low",
  medium: "medium",
  high: "high",
  xhigh: "veryHigh",
  max: "maximum",
  ultra: "ultra",
  persistent: "persistent",
};

const sandboxModeKeys: Record<SandboxMode, TranslationKey> = {
  "read-only": "permissionReadOnly",
  "workspace-write": "permissionWorkspaceWrite",
  "danger-full-access": "permissionFullAccess",
};

interface PromptComposerProps {
  activeSession?: SessionInfo;
  activeSessionId?: string;
  backend: BackendKind;
  draft: string;
  hasProject: boolean;
  modelId?: string;
  reasoningEffort?: ReasoningEffort;
  sandboxMode?: SandboxMode;
  planMode: boolean;
  providers: ProviderInfo[];
  running: boolean;
  onAttachContext: (withDirectories: boolean) => void;
  onSelectionChange: (
    backend: BackendKind,
    modelId?: string,
    reasoningEffort?: ReasoningEffort,
    sandboxMode?: SandboxMode,
  ) => void;
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
  hasProject,
  modelId,
  reasoningEffort,
  sandboxMode,
  planMode,
  providers,
  running,
  onAttachContext,
  onSelectionChange,
  onDraftChange,
  onPlanModeChange,
  onSend,
  onStop,
}: PromptComposerProps): JSX.Element {
  const { t } = useI18n();
  const selectedProvider = providers.find(
    (provider) => provider.kind === backend,
  );
  const selectedModelId = modelId ?? selectedProvider?.models[0]?.id;
  const selectedModel = selectedProvider?.models.find(
    (model) => model.id === selectedModelId,
  );
  const reasoningEfforts = selectedModel?.reasoningEfforts ?? [];
  const selectedSandboxMode = sandboxMode ?? defaultSandboxMode;
  const [selectorOpen, setSelectorOpen] = useState(false);
  const [menuBackend, setMenuBackend] = useState(backend);
  const selectorRef = useRef<HTMLDivElement>(null);
  const menuProvider =
    providers.find((provider) => provider.kind === menuBackend) ??
    selectedProvider ??
    providers[0];

  useEffect(() => {
    if (!selectorOpen) {
      return;
    }
    const closeOnOutsidePointer = (event: PointerEvent): void => {
      if (
        selectorRef.current &&
        !selectorRef.current.contains(event.target as Node)
      ) {
        setSelectorOpen(false);
      }
    };
    const closeOnEscape = (event: KeyboardEvent): void => {
      if (event.key === "Escape") {
        setSelectorOpen(false);
      }
    };
    document.addEventListener("pointerdown", closeOnOutsidePointer);
    document.addEventListener("keydown", closeOnEscape);
    return () => {
      document.removeEventListener("pointerdown", closeOnOutsidePointer);
      document.removeEventListener("keydown", closeOnEscape);
    };
  }, [selectorOpen]);

  useEffect(() => {
    if (selectorOpen) {
      setMenuBackend(backend);
    }
  }, [backend, selectorOpen]);

  const supportsPlan = selectedProvider?.supportsPlan;
  let selectionTitle = t("selectAgentModel");
  if (running) {
    selectionTitle = t("switchAfterRun");
  }
  if (activeSession) {
    selectionTitle = t("switchStartsConversation");
  }

  return (
    <form className="composer" onSubmit={onSend}>
      <label className="composer-label" htmlFor="prompt">
        {t("sendToAgent")}
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
          activeSession || hasProject
            ? t("promptWithContext")
            : t("promptWithoutProject")
        }
        disabled={running}
        rows={3}
      />
      <div>
        <button
          type="button"
          className="attach"
          aria-label={t("addContext")}
          title={t("addFilesAsContext")}
          onClick={() => onAttachContext(true)}
        >
          +
        </button>
        <button
          type="button"
          className="context-action"
          aria-label={t("referenceFile")}
          title={t("referenceFile")}
          onClick={() => onAttachContext(false)}
        >
          @
        </button>
        <div className="agent-model-control" ref={selectorRef}>
          <button
            type="button"
            className="agent-model-trigger"
            aria-label={t("selectAgentModel")}
            aria-expanded={selectorOpen}
            aria-haspopup="dialog"
            disabled={running || providers.length === 0}
            title={selectionTitle}
            onClick={() => {
              setMenuBackend(backend);
              setSelectorOpen((open) => !open);
            }}
          >
            {selectedProvider && (
              <span
                className="agent-model-trigger-icon"
                style={{ color: providerIcons[selectedProvider.kind].tint }}
                aria-hidden="true"
              >
                {providerIcons[selectedProvider.kind].glyph}
              </span>
            )}
            <span className="agent-model-trigger-text">
              {selectedModel?.name ?? t("defaultModel")}
            </span>
            <span
              className={`agent-model-trigger-caret${
                selectorOpen ? " open" : ""
              }`}
              aria-hidden="true"
            />
          </button>
          {selectorOpen && menuProvider && (
            <div
              className="agent-model-picker"
              role="dialog"
              aria-label={t("selectAgentModel")}
            >
              <div
                className="agent-model-agents"
                role="tablist"
                aria-label={t("agentList")}
              >
                <span className="agent-model-column-label">Agent</span>
                {providers.map((provider) => (
                  <button
                    key={provider.kind}
                    type="button"
                    className={`agent-model-agent${
                      provider.kind === menuProvider.kind ? " active" : ""
                    }`}
                    role="tab"
                    aria-selected={provider.kind === menuProvider.kind}
                    onClick={() => {
                      setMenuBackend(provider.kind);
                      if (provider.models.length === 0) {
                        onSelectionChange(provider.kind, undefined);
                        setSelectorOpen(false);
                      }
                    }}
                  >
                    <span className="agent-model-agent-copy">
                      <strong>{provider.name}</strong>
                      <small>
                        {provider.models.length > 0
                          ? t("modelCount", { count: provider.models.length })
                          : t("defaultModel")}
                      </small>
                    </span>
                  </button>
                ))}
              </div>
              <div className="agent-model-options">
                <div className="agent-model-options-head">
                  <strong>{menuProvider.name}</strong>
                  <span>{t("availableModels")}</span>
                </div>
                <div
                  role="listbox"
                  aria-label={`${menuProvider.name} ${t("availableModels")}`}
                >
                  {menuProvider.models.length > 0 ? (
                    menuProvider.models.map((model) => (
                      <button
                        key={model.id}
                        type="button"
                        className={`agent-model-option${
                          menuProvider.kind === backend &&
                          model.id === selectedModelId
                            ? " active"
                            : ""
                        }`}
                        role="option"
                        aria-selected={
                          menuProvider.kind === backend &&
                          model.id === selectedModelId
                        }
                        onClick={() => {
                          onSelectionChange(menuProvider.kind, model.id);
                          setSelectorOpen(false);
                        }}
                      >
                        <span>{model.name}</span>
                      </button>
                    ))
                  ) : (
                    <button
                      type="button"
                      className="agent-model-option active"
                      role="option"
                      aria-selected={menuProvider.kind === backend}
                      onClick={() => {
                        onSelectionChange(menuProvider.kind, undefined);
                        setSelectorOpen(false);
                      }}
                    >
                      <span>{t("useDefaultModel")}</span>
                    </button>
                  )}
                </div>
              </div>
            </div>
          )}
        </div>
        <label className="reasoning-control">
          <svg
            className="reasoning-icon"
            viewBox="0 0 24 24"
            aria-hidden="true"
          >
            <path d="M9.5 4.5A3 3 0 0 0 6 7.3a3.5 3.5 0 0 0-1.5 6.4A3 3 0 0 0 7 19.5h2.5V4.5Z" />
            <path d="M14.5 4.5A3 3 0 0 1 18 7.3a3.5 3.5 0 0 1 1.5 6.4A3 3 0 0 1 17 19.5h-2.5V4.5Z" />
            <path d="M9.5 8.5h1v3h-1m4-3h-1v3h1m-4 3h1v2m4-2h-1v2M12 4.5v15" />
          </svg>
          <select
            className="reasoning-select"
            aria-label={t("reasoningDepth")}
            value={reasoningEffort ?? ""}
            disabled={running || reasoningEfforts.length === 0}
            onChange={(event) => {
              const value = event.target.value;
              onSelectionChange(
                backend,
                selectedModelId,
                value ? (value as ReasoningEffort) : undefined,
              );
            }}
          >
            <option value="">
              {reasoningEfforts.length > 0 ? t("default") : t("unsupported")}
            </option>
            {reasoningEfforts.map((effort) => (
              <option key={effort} value={effort}>
                {t(reasoningEffortKeys[effort])}
              </option>
            ))}
          </select>
        </label>
        <label className="permission-control">
          <svg
            className="permission-icon"
            viewBox="0 0 24 24"
            aria-hidden="true"
          >
            <path d="M12 3.5 19 6v5.3c0 4.3-2.8 7.6-7 9.2-4.2-1.6-7-4.9-7-9.2V6l7-2.5Z" />
            <path d="m9.2 12 1.8 1.8 3.8-4" />
          </svg>
          <select
            className="permission-select"
            aria-label={t("permissions")}
            title={
              backend === "codex"
                ? `${t("permissions")}: ${t(
                    sandboxModeKeys[selectedSandboxMode],
                  )} · ${t("approvalOnRequest")}`
                : t("permissionCodexOnly")
            }
            value={selectedSandboxMode}
            disabled={running || backend !== "codex"}
            onChange={(event) =>
              onSelectionChange(
                backend,
                selectedModelId,
                reasoningEffort,
                event.target.value as SandboxMode,
              )
            }
          >
            <option value="read-only">{t("permissionReadOnly")}</option>
            <option value="workspace-write">
              {t("permissionWorkspaceWrite")}
            </option>
            <option value="danger-full-access">
              {t("permissionFullAccess")}
            </option>
          </select>
        </label>
        <label className="plan-toggle">
          <input
            type="checkbox"
            checked={planMode}
            onChange={(event) => onPlanModeChange(event.target.checked)}
            disabled={!activeSession || !supportsPlan}
          />
          <span>{t("planMode")}</span>
        </label>
        <span className="send-hint">
          {activeSession || hasProject
            ? t("sendHint")
            : t("sendAfterChoosingProject")}
        </span>
        {running ? (
          <button
            type="button"
            className="quiet"
            onClick={() => activeSessionId && onStop(activeSessionId)}
          >
            {t("stop")}
          </button>
        ) : (
          <button type="submit" className="send" aria-label={t("send")}>
            ↑
          </button>
        )}
      </div>
    </form>
  );
}
