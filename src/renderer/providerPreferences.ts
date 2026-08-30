import type { BackendKind } from "../shared/types";

const disabledProvidersKey = "disco.disabledProviders";

export function loadDisabledProviders(): BackendKind[] {
  try {
    const parsed: unknown = JSON.parse(
      localStorage.getItem(disabledProvidersKey) ?? "[]",
    );
    if (!Array.isArray(parsed)) {
      return [];
    }
    return parsed.filter(
      (kind): kind is BackendKind =>
        kind === "codex" || kind === "claude" || kind === "opencode",
    );
  } catch {
    return [];
  }
}

export function saveDisabledProviders(disabledProviders: BackendKind[]): void {
  localStorage.setItem(disabledProvidersKey, JSON.stringify(disabledProviders));
}

export function isProviderPreferencesEvent(event: StorageEvent): boolean {
  return event.key === disabledProvidersKey;
}
