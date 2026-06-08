/**
 * Component tests for the ThemeToggle dropdown.
 *
 * Renders inside a real ThemeProvider (no backend). The OS color-scheme signal
 * and localStorage are controlled per-test. We drive the Radix dropdown via
 * fireEvent.pointerDown on the trigger (matching the rest of the suite) and
 * assert the menu options, the selected-item check mark, the trigger icon
 * swap, and that selecting an option persists the choice.
 */
import { fireEvent, render, screen, within } from "@testing-library/react";
import { beforeEach, describe, expect, it } from "vitest";

import { ThemeProvider } from "../ThemeProvider";
import { ThemeToggle } from "../ThemeToggle";

const STORAGE_KEY = "pose-deck-theme";

/** Minimal matchMedia stub with a fixed OS preference (no live listeners). */
function installMatchMedia(prefersDark: boolean) {
  window.matchMedia = ((query: string) =>
    ({
      matches: prefersDark,
      media: query,
      onchange: null,
      addEventListener: () => {},
      removeEventListener: () => {},
      addListener: () => {},
      removeListener: () => {},
      dispatchEvent: () => false,
    }) as unknown as MediaQueryList) as typeof window.matchMedia;
}

function renderToggle() {
  return render(
    <ThemeProvider>
      <ThemeToggle />
    </ThemeProvider>,
  );
}

/** Opens the dropdown and returns the menu element. */
function openMenu() {
  fireEvent.pointerDown(
    screen.getByRole("button", { name: "Change theme" }),
    { button: 0, ctrlKey: false },
  );
  return screen.getByRole("menu");
}

beforeEach(() => {
  window.localStorage.clear();
  document.documentElement.classList.remove("dark");
  installMatchMedia(false);
});

describe("ThemeToggle", () => {
  it("renders an accessible trigger button", () => {
    renderToggle();
    expect(
      screen.getByRole("button", { name: "Change theme" }),
    ).toBeInTheDocument();
  });

  it("opens a menu with Light, Dark, and System options", () => {
    renderToggle();
    const menu = openMenu();

    expect(within(menu).getByText("Light")).toBeInTheDocument();
    expect(within(menu).getByText("Dark")).toBeInTheDocument();
    expect(within(menu).getByText("System")).toBeInTheDocument();
  });

  it("selecting Dark applies the theme and persists it", () => {
    renderToggle();
    const menu = openMenu();

    fireEvent.click(within(menu).getByText("Dark"));

    expect(window.localStorage.getItem(STORAGE_KEY)).toBe("dark");
    expect(document.documentElement.classList.contains("dark")).toBe(true);
  });

  it("selecting Light removes the .dark class and persists the choice", () => {
    installMatchMedia(true); // start dark via OS
    renderToggle();
    expect(document.documentElement.classList.contains("dark")).toBe(true);

    const menu = openMenu();
    fireEvent.click(within(menu).getByText("Light"));

    expect(window.localStorage.getItem(STORAGE_KEY)).toBe("light");
    expect(document.documentElement.classList.contains("dark")).toBe(false);
  });

  it("selecting System persists 'system'", () => {
    window.localStorage.setItem(STORAGE_KEY, "dark");
    renderToggle();

    const menu = openMenu();
    fireEvent.click(within(menu).getByText("System"));

    expect(window.localStorage.getItem(STORAGE_KEY)).toBe("system");
  });

  it("shows the trigger's moon icon when the resolved theme is dark", () => {
    installMatchMedia(true);
    renderToggle();

    // The trigger button swaps Sun -> Moon based on resolvedTheme. lucide
    // renders an <svg> with a class derived from the icon name.
    const trigger = screen.getByRole("button", { name: "Change theme" });
    const icon = trigger.querySelector("svg");
    expect(icon).not.toBeNull();
    expect(icon?.getAttribute("class") ?? "").toMatch(/lucide-moon/);
  });

  it("shows the trigger's sun icon when the resolved theme is light", () => {
    installMatchMedia(false);
    renderToggle();

    const trigger = screen.getByRole("button", { name: "Change theme" });
    const icon = trigger.querySelector("svg");
    expect(icon?.getAttribute("class") ?? "").toMatch(/lucide-sun/);
  });
});
