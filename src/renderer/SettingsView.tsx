import { type JSX, useEffect, useState } from "react";
import type { AboutInfo, BackendKind, ProviderInfo } from "../shared/types";
import {
  loadDisabledProviders,
  saveDisabledProviders,
} from "./providerPreferences";

const providerIcons: Record<BackendKind, { glyph: string; tint: string }> = {
  codex: { glyph: "❋", tint: "#272725" },
  claude: { glyph: "✳", tint: "#d9774b" },
  opencode: { glyph: "◆", tint: "#6f6d69" },
};

const settingsSections = [
  { key: "providers", label: "服务商", icon: "☁" },
  { key: "general", label: "通用", icon: "⚙" },
] as const;

type SettingsSection = (typeof settingsSections)[number]["key"];

export function SettingsView({ onClose }: { onClose: () => void }): JSX.Element {
  const [providers, setProviders] = useState<ProviderInfo[]>([]);
  const [about, setAbout] = useState<AboutInfo>();
  const [activeSection, setActiveSection] =
    useState<SettingsSection>("providers");
  const [searchQuery, setSearchQuery] = useState("");
  const [disabledProviders, setDisabledProviders] = useState<BackendKind[]>(
    loadDisabledProviders,
  );
  const [openInstallGuide, setOpenInstallGuide] = useState<BackendKind>();
  const [copiedHint, setCopiedHint] = useState<string>();
  const [checkedAt, setCheckedAt] = useState<number>();

  useEffect(() => {
    void refreshProviders();
  }, []);

  async function refreshProviders(): Promise<void> {
    const [providerInfo, appInfo] = await Promise.all([
      window.disco.providers(),
      window.disco.about(),
    ]);
    setProviders(providerInfo);
    setAbout(appInfo);
    setCheckedAt(Date.now());
  }

  function toggleProvider(kind: BackendKind): void {
    const nextDisabledProviders = disabledProviders.includes(kind)
      ? disabledProviders.filter((item) => item !== kind)
      : [...disabledProviders, kind];
    saveDisabledProviders(nextDisabledProviders);
    setDisabledProviders(nextDisabledProviders);
  }

  function copyHint(hint: string): void {
    void navigator.clipboard
      ?.writeText(hint)
      .then(() => {
        setCopiedHint(hint);
        setTimeout(() => setCopiedHint(undefined), 1_500);
      })
      .catch(() => {});
  }

  const normalizedQuery = searchQuery.trim().toLowerCase();
  const visibleProviders = providers.filter(
    (provider) =>
      !normalizedQuery || provider.name.toLowerCase().includes(normalizedQuery),
  );
  const visibleSections = settingsSections.filter(
    (section) =>
      !normalizedQuery || section.label.toLowerCase().includes(normalizedQuery),
  );

  let checkedLabel: string | undefined;
  if (checkedAt !== undefined) {
    const minutesSinceCheck = Math.max(
      1,
      Math.round((Date.now() - checkedAt) / 60_000),
    );
    checkedLabel =
      Date.now() - checkedAt < 60_000
        ? "刚刚检查过"
        : `${minutesSinceCheck} 分钟前检查`;
  }

  return (
    <div className="settings standalone">
      <div className="settings-body">
        <nav className="settings-nav" aria-label="设置导航">
          <button className="settings-back" onClick={onClose}>
            ← 返回
          </button>
          <input
            className="settings-search"
            type="search"
            placeholder="搜索设置"
            value={searchQuery}
            onChange={(event) => setSearchQuery(event.target.value)}
          />
          {visibleSections.map((section) => (
            <button
              key={section.key}
              className={`nav-item${
                activeSection === section.key ? " active" : ""
              }`}
              onClick={() => setActiveSection(section.key)}
            >
              <span className="nav-icon" aria-hidden="true">
                {section.icon}
              </span>
              <span>{section.label}</span>
            </button>
          ))}
        </nav>

        {activeSection === "providers" ? (
          <div className="panel-card">
            <header className="panel-head">
              <div>
                <h3>编程智能体</h3>
                <p className="panel-sub">
                  Disco
                  调用安装在这台电脑上的智能体命令行工具。请先安装相应工具或完成登录，然后刷新。
                </p>
              </div>
              <div className="panel-refresh">
                <button
                  className="quiet"
                  onClick={() => void refreshProviders()}
                >
                  ⟳ 刷新
                </button>
                {checkedLabel && <small>{checkedLabel}</small>}
              </div>
            </header>
            <div className="agent-list">
              {visibleProviders.map((provider) => (
                <div className="agent-item" key={provider.kind}>
                  <div className="agent-row">
                    <span
                      className="agent-icon"
                      style={{ color: providerIcons[provider.kind].tint }}
                      aria-hidden="true"
                    >
                      {providerIcons[provider.kind].glyph}
                    </span>
                    <div className="agent-meta">
                      <strong>
                        {provider.name}
                        {disabledProviders.includes(provider.kind) && (
                          <em className="agent-off">已停用</em>
                        )}
                      </strong>
                      {provider.available ? (
                        <span className="agent-status">
                          <i className="dot ready" />
                          {provider.evidence && (
                            <code>{provider.evidence}</code>
                          )}
                        </span>
                      ) : (
                        <span className="agent-status">
                          <i className="dot missing" />
                          未检测到登录态或工具
                        </span>
                      )}
                    </div>
                    {provider.available ? (
                      <label
                        className="switch"
                        title={
                          disabledProviders.includes(provider.kind)
                            ? "启用该智能体"
                            : "停用该智能体"
                        }
                      >
                        <input
                          type="checkbox"
                          checked={!disabledProviders.includes(provider.kind)}
                          onChange={() => toggleProvider(provider.kind)}
                          aria-label={`启用 ${provider.name}`}
                        />
                        <span aria-hidden="true" />
                      </label>
                    ) : (
                      provider.hint && (
                        <button
                          type="button"
                          className="agent-fix-toggle"
                          onClick={() =>
                            setOpenInstallGuide(
                              openInstallGuide === provider.kind
                                ? undefined
                                : provider.kind,
                            )
                          }
                        >
                          安装指引 ›
                        </button>
                      )
                    )}
                  </div>
                  {!provider.available &&
                    openInstallGuide === provider.kind &&
                    provider.hint && (
                      <div className="agent-fix">
                        <span>在终端运行</span>
                        <code>{provider.hint}</code>
                        <button
                          type="button"
                          onClick={() =>
                            provider.hint && copyHint(provider.hint)
                          }
                        >
                          {copiedHint === provider.hint ? "已复制" : "复制"}
                        </button>
                      </div>
                    )}
                  {provider.models.length > 0 && (
                    <div className="model-list">
                      {provider.models.map((model) => (
                        <span className="model-tag" key={model.id}>
                          {model.name}
                        </span>
                      ))}
                    </div>
                  )}
                </div>
              ))}
              {visibleProviders.length === 0 && (
                <p className="panel-empty">
                  没有匹配「{searchQuery.trim()}」的设置项
                </p>
              )}
            </div>
          </div>
        ) : (
          <div className="panel-card">
            <header className="panel-head">
              <div>
                <h3>数据与应用</h3>
                <p className="panel-sub">
                  所有项目、会话与消息都保存在本机 SQLite 数据库中，不会上传。
                </p>
              </div>
            </header>
            <div className="data-card">
              <div>
                <span>会话记录</span>
                <code title={about?.dataPath}>{about?.dataPath}</code>
              </div>
              <div>
                <span>版本</span>
                <code>{about?.version}</code>
              </div>
            </div>
          </div>
        )}
      </div>
    </div>
  );
}
