#!/usr/bin/env bash
# Mint a short-lived (1h) HS256 admin JWT signed with the cluster's jwt-secret.
# Requires kubectl access to the project namespace and python3 + openssl.
# Prints the signed JWT to stdout — pipe into curl, grpcurl, etc.
#
# Example:
#   curl -H "Authorization: Bearer $(scripts/mint-cluster-token.sh)" \
#        https://grpc-demo.latentlab.cc/greeter/api/admin/users
#
# The minted token has user_id="admin" — a synthetic value that does NOT
# correspond to a real database row. That's fine for admin-only RPCs like
# ListUsers (which doesn't look up the caller), but DO NOT use this token
# for self-mutating RPCs like UpdateProfile — they will write against the
# non-existent "admin" user_id.

set -euo pipefail

# Resolve the repo root regardless of where the script is invoked from.
cd "$(dirname "$0")/.."

cfg() { grep "^$1:" project.yaml | head -1 | awk '{print $2}'; }
PROJECT_NAME=$(cfg project_name)
NAMESPACE=$(cfg namespace)

JWT_SECRET=$(kubectl get secret "${PROJECT_NAME}-auth" \
    -n "$NAMESPACE" \
    -o jsonpath='{.data.jwt-secret}' | base64 -d)

python3 - "$JWT_SECRET" <<'PYEOF'
import base64, hmac, hashlib, json, time, sys

secret = sys.argv[1]
header = base64.urlsafe_b64encode(
    json.dumps({"alg": "HS256", "typ": "JWT"}, separators=(",", ":")).encode()
).rstrip(b"=").decode()
payload = base64.urlsafe_b64encode(
    json.dumps(
        {"user_id": "admin", "is_admin": True, "exp": int(time.time()) + 3600},
        separators=(",", ":"),
    ).encode()
).rstrip(b"=").decode()
sig = hmac.new(secret.encode(), f"{header}.{payload}".encode(), hashlib.sha256).digest()
print(f"{header}.{payload}.{base64.urlsafe_b64encode(sig).rstrip(b'=').decode()}")
PYEOF
