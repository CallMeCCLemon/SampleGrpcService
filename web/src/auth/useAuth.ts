import { createContext, useContext } from 'react'
import type { User } from '../generated/auth'

export interface AuthContextValue {
  user: User | null
  jwt: string | null
  loading: boolean
  sessionExpired: boolean
  signIn: (jwt: string, user: User) => void
  signOut: () => void
}

export const AuthContext = createContext<AuthContextValue | undefined>(undefined)

export function useAuth(): AuthContextValue {
  const ctx = useContext(AuthContext)
  if (!ctx) {
    throw new Error('useAuth must be used within an AuthProvider')
  }
  return ctx
}
