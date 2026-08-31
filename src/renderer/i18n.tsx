import {
  createContext,
  type JSX,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useState,
} from "react";
import type { Locale } from "../shared/types";
import {
  localizeSessionTitle,
  translate,
  type TranslationKey,
} from "../shared/i18n";

export const languageStorageKey = "disco.locale";

interface I18nContextValue {
  locale: Locale;
  setLocale: (locale: Locale) => void;
  t: (
    key: TranslationKey,
    values?: Record<string, string | number>,
  ) => string;
}

const I18nContext = createContext<I18nContextValue | null>(null);

function readLocale(): Locale {
  try {
    return localStorage.getItem(languageStorageKey) === "en-US"
      ? "en-US"
      : "zh-CN";
  } catch {
    return "zh-CN";
  }
}

export function I18nProvider({ children }: { children: JSX.Element }): JSX.Element {
  const [locale, setLocale] = useState<Locale>(readLocale);

  useEffect(() => {
    document.documentElement.lang = locale;
    try {
      localStorage.setItem(languageStorageKey, locale);
    } catch {
      // The UI can still switch language when storage is unavailable.
    }
  }, [locale]);

  useEffect(() => {
    const handleStorage = (event: StorageEvent): void => {
      if (event.key !== languageStorageKey) {
        return;
      }
      setLocale(event.newValue === "en-US" ? "en-US" : "zh-CN");
    };
    window.addEventListener("storage", handleStorage);
    return () => window.removeEventListener("storage", handleStorage);
  }, []);

  const t = useCallback(
    (key: TranslationKey, values?: Record<string, string | number>) =>
      translate(locale, key, values),
    [locale],
  );
  const value = useMemo(
    () => ({ locale, setLocale, t }),
    [locale, t],
  );

  return <I18nContext.Provider value={value}>{children}</I18nContext.Provider>;
}

export function useI18n(): I18nContextValue {
  const context = useContext(I18nContext);
  if (!context) {
    throw new Error("useI18n must be used within I18nProvider");
  }
  return context;
}

export { localizeSessionTitle };
