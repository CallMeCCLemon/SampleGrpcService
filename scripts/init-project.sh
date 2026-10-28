#!/usr/bin/env bash
# Turns a fresh copy of the template into a new project. Run via:
#   make init NAME=<project_name> REPO=<github url> [MODULE=<go module path>]
#
# NAME is the lowercase, hyphen-free identifier used for k8s resource names,
# the namespace, the DB name, the proto package, and the /<name>/api prefix.
# MODULE defaults to the repo URL without its scheme (github.com/org/repo).
#
# What it does:
#   1. Rewrites project.yaml for the new name, repo, domain, and free NodePorts
#      (picked from the cluster when kubectl can reach it).
#   2. Replaces greeter/Greeter, grpc-demo, sample-grpc, and the Go module path
#      in every tracked file except generated code.
#   3. Renames proto/greeter.proto, regenerates Go + TS stubs and k8s/.
#   4. Enables CI by renaming ci.yml.disabled.
#
# Refuses to run unless project.yaml still has project_name: greeter, so it
# cannot rename a project twice.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

NAME="${1:?usage: init-project.sh NAME REPO [MODULE]}"
REPO="${2:?usage: init-project.sh NAME REPO [MODULE]}"
REPO="${REPO%.git}"
MODULE="${3:-${REPO#https://}}"

OLD_NAME=greeter
OLD_MODULE=SampleGrpcProject

die() { echo "init: $*" >&2; exit 1; }

[[ "$NAME" =~ ^[a-z][a-z0-9]*$ ]] || die "NAME must be lowercase letters/digits, starting with a letter (got '$NAME')"
grep -q "^project_name: ${OLD_NAME}$" project.yaml || die "project.yaml is not the untouched template (project_name != ${OLD_NAME}); already initialised?"
for tool in protoc protoc-gen-go protoc-gen-go-grpc envsubst perl; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool not found on PATH"
done

CAP_NAME="$(tr '[:lower:]' '[:upper:]' <<<"${NAME:0:1}")${NAME:1}"
OLD_DOMAIN=$(awk '/^public_domain:/ {print $2}' project.yaml)
BASE_DOMAIN="${OLD_DOMAIN#*.}"

# ── NodePorts ────────────────────────────────────────────────────────────────
# grpc and web NodePorts must be unique across the cluster. kong_nodeport is
# the shared gateway's and stays as-is.
GRPC_PORT=$(awk '/^grpc_nodeport:/ {print $2}' project.yaml)
WEB_PORT=$(awk '/^web_nodeport:/ {print $2}' project.yaml)
if USED=$(kubectl get svc -A --request-timeout=5s -o jsonpath='{.items[*].spec.ports[*].nodePort}' 2>/dev/null); then
    is_used() { tr ' ' '\n' <<<"$USED" | grep -qx "$1"; }
    p=30051; while is_used "$p"; do p=$((p + 1)); done; GRPC_PORT=$p
    p=30090; while is_used "$p"; do p=$((p + 1)); done; WEB_PORT=$p
    echo "init: picked free NodePorts grpc=$GRPC_PORT web=$WEB_PORT"
else
    echo "init: WARNING kubectl cannot reach the cluster; keeping grpc_nodeport=$GRPC_PORT web_nodeport=$WEB_PORT."
    echo "      Those are the template's own ports. Change them in project.yaml before deploying."
fi

# ── project.yaml ─────────────────────────────────────────────────────────────
setcfg() { perl -pi -e "s|^$1:.*|$1: $2|" project.yaml; }
setcfg project_name       "$NAME"
setcfg namespace          "$NAME"
setcfg image_name         "$NAME"
setcfg web_image_name     "$NAME-web"
setcfg public_domain      "$NAME.$BASE_DOMAIN"
setcfg tunnel_adopt_dns   false
setcfg github_repo        "$REPO"
setcfg google_client_id   '""'
setcfg api_prefix         "/$NAME/api"
setcfg grpc_nodeport      "$GRPC_PORT"
setcfg web_nodeport       "$WEB_PORT"

# ── Text replacement across tracked files ────────────────────────────────────
# Generated stubs are deleted and rebuilt below rather than edited, and the
# rendered k8s/*.yaml are re-rendered from templates.
git grep -lzI -e "$OLD_NAME" -e 'Greeter' -e 'grpc-demo' -e 'sample-grpc' -e "$OLD_MODULE" -- . \
        ':!pb' ':!web/src/generated' ':!scripts/init-project.sh' \
    | xargs -0 perl -pi -e "
        s|\Q$OLD_MODULE\E|$MODULE|g;
        s|sample-grpc|$NAME|g;
        s|grpc-demo|$NAME|g;
        s|Greeter|$CAP_NAME|g;
        s|$OLD_NAME|$NAME|g;
    "

# ── Protos + stubs ───────────────────────────────────────────────────────────
git mv "proto/${OLD_NAME}.proto" "proto/${NAME}.proto"
git rm -q --cached pb/${OLD_NAME}*.pb.go web/src/generated/${OLD_NAME}.ts 2>/dev/null || true
rm -f pb/${OLD_NAME}*.pb.go web/src/generated/${OLD_NAME}.ts

make generate-k8s
make proto
if [ ! -d web/node_modules ]; then
    npm --prefix web ci
fi
make web-proto
make check-api-paths

# ── CI + version ─────────────────────────────────────────────────────────────
if [ -f .github/workflows/ci.yml.disabled ]; then
    git mv .github/workflows/ci.yml.disabled .github/workflows/ci.yml
fi
echo "0.1.0" > VERSION

git add -A pb web/src/generated k8s proto project.yaml VERSION web/.env

cat <<EOF

init: done. '$NAME' (module $MODULE, prefix /$NAME/api, https://$NAME.$BASE_DOMAIN)

Next:
  1. make build && make test          # sanity check, then review 'git status' and commit
  2. make kong-register               # paste the block into the platform repo's kong-values template
  3. Follow README "First deploy" for the DB, public hostname, and Google OAuth.
EOF
