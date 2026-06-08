/**
 * Component tests for the RequireAuth route guard.
 *
 * The auth state is supplied through a tiny stub of `./AuthContext` so the
 * guard can be exercised across its three states (loading, signed-out,
 * signed-in) without a real PocketBase session. Routing is driven by a
 * MemoryRouter so we can assert the redirect target and that the attempted
 * location is preserved in router state.
 */
import * as React from "react";

import { render, screen } from "@testing-library/react";
import {
  MemoryRouter,
  Route,
  Routes,
  useLocation,
} from "react-router-dom";
import { beforeEach, describe, expect, it, vi } from "vitest";

// --- Mock the auth context so each test can dictate the session state -------

interface FakeAuthState {
  isAuthenticated: boolean;
  loading: boolean;
}

const authState: FakeAuthState = { isAuthenticated: false, loading: false };

vi.mock("../AuthContext", () => ({
  useAuth: () => authState,
}));

import { RequireAuth } from "../RequireAuth";

/** Renders the protected page and shows the location it was reached at. */
function ProtectedPage(): React.JSX.Element {
  return <div>protected content</div>;
}

/** Login screen that echoes the `from` location stashed by the guard. */
function LoginPage(): React.JSX.Element {
  const location = useLocation();
  const from = (location.state as { from?: { pathname?: string } } | null)
    ?.from?.pathname;
  return <div>login screen{from ? ` from:${from}` : ""}</div>;
}

/** Renders the guard as a layout route at the given start path. */
function renderGuard(
  initialPath = "/decks",
  guardElement: React.ReactNode = <RequireAuth />,
) {
  return render(
    <MemoryRouter initialEntries={[initialPath]}>
      <Routes>
        <Route element={guardElement}>
          <Route path="/decks" element={<ProtectedPage />} />
        </Route>
        <Route path="/login" element={<LoginPage />} />
      </Routes>
    </MemoryRouter>,
  );
}

beforeEach(() => {
  authState.isAuthenticated = false;
  authState.loading = false;
});

describe("RequireAuth", () => {
  it("renders nothing while the initial auth state is loading", () => {
    authState.loading = true;
    const { container } = render(
      <MemoryRouter initialEntries={["/decks"]}>
        <Routes>
          <Route element={<RequireAuth />}>
            <Route path="/decks" element={<ProtectedPage />} />
          </Route>
          <Route path="/login" element={<LoginPage />} />
        </Routes>
      </MemoryRouter>,
    );

    // No redirect flash, and no protected content — an empty render.
    expect(screen.queryByText("protected content")).not.toBeInTheDocument();
    expect(screen.queryByText(/login screen/)).not.toBeInTheDocument();
    expect(container).toBeEmptyDOMElement();
  });

  it("redirects to /login when unauthenticated", () => {
    authState.isAuthenticated = false;
    renderGuard("/decks");

    expect(screen.queryByText("protected content")).not.toBeInTheDocument();
    expect(screen.getByText(/login screen/)).toBeInTheDocument();
  });

  it("preserves the attempted location in router state on redirect", () => {
    authState.isAuthenticated = false;
    renderGuard("/decks");

    // The login screen reads location.state.from and echoes its pathname.
    expect(screen.getByText("login screen from:/decks")).toBeInTheDocument();
  });

  it("renders the protected outlet when authenticated", () => {
    authState.isAuthenticated = true;
    renderGuard("/decks");

    expect(screen.getByText("protected content")).toBeInTheDocument();
    expect(screen.queryByText(/login screen/)).not.toBeInTheDocument();
  });

  it("renders explicit children (not <Outlet/>) when authenticated", () => {
    authState.isAuthenticated = true;
    render(
      <MemoryRouter initialEntries={["/decks"]}>
        <Routes>
          <Route
            path="/decks"
            element={
              <RequireAuth>
                <div>explicit child</div>
              </RequireAuth>
            }
          />
          <Route path="/login" element={<LoginPage />} />
        </Routes>
      </MemoryRouter>,
    );

    expect(screen.getByText("explicit child")).toBeInTheDocument();
  });

  it("honours a custom redirectTo target", () => {
    authState.isAuthenticated = false;
    render(
      <MemoryRouter initialEntries={["/decks"]}>
        <Routes>
          <Route element={<RequireAuth redirectTo="/welcome" />}>
            <Route path="/decks" element={<ProtectedPage />} />
          </Route>
          <Route path="/welcome" element={<div>welcome screen</div>} />
        </Routes>
      </MemoryRouter>,
    );

    expect(screen.getByText("welcome screen")).toBeInTheDocument();
    expect(screen.queryByText("protected content")).not.toBeInTheDocument();
  });
});
