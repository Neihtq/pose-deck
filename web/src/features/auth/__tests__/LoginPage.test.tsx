/**
 * Component tests for LoginPage (route: /login).
 *
 * Covers the page-level behaviour DESIGN/auth wiring promises: render of the
 * email + password form, a successful sign-in that navigates to the
 * redirect-from location, an invalid-credentials error surfaced inline, and the
 * in-flight state that disables the inputs/button while the request runs.
 *
 * `useAuth` is mocked with a controllable `signIn` so no real PocketBase SDK or
 * network is involved; `useNavigate` is spied via a partial mock of
 * react-router-dom so we can assert the post-login redirect target.
 */
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter, Route, Routes } from "react-router-dom";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { ThemeProvider } from "@/components/theme/ThemeProvider";
import { BACKEND_URL_STORAGE_KEY } from "@/lib/pocketbase";

const navigate = vi.fn();
vi.mock("react-router-dom", async () => {
  const actual =
    await vi.importActual<typeof import("react-router-dom")>(
      "react-router-dom",
    );
  return { ...actual, useNavigate: () => navigate };
});

const signIn = vi.fn();
vi.mock("@/features/auth/AuthContext", () => ({
  useAuth: () => ({ signIn }),
}));

import LoginPage from "@/features/auth/LoginPage";

/** A controllable deferred promise so we can hold sign-in "in flight". */
function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (reason?: unknown) => void;
  const promise = new Promise<T>((res, rej) => {
    resolve = res;
    reject = rej;
  });
  return { promise, resolve, reject };
}

function renderLogin(initialEntry: string | { pathname: string; state: unknown } = "/login") {
  return render(
    <ThemeProvider>
      <MemoryRouter initialEntries={[initialEntry]}>
        <Routes>
          <Route path="/login" element={<LoginPage />} />
        </Routes>
      </MemoryRouter>
    </ThemeProvider>,
  );
}

beforeEach(() => {
  navigate.mockReset();
  signIn.mockReset();
  // The login form persists a user-entered backend URL to localStorage; start
  // each test from a clean slate so prefill/disclosure state is deterministic.
  window.localStorage.clear();
});

describe("LoginPage", () => {
  it("renders the email + password form", () => {
    renderLogin();
    expect(
      screen.getByRole("heading", { name: "Pose Deck" }),
    ).toBeInTheDocument();
    expect(screen.getByLabelText("Email")).toBeInTheDocument();
    expect(screen.getByLabelText("Password")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Sign in" })).toBeInTheDocument();
  });

  it("signs in and navigates to '/' by default", async () => {
    signIn.mockResolvedValue(undefined);
    renderLogin();

    fireEvent.change(screen.getByLabelText("Email"), {
      target: { value: "owner@posedeck.test" },
    });
    fireEvent.change(screen.getByLabelText("Password"), {
      target: { value: "changeme123" },
    });
    fireEvent.click(screen.getByRole("button", { name: "Sign in" }));

    await waitFor(() =>
      expect(signIn).toHaveBeenCalledWith("owner@posedeck.test", "changeme123"),
    );
    await waitFor(() =>
      expect(navigate).toHaveBeenCalledWith("/", { replace: true }),
    );
  });

  it("redirects to the location the user was sent from", async () => {
    signIn.mockResolvedValue(undefined);
    renderLogin({
      pathname: "/login",
      state: { from: { pathname: "/decks/d1" } },
    });

    fireEvent.change(screen.getByLabelText("Email"), {
      target: { value: "a@b.test" },
    });
    fireEvent.change(screen.getByLabelText("Password"), {
      target: { value: "pw" },
    });
    fireEvent.click(screen.getByRole("button", { name: "Sign in" }));

    await waitFor(() =>
      expect(navigate).toHaveBeenCalledWith("/decks/d1", { replace: true }),
    );
  });

  it("shows an inline error and does not navigate on failure", async () => {
    signIn.mockRejectedValue(new Error("bad creds"));
    renderLogin();

    fireEvent.change(screen.getByLabelText("Email"), {
      target: { value: "owner@posedeck.test" },
    });
    fireEvent.change(screen.getByLabelText("Password"), {
      target: { value: "wrong" },
    });
    fireEvent.click(screen.getByRole("button", { name: "Sign in" }));

    const alert = await screen.findByRole("alert");
    expect(alert).toHaveTextContent(/invalid email or password/i);
    expect(navigate).not.toHaveBeenCalled();
    // The submit button is re-enabled so the user can retry.
    expect(screen.getByRole("button", { name: "Sign in" })).toBeEnabled();
  });

  it("persists an entered server URL on a successful sign-in", async () => {
    signIn.mockResolvedValue(undefined);
    renderLogin();

    // The server field is collapsed by default; open it.
    fireEvent.click(
      screen.getByRole("button", { name: /use a different server/i }),
    );
    fireEvent.change(screen.getByLabelText("Server URL"), {
      target: { value: "https://api.example.com" },
    });
    fireEvent.change(screen.getByLabelText("Email"), {
      target: { value: "a@b.test" },
    });
    fireEvent.change(screen.getByLabelText("Password"), {
      target: { value: "pw" },
    });
    fireEvent.click(screen.getByRole("button", { name: "Sign in" }));

    await waitFor(() =>
      expect(window.localStorage.getItem(BACKEND_URL_STORAGE_KEY)).toBe(
        "https://api.example.com",
      ),
    );
    await waitFor(() => expect(navigate).toHaveBeenCalled());
  });

  it("rejects a malformed server URL before attempting sign-in", async () => {
    signIn.mockResolvedValue(undefined);
    renderLogin();

    fireEvent.click(
      screen.getByRole("button", { name: /use a different server/i }),
    );
    fireEvent.change(screen.getByLabelText("Server URL"), {
      target: { value: "not a url" },
    });
    fireEvent.change(screen.getByLabelText("Email"), {
      target: { value: "a@b.test" },
    });
    fireEvent.change(screen.getByLabelText("Password"), {
      target: { value: "pw" },
    });
    fireEvent.click(screen.getByRole("button", { name: "Sign in" }));

    const alert = await screen.findByRole("alert");
    expect(alert).toHaveTextContent(/valid server url/i);
    expect(signIn).not.toHaveBeenCalled();
    expect(navigate).not.toHaveBeenCalled();
  });

  it("disables the form and shows a busy label while signing in", async () => {
    const pending = deferred<void>();
    signIn.mockReturnValue(pending.promise);
    renderLogin();

    fireEvent.change(screen.getByLabelText("Email"), {
      target: { value: "owner@posedeck.test" },
    });
    fireEvent.change(screen.getByLabelText("Password"), {
      target: { value: "changeme123" },
    });
    fireEvent.click(screen.getByRole("button", { name: "Sign in" }));

    const busyButton = await screen.findByRole("button", {
      name: "Signing in…",
    });
    expect(busyButton).toBeDisabled();
    expect(screen.getByLabelText("Email")).toBeDisabled();
    expect(screen.getByLabelText("Password")).toBeDisabled();

    pending.resolve();
    await waitFor(() => expect(navigate).toHaveBeenCalled());
  });
});
