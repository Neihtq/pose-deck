/**
 * Sign-in page for Pose Deck (route: /login).
 *
 * Centered email + password form matching the App.tsx shell aesthetic
 * (max-w-md, Input + Button). Calls useAuth().signIn; on success navigates
 * to the page the user came from (router redirect state) or "/". Errors are
 * shown inline and the submit button is disabled while the request is in
 * flight.
 */
import * as React from "react";

import { useLocation, useNavigate } from "react-router-dom";

import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { ThemeToggle } from "@/components/theme/ThemeToggle";
import { useAuth } from "@/features/auth/AuthContext";
import {
  readStoredBackendUrl,
  resolveApiBaseUrl,
  setStoredBackendUrl,
} from "@/lib/pocketbase";

/** Shape of the location state set by RequireAuth on redirect. */
interface FromLocationState {
  from?: { pathname?: string };
}

export default function LoginPage(): React.JSX.Element {
  const { signIn } = useAuth();
  const navigate = useNavigate();
  const location = useLocation();

  const [email, setEmail] = React.useState("");
  const [password, setPassword] = React.useState("");
  // Prefill with the live resolved URL so the field always shows where we'd
  // connect (stored override → env → default), not an empty box.
  const [backendUrl, setBackendUrl] = React.useState(() => resolveApiBaseUrl());
  // Expand the server section by default only if the user has already set a
  // custom backend, so first-time/local users see a clean form.
  const [serverOpen, setServerOpen] = React.useState(
    () => readStoredBackendUrl() !== null,
  );
  const [error, setError] = React.useState<string | null>(null);
  const [submitting, setSubmitting] = React.useState(false);

  const redirectTo =
    (location.state as FromLocationState | null)?.from?.pathname ?? "/";

  const handleSubmit = async (
    event: React.FormEvent<HTMLFormElement>,
  ): Promise<void> => {
    event.preventDefault();
    setError(null);

    // Point the client at the entered server before authenticating, so a wrong
    // URL surfaces as a sign-in failure here rather than silently hitting the
    // old backend. Only touch the stored override if the user actually engaged
    // the server field — otherwise the prefilled env/default URL would get
    // baked into localStorage and shadow a later env change. An empty field
    // clears the override (falls back to env).
    if (serverOpen) {
      const trimmedUrl = backendUrl.trim();
      if (trimmedUrl !== "") {
        try {
          // Reject a malformed URL up front with a clear message instead of a
          // confusing auth error.
          new URL(trimmedUrl);
        } catch {
          setError("Enter a valid server URL, e.g. https://api.example.com");
          return;
        }
      }
      setStoredBackendUrl(trimmedUrl);
    }

    setSubmitting(true);
    try {
      await signIn(email, password);
      navigate(redirectTo, { replace: true });
    } catch {
      setError("Invalid email or password. Please try again.");
      setSubmitting(false);
    }
  };

  return (
    <main className="relative mx-auto flex min-h-screen max-w-md flex-col items-center justify-center gap-6 p-8">
      {/* Theme switch is reachable pre-auth too, so the login screen honors a
          dark-mode preference instead of flashing light. */}
      <div className="absolute right-4 top-4">
        <ThemeToggle />
      </div>

      <div className="text-center">
        <h1 className="text-2xl font-semibold tracking-tight">Pose Deck</h1>
        <p className="text-sm text-muted-foreground">
          Sign in to your account
        </p>
      </div>

      <form className="flex w-full flex-col gap-4" onSubmit={handleSubmit}>
        <div className="flex flex-col gap-1.5">
          <Label htmlFor="email">Email</Label>
          <Input
            id="email"
            type="email"
            autoComplete="email"
            placeholder="you@example.com"
            value={email}
            onChange={(e) => setEmail(e.target.value)}
            disabled={submitting}
            required
            autoFocus
          />
        </div>

        <div className="flex flex-col gap-1.5">
          <Label htmlFor="password">Password</Label>
          <Input
            id="password"
            type="password"
            autoComplete="current-password"
            placeholder="••••••••"
            value={password}
            onChange={(e) => setPassword(e.target.value)}
            disabled={submitting}
            required
          />
        </div>

        <div className="flex flex-col gap-1.5">
          {serverOpen ? (
            <>
              <Label htmlFor="backend-url">Server URL</Label>
              {/* type="text" (not "url") so our explicit validation below is
                  the single, friendly gate — a "url" input's native constraint
                  validation silently blocks form submit before our handler can
                  show a helpful message. */}
              <Input
                id="backend-url"
                type="text"
                inputMode="url"
                autoComplete="url"
                autoCapitalize="none"
                spellCheck={false}
                placeholder="https://api.example.com"
                value={backendUrl}
                onChange={(e) => setBackendUrl(e.target.value)}
                disabled={submitting}
              />
              <p className="text-xs text-muted-foreground">
                The Pose Deck backend to connect to. Leave the default unless
                you self-host.
              </p>
            </>
          ) : (
            <button
              type="button"
              className="self-start text-xs text-muted-foreground underline-offset-2 hover:underline"
              onClick={() => setServerOpen(true)}
            >
              Use a different server
            </button>
          )}
        </div>

        {error !== null && (
          <p role="alert" className="text-sm text-destructive">
            {error}
          </p>
        )}

        <Button type="submit" className="w-full" disabled={submitting}>
          {submitting ? "Signing in…" : "Sign in"}
        </Button>
      </form>
    </main>
  );
}
