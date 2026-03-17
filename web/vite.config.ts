import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// https://vite.dev/config/
export default defineConfig({
  plugins: [react()],
  server: {
    hmr: true,
    proxy: {
      '/hello': 'http://192.168.1.110:30080',
      '/goodbye': 'http://192.168.1.110:30080',
    },
  },
})
