// React context wrapping the session JWT lifecycle:
//   - on mount, attempt to restore a cached JWT from localStorage and validate
//     it by calling /auth/me; on AuthError, discard it and surface a
//     "session expired" flag
//   - signIn caches the JWT + user from a fresh login
//   - signOut clears both
//
// JWT is stored in localStorage under a project-scoped key so multiple apps
// on the same origin don't collide.

import { createContext, useContext, useEffect, useState } from 'react'
import type { ReactNode } from 'react'
import type { User } from '../generated/auth'
import { AuthError, getCurrentUser } from '../api/auth'

const STORAGE_KEY = 'sample_grpc_session_jwt'

interface AuthContextValue {
  user: User | null
  jwt: string | null
  loading: boolean
  sessionExpired: boolean
  signIn: (jwt: string, user: User) => void
  signOut: () => void
}

const AuthContext = createContext<AuthContextValue | undefined>(undefined)

export function AuthProvider({ children }: { children: ReactNode }) {
  const [user, setUser] = useState<User | null>(null)
  const [jwt, setJwt] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)
  const [sessionExpired, setSessionExpired] = useState(false)

  useEffect(() => {
    const cached = localStorage.getItem(STORAGE_KEY)
    if (!cached) {
      setLoading(false)
      return
    }
    getCurrentUser(cached)
      .then((u) => {
        setJwt(cached)
        setUser(u)
      })
      .catch((err) => {
        // Expired/invalid token — clear and prompt to re-sign-in.
        if (err instanceof AuthError) {
          setSessionExpired(true)
        }
        localStorage.removeItem(STORAGE_KEY)
      })
      .finally(() => setLoading(false))
  }, [])

  const signIn = (newJwt: string, newUser: User) => {
    localStorage.setItem(STORAGE_KEY, newJwt)
    setJwt(newJwt)
    setUser(newUser)
    setSessionExpired(false)
  }

  const signOut = () => {
    localStorage.removeItem(STORAGE_KEY)
    setJwt(null)
    setUser(null)
  }

  return (
    <AuthContext.Provider value={{ user, jwt, loading, sessionExpired, signIn, signOut }}>
      {children}
    </AuthContext.Provider>
  )
}

export function useAuth(): AuthContextValue {
  const ctx = useContext(AuthContext)
  if (!ctx) {
    throw new Error('useAuth must be used within an AuthProvider')
  }
  return ctx
}
