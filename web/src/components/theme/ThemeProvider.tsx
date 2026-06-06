/**
 * Theme provider — light / dark / system, persisted to localStorage.
 *
 * Toggles the `.dark` class on <html> (Tailwind `darkMode: ["class"]`). The
 * "system" choice follows the OS preference and updates live when it changes.
 * All UI uses semantic tokens (bg-background, text-foreground, …) defined for
 * both themes in globals.css, so components adapt automatically.
 */
import * as React from "react";

export type Theme = "light" | "dark" | "system";

interface ThemeContextValue {
  /** The user's chosen setting (may be "system"). */
  theme: Theme;
  /** The actually-applied theme after resolving "system". */
  resolvedTheme: "light" | "dark";
  setTheme: (theme: Theme) => void;
}

const STORAGE_KEY = "pose-deck-theme";

const ThemeContext = React.createContext<ThemeContextValue | null>(null);

/** Read the persisted theme, defaulting to "system". */
function readStoredTheme(): Theme {
  if (typeof window === "undefined") {
    return "system";
  }
  const stored = window.localStorage.getItem(STORAGE_KEY);
  return stored === "light" || stored === "dark" || stored === "system"
    ? stored
    : "system";
}

/** Does the OS currently prefer dark? */
function systemPrefersDark(): boolean {
  return (
    typeof window !== "undefined" &&
    window.matchMedia("(prefers-color-scheme: dark)").matches
  );
}

/** Apply (or remove) the `.dark` class on the document root. */
function applyThemeClass(resolved: "light" | "dark"): void {
  const root = document.documentElement;
  root.classList.toggle("dark", resolved === "dark");
}

export function ThemeProvider({
  children,
}: {
  children: React.ReactNode;
}): React.JSX.Element {
  const [theme, setThemeState] = React.useState<Theme>(readStoredTheme);
  const [resolvedTheme, setResolvedTheme] = React.useState<"light" | "dark">(
    () => (readStoredTheme() === "dark" ? "dark" : "light"),
  );

  // Recompute + apply whenever the chosen theme changes, and keep "system" in
  // sync with live OS preference changes.
  React.useEffect(() => {
    const resolve = (): "light" | "dark" =>
      theme === "system" ? (systemPrefersDark() ? "dark" : "light") : theme;

    const next = resolve();
    setResolvedTheme(next);
    applyThemeClass(next);

    if (theme !== "system") {
      return;
    }
    const media = window.matchMedia("(prefers-color-scheme: dark)");
    const onChange = (): void => {
      const r = resolve();
      setResolvedTheme(r);
      applyThemeClass(r);
    };
    media.addEventListener("change", onChange);
    return () => media.removeEventListener("change", onChange);
  }, [theme]);

  const setTheme = React.useCallback((next: Theme): void => {
    window.localStorage.setItem(STORAGE_KEY, next);
    setThemeState(next);
  }, []);

  const value = React.useMemo<ThemeContextValue>(
    () => ({ theme, resolvedTheme, setTheme }),
    [theme, resolvedTheme, setTheme],
  );

  return (
    <ThemeContext.Provider value={value}>{children}</ThemeContext.Provider>
  );
}

/** Access the theme context. Throws if used outside a {@link ThemeProvider}. */
export function useTheme(): ThemeContextValue {
  const ctx = React.useContext(ThemeContext);
  if (ctx === null) {
    throw new Error("useTheme must be used within a <ThemeProvider>");
  }
  return ctx;
}
