/**
 * Component/hook tests for the ThemeProvider.
 *
 * No backend is involved. The OS color-scheme signal (window.matchMedia) and
 * localStorage are controlled per-test so we can exercise:
 *   - default "system" resolution and the `.dark` class side-effect,
 *   - explicit light / dark choices + persistence,
 *   - live OS preference changes while on "system",
 *   - reading a previously-persisted choice on mount,
 *   - the useTheme-outside-provider guard.
 */
import * as React from "react";

import { act, render, renderHook, screen } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { ThemeProvider, useTheme } from "../ThemeProvider";

const STORAGE_KEY = "pose-deck-theme";

/**
 * Installs a controllable matchMedia stub. `prefersDark` sets the initial
 * value; the returned `setSystemDark` fires registered change listeners so
 * tests can simulate the OS flipping to dark/light at runtime.
 */
function installMatchMedia(prefersDark: boolean) {
  const listeners = new Set<() => void>();
  let matches = prefersDark;

  window.matchMedia = ((query: string) =>
    ({
      get matches() {
        return matches;
      },
      media: query,
      onchange: null,
      addEventListener: (_: string, cb: () => void) => listeners.add(cb),
      removeEventListener: (_: string, cb: () => void) => listeners.delete(cb),
      addListener: (cb: () => void) => listeners.add(cb),
      removeListener: (cb: () => void) => listeners.delete(cb),
      dispatchEvent: () => false,
    }) as unknown as MediaQueryList) as typeof window.matchMedia;

  return {
    setSystemDark(next: boolean) {
      matches = next;
      for (const cb of listeners) cb();
    },
  };
}

function wrapper({ children }: { children: React.ReactNode }) {
  return <ThemeProvider>{children}</ThemeProvider>;
}

beforeEach(() => {
  window.localStorage.clear();
  document.documentElement.classList.remove("dark");
});

afterEach(() => {
  document.documentElement.classList.remove("dark");
});

describe("ThemeProvider / useTheme", () => {
  it("defaults to system and resolves to light when the OS prefers light", () => {
    installMatchMedia(false);
    const { result } = renderHook(() => useTheme(), { wrapper });

    expect(result.current.theme).toBe("system");
    expect(result.current.resolvedTheme).toBe("light");
    expect(document.documentElement.classList.contains("dark")).toBe(false);
  });

  it("resolves system to dark and applies the .dark class when the OS prefers dark", () => {
    installMatchMedia(true);
    const { result } = renderHook(() => useTheme(), { wrapper });

    expect(result.current.theme).toBe("system");
    expect(result.current.resolvedTheme).toBe("dark");
    expect(document.documentElement.classList.contains("dark")).toBe(true);
  });

  it("setTheme('dark') applies .dark, persists, and ignores the OS preference", () => {
    installMatchMedia(false); // OS prefers light
    const { result } = renderHook(() => useTheme(), { wrapper });

    act(() => result.current.setTheme("dark"));

    expect(result.current.theme).toBe("dark");
    expect(result.current.resolvedTheme).toBe("dark");
    expect(document.documentElement.classList.contains("dark")).toBe(true);
    expect(window.localStorage.getItem(STORAGE_KEY)).toBe("dark");
  });

  it("setTheme('light') removes .dark even when the OS prefers dark", () => {
    installMatchMedia(true); // OS prefers dark
    const { result } = renderHook(() => useTheme(), { wrapper });
    expect(document.documentElement.classList.contains("dark")).toBe(true);

    act(() => result.current.setTheme("light"));

    expect(result.current.resolvedTheme).toBe("light");
    expect(document.documentElement.classList.contains("dark")).toBe(false);
    expect(window.localStorage.getItem(STORAGE_KEY)).toBe("light");
  });

  it("follows live OS preference changes while on 'system'", () => {
    const media = installMatchMedia(false);
    const { result } = renderHook(() => useTheme(), { wrapper });
    expect(result.current.resolvedTheme).toBe("light");

    act(() => media.setSystemDark(true));
    expect(result.current.resolvedTheme).toBe("dark");
    expect(document.documentElement.classList.contains("dark")).toBe(true);

    act(() => media.setSystemDark(false));
    expect(result.current.resolvedTheme).toBe("light");
    expect(document.documentElement.classList.contains("dark")).toBe(false);
  });

  it("does NOT follow OS changes once an explicit theme is chosen", () => {
    const media = installMatchMedia(false);
    const { result } = renderHook(() => useTheme(), { wrapper });

    act(() => result.current.setTheme("light"));
    expect(result.current.resolvedTheme).toBe("light");

    // OS flips to dark — explicit "light" should be unaffected.
    act(() => media.setSystemDark(true));
    expect(result.current.resolvedTheme).toBe("light");
    expect(document.documentElement.classList.contains("dark")).toBe(false);
  });

  it("reads a previously-persisted choice on mount", () => {
    window.localStorage.setItem(STORAGE_KEY, "dark");
    installMatchMedia(false); // OS light, but stored choice is dark

    const { result } = renderHook(() => useTheme(), { wrapper });

    expect(result.current.theme).toBe("dark");
    expect(result.current.resolvedTheme).toBe("dark");
    expect(document.documentElement.classList.contains("dark")).toBe(true);
  });

  it("ignores a corrupt persisted value and falls back to system", () => {
    window.localStorage.setItem(STORAGE_KEY, "neon");
    installMatchMedia(true);

    const { result } = renderHook(() => useTheme(), { wrapper });

    expect(result.current.theme).toBe("system");
    expect(result.current.resolvedTheme).toBe("dark");
  });

  it("renders children inside the provider", () => {
    installMatchMedia(false);
    function Probe() {
      const { resolvedTheme } = useTheme();
      return <span>theme:{resolvedTheme}</span>;
    }
    render(
      <ThemeProvider>
        <Probe />
      </ThemeProvider>,
    );
    expect(screen.getByText("theme:light")).toBeInTheDocument();
  });

  it("useTheme throws when used outside a provider", () => {
    const spy = vi.spyOn(console, "error").mockImplementation(() => {});
    function Probe() {
      useTheme();
      return null;
    }
    expect(() => render(<Probe />)).toThrow(
      /useTheme must be used within a <ThemeProvider>/,
    );
    spy.mockRestore();
  });
});
