import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import { VitePWA } from "vite-plugin-pwa";

export default defineConfig({
  plugins: [
    react(),
    VitePWA({
      registerType: "prompt",
      includeAssets: ["icon.svg", "icon-192.png", "icon-512.png"],
      manifest: {
        name: "MisGastos",
        short_name: "MisGastos",
        lang: "es",
        description: "Tus finanzas personales, con claridad.",
        display: "standalone",
        start_url: "/",
        scope: "/",
        theme_color: "#17634e",
        background_color: "#f5f7f4",
        icons: [192, 512].map((size) => ({
          src: `/icon-${size}.png`,
          sizes: `${size}x${size}`,
          type: "image/png",
          purpose: "any",
        })),
      },
      workbox: {
        // Solo recursos estáticos. Las respuestas de Auth y financieras no se cachean.
        globPatterns: ["**/*.{js,css,html,svg,png,woff2}"],
        navigateFallbackDenylist: [/^\/auth\//],
        cleanupOutdatedCaches: true,
      },
    }),
  ],
});
