import type { BackendKind } from "../shared/types";

const disabledProvidersKey = "disco.disabledProviders";
export const providerPreferencesChangedEventName =
  "disco-provider-preferences-changed";

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
  window.dispatchEvent(new Event(providerPreferencesChangedEventName));
}

export function isProviderPreferencesEvent(event: Event): boolean {
  return (
    event.type === providerPreferencesChangedEventName ||
    (event.type === "storage" &&
      (event as StorageEvent).key === disabledProvidersKey)
  );
}
