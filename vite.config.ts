import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import { VitePWA } from "vite-plugin-pwa";

export default defineConfig({
  plugins: [
    react(),
    VitePWA({
      registerType: "prompt",
      injectRegister: false,
      devOptions: { enabled: false },
      manifest: {
        name: "MisGastos",
        short_name: "MisGastos",
        lang: "es",
        description: "Tus finanzas personales, con claridad.",
        display: "standalone",
        id: "./",
        start_url: "./",
        scope: "./",
        theme_color: "#17634e",
        background_color: "#f5f7f4",
        icons: [
          ...[192, 512].map((size) => ({
            src: `icon-${size}.png`,
            sizes: `${size}x${size}`,
            type: "image/png",
            purpose: "any",
          })),
          {
            src: "icon-maskable-512.png",
            sizes: "512x512",
            type: "image/png",
            purpose: "maskable",
          },
        ],
      },
      workbox: {
        // Solo recursos estáticos. Las respuestas de Auth y financieras no se cachean.
        globPatterns: ["**/*.{js,css,html,svg,png,woff2}"],
        navigateFallbackDenylist: [
          /\/(?:api|rest|auth\/v1|storage|functions)\//,
          /\/[^/?]+\.[^/?]+(?:\?|$)/,
        ],
        runtimeCaching: [],
        skipWaiting: false,
        clientsClaim: false,
        // El precache elimina sus entradas obsoletas al activar. Evitamos la
        // limpieza global de Workbox, que también podría afectar a otra PWA.
        cleanupOutdatedCaches: false,
      },
    }),
  ],
});
