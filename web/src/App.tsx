import { useState } from 'react'
import './App.css'
import { HelloRequest, HelloReply, GoodbyeRequest, GoodbyeReply } from './generated/greeter'

// In dev, Vite proxies /hello and /goodbye to Kong (see vite.config.ts).
// In production, set VITE_KONG_BASE to the Kong proxy URL.
const KONG_BASE = import.meta.env.VITE_KONG_BASE ?? ''

async function callGreeter(endpoint: string, req: HelloRequest | GoodbyeRequest): Promise<HelloReply | GoodbyeReply> {
  const res = await fetch(`${KONG_BASE}${endpoint}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(req),
  })
  if (!res.ok) {
    throw new Error(`${res.status}: ${await res.text()}`)
  }
  return res.json()
}

function App() {
  const [name, setName] = useState('')
  const [response, setResponse] = useState<HelloReply | GoodbyeReply | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [loading, setLoading] = useState(false)

  const call = async (endpoint: string) => {
    if (!name.trim()) return
    setLoading(true)
    setError(null)
    setResponse(null)
    try {
      const req: HelloRequest | GoodbyeRequest = { name: name.trim() }
      setResponse(await callGreeter(endpoint, req))
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    } finally {
      setLoading(false)
    }
  }

  return (
    <div className="app">
      <h1>Greeter gRPC PoC</h1>
      <p className="subtitle">Calls the Go gRPC service via Kong HTTP/JSON transcoding</p>

      <div className="form">
        <input
          type="text"
          placeholder="Enter a name"
          value={name}
          onChange={(e) => setName(e.target.value)}
          onKeyDown={(e) => e.key === 'Enter' && call('/hello')}
          disabled={loading}
        />
        <div className="buttons">
          <button onClick={() => call('/hello')} disabled={loading || !name.trim()}>
            Say Hello
          </button>
          <button onClick={() => call('/goodbye')} disabled={loading || !name.trim()}>
            Say Goodbye
          </button>
        </div>
      </div>

      {loading && <p className="status">Loading...</p>}
      {error && <p className="error">{error}</p>}
      {response && <p className="response">{response.message}</p>}
    </div>
  )
}

export default App
