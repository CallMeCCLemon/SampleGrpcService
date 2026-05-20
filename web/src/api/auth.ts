// Thin fetch wrappers around the AuthService HTTP endpoints exposed by Kong.
// All requests go through the same /greeter/api prefix that the rest of the
// app uses (proxied to Kong by vite in dev, by nginx in prod).

import type { User } from '../generated/auth'

// AuthError signals an authentication failure (401). Components catch this to
// know when to clear the cached session JWT.
export class AuthError extends Error {
  constructor(message: string) {
    super(message)
    this.name = 'AuthError'
  }
}

const API_BASE = (import.meta.env.VITE_KONG_BASE ?? '') + '/greeter/api'

async function request<T>(path: string, init: RequestInit, jwt?: string): Promise<T> {
  const headers: Record<string, string> = {
    'Content-Type': 'application/json',
    ...((init.headers as Record<string, string>) ?? {}),
  }
  if (jwt) {
    headers['Authorization'] = `Bearer ${jwt}`
  }

  const res = await fetch(`${API_BASE}${path}`, { ...init, headers })
  if (res.status === 401) {
    throw new AuthError(await res.text())
  }
  if (!res.ok) {
    throw new Error(`${res.status}: ${await res.text()}`)
  }
  return res.json() as Promise<T>
}

interface SessionResponseJSON {
  jwt: string
  user: User
}

// Exchange a Google ID token for a session JWT + user profile.
export async function loginWithGoogle(idToken: string): Promise<SessionResponseJSON> {
  return request<SessionResponseJSON>('/auth/login', {
    method: 'POST',
    body: JSON.stringify({ id_token: idToken }),
  })
}

// Fetch the current user. Throws AuthError if the JWT is missing/expired.
export async function getCurrentUser(jwt: string): Promise<User> {
  return request<User>('/auth/me', { method: 'GET' }, jwt)
}

// Update the current user's username (3–30 alphanumeric/underscore chars,
// or empty string to clear).
export async function updateProfile(jwt: string, username: string): Promise<User> {
  return request<User>(
    '/auth/me',
    { method: 'POST', body: JSON.stringify({ username }) },
    jwt,
  )
}
