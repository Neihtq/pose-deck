import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import { VitePWA } from "vite-plugin-pwa";
import path from "node:path";

// https://vite.dev/config/
export default defineConfig({
  plugins: [
    react(),
    // M3 STEP 6 service worker. `injectManifest` so we ship our own SW
    // (`src/sw.ts`) that precaches ONLY the static app shell and is NetworkOnly
    // for all API/auth/file/cross-origin requests (PocketBase is cross-origin).
    // Offline images come from the explicit Dexie pin, not the SW. Disabled in
    // dev so HMR / the dev server are unaffected.
    VitePWA({
      strategies: "injectManifest",
      srcDir: "src",
      filename: "sw.ts",
      injectRegister: null,
      devOptions: { enabled: false },
      manifest: {
        name: "Pose Deck",
        short_name: "Pose Deck",
        theme_color: "#0a0a0a",
        background_color: "#0a0a0a",
        display: "standalone",
        start_url: "/",
      },
      injectManifest: {
        // Precache the built shell: JS/CSS/HTML/fonts/icons. Image bytes are
        // handled by the Dexie pin, never the SW precache.
        globPatterns: ["**/*.{js,css,html,svg,woff,woff2,ico,png}"],
      },
    }),
  ],
  resolve: {
    alias: {
      "@": path.resolve(__dirname, "./src"),
    },
  },
  server: {
    port: 5173,
  },
});
