import { type JSX, useEffect, useState } from "react";
import type { AboutInfo, BackendKind, ProviderInfo } from "../shared/types";
import {
  loadDisabledProviders,
  saveDisabledProviders,
} from "./providerPreferences";
import { providerIcons } from "./providerIcons";
import { useI18n } from "./i18n";

const settingsSections = [
  { key: "providers", labelKey: "settingsProviders", icon: "☁" },
  { key: "general", labelKey: "settingsGeneral", icon: "⚙" },
] as const;

type SettingsSection = (typeof settingsSections)[number]["key"];

export function SettingsView({ onClose }: { onClose: () => void }): JSX.Element {
  const { locale, setLocale, t } = useI18n();
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
  }, [locale]);

  async function refreshProviders(): Promise<void> {
    const [providerInfo, appInfo] = await Promise.all([
      window.disco.providers(locale),
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
      !normalizedQuery ||
      t(section.labelKey).toLowerCase().includes(normalizedQuery),
  );

  let checkedLabel: string | undefined;
  if (checkedAt !== undefined) {
    const minutesSinceCheck = Math.max(
      1,
      Math.round((Date.now() - checkedAt) / 60_000),
    );
    checkedLabel =
      Date.now() - checkedAt < 60_000
        ? t("justChecked")
        : t("minutesAgo", { minutes: minutesSinceCheck });
  }

  return (
    <div className="settings standalone">
      <div className="settings-body">
        <nav className="settings-nav" aria-label={t("settingsNavigation")}>
          <button className="settings-back" onClick={onClose}>
            ← {t("back")}
          </button>
          <input
            className="settings-search"
            type="search"
            placeholder={t("searchSettings")}
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
              <span>{t(section.labelKey)}</span>
            </button>
          ))}
        </nav>

        {activeSection === "providers" ? (
          <div className="panel-card">
            <header className="panel-head">
              <div>
                <h3>{t("codingAgents")}</h3>
                <p className="panel-sub">{t("providersDescription")}</p>
              </div>
              <div className="panel-refresh">
                <button
                  className="quiet"
                  onClick={() => void refreshProviders()}
                >
                  ⟳ {t("refresh")}
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
                          <em className="agent-off">{t("disabled")}</em>
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
                          {t("providerUnavailable")}
                        </span>
                      )}
                    </div>
                    {provider.available ? (
                      <label
                        className="switch"
                        title={
                          disabledProviders.includes(provider.kind)
                            ? t("enableAgent")
                            : t("disableAgent")
                        }
                      >
                        <input
                          type="checkbox"
                          checked={!disabledProviders.includes(provider.kind)}
                          onChange={() => toggleProvider(provider.kind)}
                          aria-label={t("enableProvider", {
                            provider: provider.name,
                          })}
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
                          {t("installGuide")}
                        </button>
                      )
                    )}
                  </div>
                  {!provider.available &&
                    openInstallGuide === provider.kind &&
                    provider.hint && (
                      <div className="agent-fix">
                        <span>{t("runInTerminal")}</span>
                        <code>{provider.hint}</code>
                        <button
                          type="button"
                          onClick={() =>
                            provider.hint && copyHint(provider.hint)
                          }
                        >
                          {copiedHint === provider.hint
                            ? t("copied")
                            : t("copy")}
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
                  {t("noMatchingSettings", { query: searchQuery.trim() })}
                </p>
              )}
            </div>
          </div>
        ) : (
          <div className="panel-card">
            <header className="panel-head">
              <div>
                <h3>{t("dataAndApp")}</h3>
                <p className="panel-sub">{t("dataAndAppDescription")}</p>
              </div>
            </header>
            <div className="language-setting">
              <div>
                <strong>{t("language")}</strong>
                <span>{t("languageDescription")}</span>
              </div>
              <select
                value={locale}
                aria-label={t("language")}
                onChange={(event) =>
                  setLocale(event.target.value as typeof locale)
                }
              >
                <option value="zh-CN">{t("chinese")}</option>
                <option value="en-US">{t("english")}</option>
              </select>
            </div>
            <div className="data-card">
              <div>
                <span>{t("sessionRecords")}</span>
                <code title={about?.dataPath}>{about?.dataPath}</code>
              </div>
              <div>
                <span>{t("version")}</span>
                <code>{about?.version}</code>
              </div>
            </div>
          </div>
        )}
      </div>
    </div>
  );
}
