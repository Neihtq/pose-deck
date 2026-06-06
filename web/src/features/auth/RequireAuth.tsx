/**
 * Route guard: gates protected routes behind an authenticated session.
 *
 * Use either as a layout route wrapping an <Outlet/>:
 *   <Route element={<RequireAuth />}>
 *     <Route path="/decks" element={<DecksPage />} />
 *   </Route>
 *
 * or wrapping explicit children:
 *   <RequireAuth><DecksPage /></RequireAuth>
 *
 * When unauthenticated it redirects to /login, preserving the attempted
 * location in router state so the login flow can send the user back.
 */
import * as React from "react";

import { Navigate, Outlet, useLocation } from "react-router-dom";

import { useAuth } from "./AuthContext";

export interface RequireAuthProps {
  /** Optional explicit children; falls back to <Outlet/> for layout routes. */
  children?: React.ReactNode;
  /** Where to send unauthenticated users. Defaults to "/login". */
  redirectTo?: string;
}

export function RequireAuth({
  children,
  redirectTo = "/login",
}: RequireAuthProps): React.JSX.Element {
  const { isAuthenticated, loading } = useAuth();
  const location = useLocation();

  // Avoid a redirect flash before the initial auth state has been read.
  if (loading) {
    return <></>;
  }

  if (!isAuthenticated) {
    return <Navigate to={redirectTo} replace state={{ from: location }} />;
  }

  return <>{children ?? <Outlet />}</>;
}

export default RequireAuth;
