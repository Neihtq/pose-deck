import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { BrowserRouter } from "react-router-dom";

import App from "./App.tsx";
import { AuthProvider } from "@/features/auth/AuthContext";
import { ThemeProvider } from "@/components/theme/ThemeProvider";
import { registerServiceWorker } from "./registerSW";
import "./globals.css";

// Register the app-shell service worker (M3 STEP 6). No-op in dev (the PWA
// plugin is disabled there); precaches only the static shell in production.
registerServiceWorker();

const rootEl = document.getElementById("root");
if (!rootEl) {
  throw new Error("Root element #root not found");
}

createRoot(rootEl).render(
  <StrictMode>
    <ThemeProvider>
      <BrowserRouter>
        <AuthProvider>
          <App />
        </AuthProvider>
      </BrowserRouter>
    </ThemeProvider>
  </StrictMode>,
);
