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
        // Proxy all /api/* requests to Kong, stripping the /api prefix.
        // e.g. POST /api/hello -> Kong receives POST /hello
        // Mirrors the nginx.conf convention so dev and prod behave identically.
        '/api': {
          target: kongUrl,
          rewrite: (path) => path.replace(/^\/api/, ''),
        },
      },
    },
  }
})
