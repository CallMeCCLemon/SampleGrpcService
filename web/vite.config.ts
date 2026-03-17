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
        '/hello': kongUrl,
        '/goodbye': kongUrl,
      },
    },
  }
})
