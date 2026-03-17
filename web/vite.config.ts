import { defineConfig, loadEnv } from 'vite'
import react from '@vitejs/plugin-react'

// https://vite.dev/config/
export default defineConfig(({ mode }) => {
  const env = loadEnv(mode, process.cwd(), '')
  // KONG_URL is the Kong proxy address used by the dev server proxy.
  // Override via .env.development.local or KONG_URL env var.
  const kongUrl = env.KONG_URL

  return {
    plugins: [react()],
    server: {
      hmr: true,
      proxy: {
        // Proxy any path that starts with a lowercase letter and contains no dots.
        // This catches all Kong API endpoints (e.g. /hello, /goodbye, /any-future-route)
        // while leaving Vite internals (/@vite/...), static assets (/assets/main.js,
        // /favicon.svg), and the root (/) unproxied.
        '^/[a-z][^.]*$': kongUrl,
      },
    },
  }
})
