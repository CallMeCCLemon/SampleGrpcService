// Minimal sign-in / sign-out strip. Renders a Google Sign-In button when the
// user isn't authenticated; renders "Signed in as X" + sign-out when they are.
// Echo remains usable anonymously regardless of sign-in state.

import { GoogleLogin } from '@react-oauth/google'
import type { CredentialResponse } from '@react-oauth/google'
import { useAuth } from './AuthContext'
import { loginWithGoogle } from '../api/auth'

export function AuthBar() {
  const { user, loading, sessionExpired, signIn, signOut } = useAuth()

  const handleGoogleSuccess = async (cred: CredentialResponse) => {
    if (!cred.credential) return
    try {
      const session = await loginWithGoogle(cred.credential)
      signIn(session.jwt, session.user)
    } catch (err) {
      console.error('sign-in failed:', err)
    }
  }

  if (loading) {
    return <div className="auth-bar">…</div>
  }

  if (user) {
    return (
      <div className="auth-bar">
        <span className="auth-user">
          Signed in as <strong>{user.username || user.displayName}</strong>
          {user.isAdmin && <span className="auth-admin-badge"> admin</span>}
        </span>
        <button className="auth-signout" onClick={signOut}>Sign out</button>
      </div>
    )
  }

  return (
    <div className="auth-bar">
      {sessionExpired && (
        <span className="auth-expired">Session expired — please sign in again.</span>
      )}
      <GoogleLogin onSuccess={handleGoogleSuccess} onError={() => console.error('Google sign-in failed')} />
    </div>
  )
}
