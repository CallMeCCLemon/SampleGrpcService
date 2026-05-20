# Claude Code Instructions — SampleGrpcProject

## Tool preferences

**Reading files**: Use the `Read` tool, not `Bash` with `cat`, `head`, `tail`, or `sed`. Reserve `Bash` for operations that have no direct tool equivalent (building, testing, git, grepping for patterns).

**Editing files**: Use `Edit` or `Write`, not `sed -i` or `awk`.

These preferences reduce unnecessary permission prompts and make diffs reviewable.

## Make targets — use these, not raw tool invocations

Always prefer the project's `make` targets over running `go`, `npm`, `golangci-lint`, `protoc`, or `kubectl` directly. The targets encode the correct flags, environment, and ordering.

| Goal | Target |
|---|---|
| Build the Go server | `make build` (output: `bin/server`) |
| Regenerate Go gRPC stubs | `make proto` |
| Regenerate TypeScript gRPC stubs | `make web-proto` |
| Run fast Go tests (no Docker) | `make test` |
| Run all tests incl. testcontainers | `make test-integration` |
| Full lint sweep | `make lint` |
| Lint only newly changed lines | `make lint-new` (used by pre-commit hook) |
| Auto-fix formatting + simple issues | `make lint-fix` |
| Go coverage report | `make coverage-go` |
| Enforce coverage floors | `make coverage-check` |
| Validate proto HTTP paths | `make check-api-paths` |
| Render k8s manifests from templates | `make generate-k8s` |
| Build + push backend image | `make docker-build` |
| Build + push web image | `make web-docker-build` |
| Roll out backend | `make deploy` |
| Roll out web | `make web-deploy` |
| Refresh Kong proto configmaps + rollout | `make kong-deploy` (expensive — only on proto/Kong changes) |
| Inspect / prune the cluster registry | `make registry-show` / `make registry-prune` |

Never call `go test ./...`, `go build`, `golangci-lint run`, `protoc`, or `kubectl apply` directly. If a target is missing for something you need, add it to the Makefile.

## Single source of truth: `project.yaml`

Project-specific values (names, namespace, IPs, NodePorts, image names, OAuth client ID, coverage floors) live in `project.yaml`. After editing, run `make generate-k8s` to re-render `k8s/*.yaml` and `web/.env`. Never edit generated files directly — they are clobbered on the next render.

## Routing model: do not strip the API prefix

Kong runs with `strip-path: "false"`. Every proto `google.api.http` annotation must include the full `api_prefix` (default `/greeter/api`). `make check-api-paths` enforces this.

If you change `api_prefix` in `project.yaml`, you must:

1. Update every annotation in `proto/*.proto`.
2. Run `make proto && make web-proto`.
3. Update the frontend's hard-coded `/greeter/api` references in `web/src/api/auth.ts` and `web/src/App.tsx`.
4. Update the Vite dev proxy in `web/vite.config.ts` and the production proxy in `web/nginx.conf`.
5. Run `make kong-deploy` to push the new configmap.

## Common workflows

### Proto changes

```bash
make proto              # Go stubs
make web-proto          # TypeScript stubs
make check-api-paths    # verify annotations include the prefix
make test               # ensure nothing broke
make kong-deploy        # only if HTTP routes changed; expensive
```

### Adding a new auth-gated RPC

1. Add the RPC to `proto/auth.proto` (or another proto in the `greeter` package) with the full `/greeter/api/...` path in its `google.api.http` annotation.
2. Run `make proto && make web-proto`.
3. Implement the handler in `internal/auth/service.go` (or the appropriate package). Use `auth.ClaimsFromContext(ctx)` to get the caller's identity.
4. Decide gating in `internal/auth/interceptor.go`:
   - Public (anonymous): add to `publicRPCs`
   - Admin-only: add to `adminRPCs`
   - Default: requires a valid session JWT, no role check
5. Add a test case to `internal/auth/auth_test.go` for the new gating rule.

### Auth tokens

For one-off admin requests against the cluster, mint an admin JWT with `scripts/mint-cluster-token.sh` and pipe it into curl/grpcurl. Note the synthetic `user_id="admin"` caveat in the script's header — safe for read-only admin RPCs, unsafe for self-mutating ones.

## Tests

- Unit tests live alongside source (`*_test.go`); integration tests are gated by `//go:build integration` and run via `make test-integration` (requires Docker).
- The interceptor matrix in `internal/auth/auth_test.go` is the canonical example of how to test gRPC handlers without standing up a full server — see `TestInterceptor_*`.
- For frontend changes, there's no test runner wired up yet (`web/package.json` has no `test` script). If you add one, also add `make coverage-frontend` and wire it into `make coverage`.

## Pre-commit hook

`make hooks-install` (once per clone) points git at `.githooks/`, which runs `make lint-new` + `go build ./...` before every commit. Skip with `--no-verify` only for emergencies.

## Code commenting style

- Never use em dashes in comments. Avoid prose patterns typical of LLM output (hedging phrases, "essentially", "simply", "note that", restating the obvious).
- Comment with the intent to inform a reader of important implementation details that would otherwise be difficult to understand without reading the entire feature across multiple files.
- Do not reference identifiers or behavior of other components unless necessary for understanding. Focus on what the code in this function directly does.
- Inline comments (non-doc) must be at most 2 sentences describing behavior.
- Doc comments may be longer and should explain relevant details of the function's implementation.
