import { defineConfig, loadEnv } from 'vite'
import react from '@vitejs/plugin-react'
import type { ClientRequest } from 'node:http'

// https://vite.dev/config/
export default defineConfig(({ mode }) => {
  const env = loadEnv(mode, process.cwd(), '')
  // PUBLIC_DOMAIN is written to web/.env by `make generate-k8s`. The Kong
  // Ingress is host-scoped to it, so every proxied request must carry it as
  // Host. KONG_URL (shell or .env.development.local) points the proxy at an
  // in-cluster Kong NodePort instead of the public domain.
  const publicDomain = env.PUBLIC_DOMAIN
  const kongUrl = env.KONG_URL ?? `https://${publicDomain}`

  return {
    plugins: [react()],
    server: {
      hmr: true,
      // Mirrors the production nginx header for Google Sign-In's popup.
      headers: {
        'Cross-Origin-Opener-Policy': 'same-origin-allow-popups',
      },
      proxy: {
        // Forward /greeter/* directly to Kong, preserving the full path.
        // Kong runs with strip-path: "false" so it matches against
        // /greeter/api/... — the proto annotations include the full prefix.
        // Mirrors the nginx.conf convention so dev and prod behave identically.
        '/greeter': {
          target: kongUrl,
          changeOrigin: true,
          // changeOrigin and `headers` both lose to Node's host derivation
          // when the target is a raw IP:NodePort; proxyReq runs after it.
          configure: (proxy) => {
            proxy.on('proxyReq', (proxyReq: ClientRequest) => {
              proxyReq.setHeader('host', publicDomain)
            })
          },
        },
      },
    },
  }
})
