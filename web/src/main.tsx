import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import { GoogleOAuthProvider } from '@react-oauth/google'
import './index.css'
import App from './App.tsx'
import { AuthProvider } from './auth/AuthContext'

// VITE_GOOGLE_CLIENT_ID is baked into the bundle at build time from
// project.yaml (see `make generate-k8s` and the docker-build step).
// Falls back to empty string for dev, in which case the Google button
// won't actually authenticate but the rest of the UI still renders.
const googleClientId = import.meta.env.VITE_GOOGLE_CLIENT_ID ?? ''

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <GoogleOAuthProvider clientId={googleClientId}>
      <AuthProvider>
        <App />
      </AuthProvider>
    </GoogleOAuthProvider>
  </StrictMode>,
)
