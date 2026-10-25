#!/usr/bin/env bash
#
# Published-compose contract gate — Audit Run 43, PAB8 / PAB15 (#62).
#
# WHAT THIS EXISTS FOR:
#   install.sh and install.ps1 fetch the compose file the release manifest names
#   (artifacts.docker_compose.url, a GitHub Release asset), not this tree's
#   docker-compose.yml. Every other gate in this repository reads the tree, and
#   every installer scenario serves the tree's file over file://, so the compose a
#   `curl … | bash` or `irm … | iex` install actually deploys was never tested:
#   a fix to the tree reaches no new install until a release carries it, and a
#   release asset that regressed would pass CI here.
#
# WHAT THIS CHECKS:
#   1. The live manifest fetches, names a compose URL and a SHA-256, the asset
#      downloads, and its SHA-256 matches. Any of those failing fails the job.
#   2. The security-relevant assertions tests/bootstrap-handoff-static.sh makes
#      over the tree hold over the published file too: fail-closed passwords,
#      the fseven_app serving-role cutover, the OpenFGA playground default, the
#      digest-pinned third-party images, the loopback *_BIND defaults, the
#      secret propagation. Any missing fails the job.
#   3. The published file is compared with the tree, comments aside. Each KNOWN
#      divergence is named in the output and does not fail: which of the two is
#      canonical is the controller release owner's open question (recorded on
#      #62), and this job reports the gap rather than deciding it. Any OTHER
#      divergence fails the job, so a change on either side is read by a person.
#
# Usage:
#   tests/published-compose-contract.sh
#   FSEVEN_RELEASE_MANIFEST_URL=<url or file://…> tests/published-compose-contract.sh
#
# Needs curl, python3 and sha256sum or shasum; a missing tool is a hard failure,
# never a skip (PB6: a check that silently skips is not a check).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TREE="$ROOT_DIR/docker-compose.yml"
MANIFEST_URL="${FSEVEN_RELEASE_MANIFEST_URL:-https://github.com/f7-platform/public-agent-binaries/releases/latest/download/release-manifest.json}"

die()  { printf 'published-compose-contract: %s\n' "$1" >&2; exit "${2:-1}"; }
note() { printf 'published-compose-contract: %s\n' "$1"; }

for tool in curl python3; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool is required and not available"
done
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  else die "no SHA-256 tool (sha256sum or shasum) available"; fi
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# ── 1. The manifest, the asset it names, and its checksum ───────────────────
curl -fsSL "$MANIFEST_URL" -o "$work/release-manifest.json" \
  || die "could not fetch the release manifest from $MANIFEST_URL"
# The manifest is downloaded data: parsed with an isolated interpreter, read-only.
manifest_fields="$(python3 -I - "$work/release-manifest.json" <<'PY'
import json, sys
with open(sys.argv[1]) as fh:
    m = json.load(fh)
dc = (m.get("artifacts") or {}).get("docker_compose") or {}
print(m.get("version", ""))
print(dc.get("url", ""))
sha = str(dc.get("sha256", "")).lower()
print(sha[7:] if sha.startswith("sha256:") else sha)
PY
)" || die "the release manifest is not the JSON this gate expects"
VERSION="$(printf '%s\n' "$manifest_fields" | sed -n 1p)"
COMPOSE_URL="$(printf '%s\n' "$manifest_fields" | sed -n 2p)"
COMPOSE_SHA="$(printf '%s\n' "$manifest_fields" | sed -n 3p)"
[[ -n "$COMPOSE_URL" ]] || die "the manifest ($VERSION) names no artifacts.docker_compose.url"
[[ "$COMPOSE_SHA" =~ ^[0-9a-f]{64}$ ]] || die "the manifest ($VERSION) carries no valid artifacts.docker_compose.sha256"

PUB="$work/published-compose.yml"
curl -fsSL "$COMPOSE_URL" -o "$PUB" || die "could not download the compose the manifest names: $COMPOSE_URL"
actual="$(sha256_of "$PUB")"
[[ "$actual" == "$COMPOSE_SHA" ]] \
  || die "checksum mismatch on $COMPOSE_URL: manifest says $COMPOSE_SHA, downloaded file is $actual"
note "manifest $VERSION names $COMPOSE_URL ($(wc -l < "$PUB" | tr -d ' ') lines, SHA-256 verified)"

# ── 2. The security contract, over the published file ────────────────────────
fails=0
req() {
  if grep -Fq -- "$1" "$PUB"; then note "ok: $2"
  else printf 'published-compose-contract: FAIL: %s (missing: %s)\n' "$2" "$1" >&2; fails=$((fails + 1)); fi
}
forbid() {
  if grep -Fq -- "$1" "$PUB"; then printf 'published-compose-contract: FAIL: %s (present: %s)\n' "$2" "$1" >&2; fails=$((fails + 1))
  else note "ok: $2"; fi
}
req 'POSTGRES_PASSWORD: "${POSTGRES_PASSWORD:?' 'postgres fails closed without POSTGRES_PASSWORD (INF2/INF3)'
req 'DATABASE_URL: "postgres://fseven_app:${FSEVEN_APP_DB_PASSWORD:?' 'serving pool binds the fseven_app role, fail-closed (CD10/PB8)'
req 'DATABASE_ADMIN_URL: "postgres://seven:${POSTGRES_PASSWORD:?' 'owner role on a distinct fail-closed DATABASE_ADMIN_URL (PB8)'
req 'FSEVEN_APP_DB_PASSWORD: "${FSEVEN_APP_DB_PASSWORD:?' 'fseven_app password propagated fail-closed (PB8)'
req 'OPENFGA_DATASTORE_URI: "postgres://seven:${POSTGRES_PASSWORD:?' 'OpenFGA datastore fails closed (INF2)'
req 'OPENFGA_PLAYGROUND_ENABLED: "${OPENFGA_PLAYGROUND_ENABLED:-false}"' 'OpenFGA playground off by default (INF5/PB9)'
forbid 'OPENFGA_PLAYGROUND_ENABLED: "true"' 'OpenFGA playground not hardcoded on (INF5/PB9)'
req 'image: postgres:16-alpine@sha256:e013e867e712fec275706a6c51c966f0bb0c93cfa8f51000f85a15f9865a28cb' 'postgres image digest-pinned (INF7)'
req 'image: openfga/openfga:v1.8@sha256:1e84deddc7c84de8344f3eb0d443c5439666198b68ac37c24fd76fd2e8c1f629' 'openfga image digest-pinned (INF7)'
req 'image: redis:7-alpine@sha256:6ab0b6e7381779332f97b8ca76193e45b0756f38d4c0dcda72dbb3c32061ab99' 'redis image digest-pinned (INF7)'
req 'image: adminer:4@sha256:1068c07446f47f6d52a47387c68341b21b075b6bd651e4bb85d7fc14bca9c33a' 'adminer image digest-pinned (INF7)'
unpinned="$(grep -nE '^[[:space:]]*image:' "$PUB" | grep -v '@sha256:' | grep -vF 'image: ${CONTROLLER_IMAGE:-' || true)"
if [[ -n "$unpinned" ]]; then
  printf 'published-compose-contract: FAIL: third-party image(s) without a digest pin (INF7):\n%s\n' "$unpinned" >&2
  fails=$((fails + 1))
else
  note 'ok: every third-party image is digest-pinned (INF7)'
fi
req '${POSTGRES_BIND:-127.0.0.1}:${POSTGRES_PORT:-5432}:5432' 'Postgres published on loopback by default'
req '${OPENFGA_BIND:-127.0.0.1}:8082:8080' 'OpenFGA published on loopback by default'
req '${REDIS_BIND:-127.0.0.1}:${REDIS_PORT:-6379}:6379' 'Redis published on loopback by default'
req '${ADMINER_BIND:-127.0.0.1}:8081:8080' 'Adminer published on loopback by default'
req 'CONTROLLER_JWT_PRIVATE_KEY: "${CONTROLLER_JWT_PRIVATE_KEY:-}"' 'JWT signing key propagated to the controller (PB4)'
req 'CREDENTIAL_ENCRYPTION_KEY: "${CREDENTIAL_ENCRYPTION_KEY:-}"' 'credential encryption key propagated to the controller'

# ── 3. Divergence from the tree: known ones named, any other fails ───────────
known=0
if grep -q 'dockerfile: Dockerfile' "$PUB"; then
  note 'known divergence: the published compose carries the build: stanza the tree omits (PAB2: no source or Dockerfile is published here)'
  known=$((known + 1))
fi
if ! grep -q 'x-fseven-controller-contract:' "$PUB"; then
  note 'known divergence: the published compose has no x-fseven-controller-contract key (#29); tests/controller-image-parity.sh reads the tree'"'"'s'
  known=$((known + 1))
fi
if grep -q 'STAGED:' "$PUB"; then
  note 'known divergence: the published header describes the serving-role cutover as staged; the tree says it is live (its interpolations already are)'
  known=$((known + 1))
fi
if grep -q -- '- "${PORT:-8080}:8080"' "$PUB"; then
  note 'known divergence: the published compose publishes the controller on every interface; the tree binds loopback through CONTROLLER_BIND (PAB7), which reaches a new install only once a release carries it'
  known=$((known + 1))
fi

# Everything else that differs, comments and blank lines aside, with the lines
# the known divergences account for removed. What is left is unlisted.
norm() { grep -vE '^[[:space:]]*(#|$)' "$1"; }
allow='^[-+][[:space:]]*(build:|context: \.|dockerfile: Dockerfile|x-fseven-controller-contract:|min_controller_version: v[0-9.]+|- "\$\{PORT:-8080\}:8080"|- "\$\{CONTROLLER_BIND:-127\.0\.0\.1\}:\$\{PORT:-8080\}:8080")[[:space:]]*$'
unlisted="$(diff <(norm "$PUB") <(norm "$TREE") | grep -E '^[<>]' | sed -E 's/^< /-/; s/^> /+/' | grep -vE "$allow" || true)"
if [[ -n "$unlisted" ]]; then
  printf 'published-compose-contract: FAIL: the compose the manifest names (%s) differs from the tree in ways this gate does not know\n' "$VERSION" >&2
  printf '  (- published, + tree). Either the release asset or the tree changed; read the lines, then either fix the side that\n' >&2
  printf '  is wrong or, if the difference is deliberate, name it in the known list of %s:\n%s\n' "$0" "$unlisted" >&2
  fails=$((fails + 1))
else
  note "no unlisted divergence between the published compose and the tree (comments aside)"
fi

if [[ "$fails" -gt 0 ]]; then
  die "$fails check(s) failed over the compose the manifest names ($VERSION)"
fi
note "OK — the compose the manifest names ($VERSION) passes the security contract; $known known divergence(s) listed above"
