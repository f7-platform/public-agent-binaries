#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────
# fseven-controller — one-line installer (curl | bash safe)
#
# Per PROPOSAL-community-deployment §B2. This script is written to be
# safe when piped:  curl -fsSL https://get.fseven.ai/install.sh | bash
#
# Behaviour:
#   1. Verify Docker + docker compose are available.
#   2. If no `.env` exists, generate strong POSTGRES_PASSWORD +
#      ADMIN_API_KEY and write a minimal community `.env`.
#      If `.env` exists, reuse every value verbatim — we NEVER
#      regenerate POSTGRES_PASSWORD on an existing install.
#   3. `docker compose pull && docker compose --profile community up -d`
#   4. Tail the controller logs until we see the bootstrap banner or
#      30 s elapses, whichever comes first.
#   5. Print the dashboard URL and first-run setup URL.
#
# Flags:
#   --with-agent     Non-interactive: also install the agent on this
#                    host after bootstrap. Default in interactive
#                    terminals is to prompt (PR-19). In non-
#                    interactive shells (piped) the prompt is always
#                    skipped; pass this flag to opt in.
#   --dir <path>     Install into <path> instead of $PWD/fseven.
#   --image <ref>    Override controller image (default:
#                    ghcr.io/f7-platform/public-agent-binaries/controller:latest).
#   --port <n>       Host port for the controller (default 8080).
#   --help           Show this message.
# ─────────────────────────────────────────────────────────────────────
set -euo pipefail

# ── PB5 (Audit Run 34/37): restrict the creation mode of every file ──
# This script writes POSTGRES_PASSWORD, FSEVEN_APP_DB_PASSWORD, ADMIN_API_KEY,
# CREDENTIAL_ENCRYPTION_KEY and the CONTROLLER_JWT_PRIVATE_KEY PEM into `.env`.
# Previously `.env` was created with `cat >` at the AMBIENT umask (typically 022
# => 0644) and only chmod'ed to 0600 afterwards, so on a multi-user host every
# one of those secrets was world-readable for the window between the write and
# the chmod. Setting the umask HERE — before any file is created — closes that
# window for every file this script writes (.env, the fetched compose file, temp
# files), rather than trying to remember a chmod at each call site.
#
# The explicit `chmod 600 "$ENV_FILE"` calls below are retained: umask only
# constrains the mode of files this script CREATES, so a `.env` left behind
# world-readable by an older installer still has to be tightened on re-run.
umask 077

# ── Defaults ─────────────────────────────────────────────────────────
INSTALL_DIR="${PWD}/fseven"
CONTROLLER_IMAGE_DEFAULT="ghcr.io/f7-platform/public-agent-binaries/controller:latest"
CONTROLLER_PORT_DEFAULT="8080"
WITH_AGENT="${FSEVEN_WITH_AGENT:-auto}"
CONTROLLER_IMAGE=""
CONTROLLER_PORT=""

# ── Arg parsing ──────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --with-agent)     WITH_AGENT=yes; shift ;;
    --no-agent)       WITH_AGENT=no;  shift ;;
    --dir)            INSTALL_DIR="$2"; shift 2 ;;
    --image)          CONTROLLER_IMAGE="$2"; shift 2 ;;
    --port)           CONTROLLER_PORT="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,32p' "$0"
      exit 0
      ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

CONTROLLER_IMAGE="${CONTROLLER_IMAGE:-$CONTROLLER_IMAGE_DEFAULT}"
CONTROLLER_PORT="${CONTROLLER_PORT:-$CONTROLLER_PORT_DEFAULT}"

# ── Helpers ──────────────────────────────────────────────────────────
log()  { printf '\033[1;34m▸\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m✘\033[0m %s\n' "$*" >&2; exit 1; }

gen_secret() {
  # 32 bytes of entropy, hex-encoded = 64 chars. Prefer openssl (ubiquitous
  # on macOS + Linux); fall back to /dev/urandom if openssl is missing
  # (e.g. minimal Alpine container).
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 32
  else
    head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n'
  fi
}

download_file() {
  local url="$1" dest="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$dest"
  elif command -v wget >/dev/null 2>&1; then
    wget -q "$url" -O "$dest"
  else
    die "Neither curl nor wget is available — cannot download $url"
  fi
}

compute_sha256() {
  local file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{print $1}'
  else
    die "No SHA-256 tool found (need sha256sum or shasum)"
  fi
}

verify_sha256() {
  local file="$1" expected="$2" label="$3" actual
  expected="${expected#sha256:}"
  expected="$(printf '%s' "$expected" | tr '[:upper:]' '[:lower:]')"
  if [[ ! "$expected" =~ ^[0-9a-f]{64}$ ]]; then
    die "Invalid SHA-256 checksum for $label"
  fi
  actual="$(compute_sha256 "$file" | tr '[:upper:]' '[:lower:]')"
  if [[ "$actual" != "$expected" ]]; then
    die "$label checksum mismatch: expected $expected, got $actual"
  fi
  log "Verified $label SHA-256: $actual"
}

manifest_get() {
  local path="$1"
  [[ -n "${MANIFEST_JSON:-}" ]] || return 0
  command -v python3 >/dev/null 2>&1 || return 0
  MANIFEST_PATH="$path" MANIFEST_JSON_INPUT="$MANIFEST_JSON" python3 - <<'PY' 2>/dev/null || true
import json
import os

try:
    value = json.loads(os.environ["MANIFEST_JSON_INPUT"])
    for key in os.environ["MANIFEST_PATH"].split("."):
        if isinstance(value, dict):
            value = value.get(key)
        else:
            value = None
        if value is None:
            break
    if isinstance(value, str):
        print(value)
except Exception:
    pass
PY
}

fetch_sidecar_sha256() {
  local url="$1" label="$2" tmp checksum
  tmp="$(mktemp)"
  if download_file "${url}.sha256" "$tmp" 2>/dev/null; then
    checksum="$(awk 'match($0, /[0-9A-Fa-f]{64}/) { print substr($0, RSTART, RLENGTH); exit }' "$tmp")"
  fi
  rm -f "$tmp"
  if [[ -z "${checksum:-}" ]]; then
    die "No SHA-256 checksum available for $label. Expected ${url}.sha256 or release-manifest checksum metadata."
  fi
  printf '%s' "$checksum"
}

verify_macos_pkg_signature() {
  local pkg="$1"
  if [[ "${OS_NAME:-}" == "Darwin" ]] && command -v pkgutil >/dev/null 2>&1; then
    pkgutil --check-signature "$pkg" >/dev/null || die "macOS package signature verification failed for $pkg"
    log "Verified macOS package signature"
  fi
}

# ── Step 1. Preflight ────────────────────────────────────────────────
log "fseven controller installer — checking prerequisites"

if ! command -v docker >/dev/null 2>&1; then
  die "Docker is not installed. Install Docker Desktop or Docker Engine first:
     macOS / Windows: https://www.docker.com/products/docker-desktop/
     Linux:           https://docs.docker.com/engine/install/"
fi

if ! docker compose version >/dev/null 2>&1; then
  die "Docker Compose v2 is required ('docker compose', not 'docker-compose').
     Update Docker Desktop or install the compose-plugin package."
fi

if ! docker info >/dev/null 2>&1; then
  die "Docker daemon is not running. Start Docker and re-run this script."
fi

mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"
log "Install directory: $INSTALL_DIR"

# ── Step 1b. Resolve release manifest (PR-21 / §D2) ──────────────────
# The manifest is attached to the GitHub Release and lists the
# canonical controller image tag + matching agent installer URLs for
# this version. Remote compose/package downloads fail closed unless
# checksum metadata is available from the manifest, a sidecar, or an
# explicit env override.
MANIFEST_URL="${FSEVEN_RELEASE_MANIFEST_URL:-https://github.com/f7-platform/public-agent-binaries/releases/latest/download/release-manifest.json}"
MANIFEST_JSON=""
if command -v curl >/dev/null 2>&1; then
  MANIFEST_JSON="$(curl -fsSL "$MANIFEST_URL" 2>/dev/null || true)"
elif command -v wget >/dev/null 2>&1; then
  MANIFEST_JSON="$(wget -qO- "$MANIFEST_URL" 2>/dev/null || true)"
fi
if [[ -z "$MANIFEST_JSON" ]]; then
  warn "Could not fetch release manifest from $MANIFEST_URL; remote artifacts will require explicit checksums."
fi
if [[ -n "$MANIFEST_JSON" ]] && command -v python3 >/dev/null 2>&1; then
  # Resolve controller image unless the user explicitly overrode it.
  if [[ "$CONTROLLER_IMAGE" == "$CONTROLLER_IMAGE_DEFAULT" ]]; then
    resolved="$(manifest_get controller.image)"
    if [[ -n "$resolved" ]]; then
      CONTROLLER_IMAGE="$resolved"
      log "Manifest-resolved controller image: $CONTROLLER_IMAGE"
    fi
  fi
fi

# ── Step 2. .env handling (idempotent per §B6) ───────────────────────
ENV_FILE="$INSTALL_DIR/.env"
if [[ -f "$ENV_FILE" ]]; then
  log "Existing .env found — reusing all values (no secret rotation)"
  # shellcheck disable=SC1090
  set -a; source "$ENV_FILE"; set +a
  # Honor PORT from .env on re-runs unless overridden by --port.
  if [[ "$CONTROLLER_PORT" == "$CONTROLLER_PORT_DEFAULT" && -n "${PORT:-}" ]]; then
    CONTROLLER_PORT="$PORT"
  fi
  # Backfill CREDENTIAL_ENCRYPTION_KEY for installs that predate the
  # controller's encrypted-credential requirement (controller startup
  # rejects empty key outside dev). Mirrors private installer behavior.
  if [[ -z "${CREDENTIAL_ENCRYPTION_KEY:-}" ]]; then
    CREDENTIAL_ENCRYPTION_KEY="$(gen_secret)"
    cat >> "$ENV_FILE" <<ENV

# Added by install.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ) for encrypted telemetry HMAC keys.
CREDENTIAL_ENCRYPTION_KEY=${CREDENTIAL_ENCRYPTION_KEY}
ENV
    chmod 600 "$ENV_FILE"
    log "Added missing CREDENTIAL_ENCRYPTION_KEY to existing .env"
  fi
  # Backfill FSEVEN_APP_DB_PASSWORD for installs that predate the CD10 RLS
  # serving-role cutover (Audit Run 35, CD10; synced to the published compose by
  # Audit Run 36, PB8). The updated compose binds the controller serving pool to
  # the least-privilege `fseven_app` role via DATABASE_URL=fseven_app:${FSEVEN_APP_DB_PASSWORD:?}
  # — without this secret `docker compose up` fails closed. The controller
  # provisions + verifies the role from this password at startup, so generating a
  # fresh one here is safe (no existing fseven_app credential to preserve on a
  # pre-cutover install). POSTGRES_PASSWORD is never regenerated; only this new
  # least-privilege secret is added.
  if [[ -z "${FSEVEN_APP_DB_PASSWORD:-}" ]]; then
    FSEVEN_APP_DB_PASSWORD="$(gen_secret)"
    cat >> "$ENV_FILE" <<ENV

# Added by install.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ) for the CD10 RLS serving-role
# cutover (PB8). Password for the least-privilege fseven_app DB role.
FSEVEN_APP_DB_PASSWORD=${FSEVEN_APP_DB_PASSWORD}
ENV
    chmod 600 "$ENV_FILE"
    log "Added missing FSEVEN_APP_DB_PASSWORD to existing .env"
  fi
  FRESH_INSTALL=no
else
  log "Generating .env with fresh secrets"
  POSTGRES_PASSWORD="$(gen_secret)"
  ADMIN_API_KEY="$(gen_secret)"
  # Password for the least-privilege `fseven_app` DB role used by the controller
  # serving pool after the CD10 RLS serving-role cutover (Audit Run 35, CD10/#229;
  # synced into the published compose by Audit Run 36, PB8). The compose binds
  # DATABASE_URL to fseven_app:${FSEVEN_APP_DB_PASSWORD:?}, so a missing value
  # fails `docker compose up` closed — generate a strong one here.
  FSEVEN_APP_DB_PASSWORD="$(gen_secret)"
  # Credential-encryption key is a single-line hex string — fits
  # cleanly in a docker-compose env-file. The JWT signing key is a
  # multi-line Ed25519 PEM; it is provisioned separately in Step 3c
  # (PB4) once the compose file is on disk, because that step verifies
  # the value actually renders before committing to it.
  CREDENTIAL_ENCRYPTION_KEY="$(gen_secret)"
  cat > "$ENV_FILE" <<ENV
# Generated by install.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ)
# Do not commit this file. Back it up — POSTGRES_PASSWORD is required
# to decrypt the database and is never regenerated on re-run.
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
FSEVEN_APP_DB_PASSWORD=${FSEVEN_APP_DB_PASSWORD}
ADMIN_API_KEY=${ADMIN_API_KEY}
CREDENTIAL_ENCRYPTION_KEY=${CREDENTIAL_ENCRYPTION_KEY}
DEPLOYMENT_MODE=Community
CONTROLLER_IMAGE=${CONTROLLER_IMAGE}
PORT=${CONTROLLER_PORT}
ENV
  chmod 600 "$ENV_FILE"
  FRESH_INSTALL=yes
fi

# ── Step 3. Fetch the compose file ───────────────────────────────────
# The installer is typically run from a blank directory, so we fetch
# the canonical compose file from the repo. Local runs (this file
# lives next to docker-compose.yml) pick up the existing one.
if [[ ! -f "$INSTALL_DIR/docker-compose.yml" ]]; then
  COMPOSE_URL_DEFAULT="https://raw.githubusercontent.com/f7-platform/public-agent-binaries/main/docker-compose.yml"
  manifest_compose_url="$(manifest_get artifacts.docker_compose.url)"
  manifest_compose_sha256="$(manifest_get artifacts.docker_compose.sha256)"
  COMPOSE_URL="${FSEVEN_COMPOSE_URL:-${manifest_compose_url:-$COMPOSE_URL_DEFAULT}}"
  COMPOSE_SHA256="${FSEVEN_COMPOSE_SHA256:-$manifest_compose_sha256}"
  log "Fetching compose file from $COMPOSE_URL"
  download_file "$COMPOSE_URL" docker-compose.yml
  if [[ -z "$COMPOSE_SHA256" ]]; then
    die "No SHA-256 checksum available for downloaded compose file. Use the release manifest assets.docker_compose.sha256 field or set FSEVEN_COMPOSE_SHA256."
  fi
  verify_sha256 docker-compose.yml "$COMPOSE_SHA256" "compose file"
fi

# ── Step 3b. Stale-volume guard ──────────────────────────────────────
# Compose derives its project name from the install-dir basename. A
# named volume (e.g. fseven_pgdata) that was initialized by a PREVIOUS
# install in a different directory with the same basename will survive
# that install's teardown and rebind here — with the old
# POSTGRES_PASSWORD baked in. The new .env has a different password,
# so every controller query will 500 with "password authentication
# failed for user \"seven\"". Detect the mismatch and offer to reset.
if [[ "$FRESH_INSTALL" == "yes" ]]; then
  PROJECT_NAME="$(basename "$INSTALL_DIR" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_-' '_')"
  STALE_VOL="${PROJECT_NAME}_pgdata"
  if docker volume inspect "$STALE_VOL" >/dev/null 2>&1; then
    warn "Docker volume '$STALE_VOL' already exists from a previous install
         but this directory has a freshly-generated POSTGRES_PASSWORD.
         Postgres will refuse the new password and the controller will
         fail to start."
    if [[ -t 0 ]]; then
      read -r -p "  Reset the stale volume now? [y/N] " reply
      case "$reply" in
        y|Y|yes|YES) docker volume rm "$STALE_VOL" >/dev/null \
                     && log "Removed stale volume $STALE_VOL" \
                     || die "Failed to remove $STALE_VOL — close other docker compose projects using it, then re-run." ;;
        *) die "Cannot continue with stale volume + fresh .env. Re-run install.sh after:
            docker volume rm $STALE_VOL" ;;
      esac
    else
      die "Non-interactive shell — cannot prompt for volume reset.
          Remove the stale volume explicitly, then re-run:
            docker volume rm $STALE_VOL"
    fi
  fi
fi

# ── Step 3c. Persistent JWT signing key (PB4) ────────────────────────
# Without CONTROLLER_JWT_PRIVATE_KEY the community controller falls back to
# a signing key it generates itself. On controller images at or before v0.2.2
# (the currently published `:latest`) that key is EPHEMERAL — the controller
# logs "generating ephemeral key (tokens won't survive restart)" — so every
# `docker compose restart` / host reboot mints a fresh key and invalidates
# every outstanding agent bearer token. (Admin dashboard sessions use an
# opaque DB-backed `fseven_session` cookie and are NOT affected; the blast
# radius is agent tokens.) Newer controller builds persist a bootstrap key
# under the model-storage volume, but the published image lags that change,
# so the installer cannot rely on it.
#
# The historical reason this was left unset is that the signing key is a
# multi-line Ed25519 PEM and this script asserted a docker-compose env-file
# "can't represent it reliably". Compose v2's dotenv parser does support
# multi-line double-quoted values (it renders them as a YAML block scalar),
# so we provision the key here — and, crucially, we VERIFY it renders through
# `docker compose config` before keeping it. If the local compose build cannot
# parse the value we restore the previous .env and fall back to the
# controller-generated key, so a parser gap degrades to today's behaviour
# instead of breaking the install.
#
# Only written when absent: an existing CONTROLLER_JWT_PRIVATE_KEY is never
# rotated (same contract as POSTGRES_PASSWORD).
if ! grep -q '^CONTROLLER_JWT_PRIVATE_KEY=' "$ENV_FILE"; then
  if command -v openssl >/dev/null 2>&1; then
    JWT_PEM="$(openssl genpkey -algorithm ed25519 2>/dev/null || true)"
    if [[ "$JWT_PEM" == *"BEGIN PRIVATE KEY"* ]]; then
      # PB5 (Audit Run 37): .env.pb4.bak is a FULL PLAINTEXT COPY of every secret in
      # .env — POSTGRES_PASSWORD, FSEVEN_APP_DB_PASSWORD, ADMIN_API_KEY,
      # CREDENTIAL_ENCRYPTION_KEY, and the JWT PEM on a re-run. `umask 077` (top of
      # file) means it is CREATED 0600, so unlike the Windows path it is never
      # world-readable — but if this script dies in the window below (any command
      # failing under `set -e`, Ctrl-C, SIGTERM) the copy is left behind on disk
      # permanently, long after the installer that knew it was temporary is gone.
      # Armed BEFORE the cp so even a failing cp is covered; disarmed after the
      # rm/mv below has done its job.
      trap 'rm -f "$ENV_FILE.pb4.bak"' EXIT INT TERM HUP
      cp "$ENV_FILE" "$ENV_FILE.pb4.bak"
      {
        printf '\n# Added by install.sh on %s — persistent Ed25519 JWT signing\n' \
          "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf '# key (Audit Run 37, PB4). Keep this value: rotating it invalidates every\n'
        printf '# outstanding agent bearer token and forces each agent to re-authenticate.\n'
        printf '# Multi-line double-quoted values are parsed by docker compose v2 and by\n'
        printf '# the `source` on the re-run path above.\n'
        printf 'CONTROLLER_JWT_PRIVATE_KEY="%s\n"\n' "$JWT_PEM"
      } >> "$ENV_FILE"
      chmod 600 "$ENV_FILE"
      if docker compose --profile community config 2>/dev/null \
           | grep -q 'BEGIN PRIVATE KEY'; then
        rm -f "$ENV_FILE.pb4.bak"
        log "Provisioned a persistent JWT signing key (sessions now survive controller restarts)"
      else
        mv "$ENV_FILE.pb4.bak" "$ENV_FILE"
        chmod 600 "$ENV_FILE"
        warn "This docker compose build could not render a multi-line PEM from .env —
         leaving CONTROLLER_JWT_PRIVATE_KEY unset. The controller will generate
         its own signing key; on controller images ≤ v0.2.2 that key is ephemeral,
         so agent bearer tokens are invalidated on every restart (PB4)."
      fi
      # Window closed: the backup is gone on both branches (rm / mv).
      trap - EXIT INT TERM HUP
    else
      warn "openssl could not generate an Ed25519 key — skipping persistent JWT key (PB4)."
    fi
  else
    warn "openssl not found — skipping the persistent JWT signing key (PB4).
         The controller will generate its own key; on images ≤ v0.2.2 that key is
         ephemeral, so agent bearer tokens are invalidated on every restart.
         Install openssl and re-run install.sh to fix this permanently."
  fi
fi

# ── Step 4. Pull + up ────────────────────────────────────────────────
log "Pulling latest controller image"
if ! docker compose --profile community pull 2>&1 | tee /tmp/fseven-pull.log; then
  if grep -qiE 'manifest unknown|not found|denied|unauthorized' /tmp/fseven-pull.log; then
    rm -f /tmp/fseven-pull.log
    die "Image pull failed: the controller image could not be fetched from the registry.

This installer is published from the public-agent-binaries repo, which
intentionally does NOT contain a Dockerfile or controller source — it is
a distribution shell only. There is no local-build fallback (PD2).

To recover:
  1. Confirm CONTROLLER_IMAGE points at a published tag, e.g.
       export CONTROLLER_IMAGE=ghcr.io/f7-platform/public-agent-binaries/controller:<tag>
     and re-run install.sh. The default 'latest' is sometimes unavailable
     between releases; pin a specific version from the public release notes.
  2. If you are behind a registry mirror or air-gapped, follow the
     air-gapped install steps in the public docs (search 'air-gapped').
  3. If you are entitled to the source build, use the private
     fseven-controller repo and its 'docker build' instructions there."
  else
    die "Image pull failed for an unrecognised reason; see /tmp/fseven-pull.log"
  fi
fi
rm -f /tmp/fseven-pull.log

log "Starting services (profile: community)"
docker compose --profile community up -d

# ── Step 5. Wait for bootstrap to finish ─────────────────────────────
# The controller writes /app/model-storage/bootstrap/secrets.env as the
# final step of first-run bootstrap. Polling for that file is more
# reliable than grepping the log stream (which has a race against the
# 60 s deadline on slow machines / fresh DB migrations).
# FSEVEN_BOOTSTRAP_TIMEOUT_SECS: how long to wait for first-run bootstrap.
# Raise it on slow machines / cold DB migrations; lower it to reach the
# "bootstrap did not complete" branch quickly (the installer contract tests
# exercise that branch with a 2 s deadline).
BOOTSTRAP_TIMEOUT_SECS="${FSEVEN_BOOTSTRAP_TIMEOUT_SECS:-120}"
log "Waiting for first-run bootstrap (up to ${BOOTSTRAP_TIMEOUT_SECS} s)…"
DEADLINE=$(( $(date +%s) + BOOTSTRAP_TIMEOUT_SECS ))
SECRETS_PATH="/app/model-storage/bootstrap/secrets.env"
ADMIN_EMAIL=""
BOOTSTRAP_READY="no"
while [[ $(date +%s) -lt $DEADLINE ]]; do
  # Read the secrets file from inside the container. Succeeds the moment
  # bootstrap commits; exits non-zero until then.
  if creds=$(docker compose exec -T controller cat "$SECRETS_PATH" 2>/dev/null); then
    ADMIN_EMAIL=$(printf '%s\n' "$creds" \
      | grep -E '^FSEVEN_BOOTSTRAP_ADMIN_EMAIL=' | cut -d= -f2- | tr -d '\r')
    if [[ -n "$ADMIN_EMAIL" ]] && printf '%s\n' "$creds" | grep -qE '^FSEVEN_BOOTSTRAP_ADMIN_PASSWORD='; then
      BOOTSTRAP_READY="yes"
      break
    fi
  fi
  # Already-bootstrapped re-run: secrets.env exists from a previous run
  # but the banner was not re-emitted. Break on "healthcheck ready".
  if [[ "$FRESH_INSTALL" == "no" ]] \
     && docker compose logs --no-color controller 2>/dev/null \
          | grep -q "Listening (healthcheck ready)"; then
    break
  fi
  sleep 2
done

# ── Step 6. Print URLs + credentials ─────────────────────────────────
# PB3 (Audit Run 34/37): the controller writes the one-time bootstrap password
# in CLEARTEXT to `secrets.env` on the model-storage volume. Newer controller
# builds delete it on the first successful admin login; the published `:latest`
# (v0.2.2) image predates that, so the installer must tell the operator to scrub
# it. The Run-34 fix printed this guidance ONLY on the happy path — but the
# credential is on disk on EVERY branch that reaches here (a re-run and a
# bootstrap-timeout both leave the same cleartext file behind, and both of those
# branches told the operator how to REVEAL the password while never telling them
# to delete it). Emit it from one function called by every branch so the
# guidance cannot drift back out of one of them.
print_scrub_guidance() {
  printf '  \033[1;33m→ After you have logged in, delete the one-time credentials file\n'
  printf '    (the bootstrap password is stored in cleartext at rest):\033[0m\n'
  printf '       docker compose exec controller rm -f %s\n' "$SECRETS_PATH"
  printf '     (newer controller images remove it automatically on first login)\n\n'
}

DASHBOARD_URL="http://localhost:${CONTROLLER_PORT}"
printf '\n\033[1;32m✓\033[0m fseven controller is running at %s\n\n' "$DASHBOARD_URL"
if [[ "$BOOTSTRAP_READY" == "yes" ]]; then
  printf '  \033[1mAdmin login\033[0m\n'
  printf '  Email:     %s\n' "$ADMIN_EMAIL"
  printf '  Password:  stored once at %s\n' "$SECRETS_PATH"
  printf '  Setup:     %s/setup\n' "$DASHBOARD_URL"
  printf '\n  Reveal the one-time password only when ready to log in:\n'
  printf '    docker compose exec controller sh -lc '\''grep ^FSEVEN_BOOTSTRAP_ADMIN_PASSWORD= %s | cut -d= -f2-'\''\n\n' "$SECRETS_PATH"
  printf '  \033[1;33m→ Log in once, then rotate the password under Admin → Profile.\033[0m\n'
  print_scrub_guidance
elif [[ "$FRESH_INSTALL" == "no" ]]; then
  printf 'Dashboard:  %s\n' "$DASHBOARD_URL"
  printf '(Bootstrap credentials are only shown on demand; retrieve the one-time password with:\n'
  printf '   docker compose exec controller sh -lc '\''grep ^FSEVEN_BOOTSTRAP_ADMIN_PASSWORD= %s | cut -d= -f2-'\''\n' "$SECRETS_PATH"
  printf ' if you still have the model-storage volume.)\n\n'
  print_scrub_guidance
else
  # Fresh install but bootstrap did not complete within the deadline.
  printf '\033[1;33m⚠ Bootstrap did not complete within %s s.\033[0m\n' "$BOOTSTRAP_TIMEOUT_SECS"
  printf 'Check logs:  docker compose logs controller\n'
  printf 'Once bootstrap finishes, get credentials with:\n'
  printf '   docker compose exec controller sh -lc '\''grep ^FSEVEN_BOOTSTRAP_ADMIN_PASSWORD= %s | cut -d= -f2-'\''\n\n' "$SECRETS_PATH"
  print_scrub_guidance
fi

# ── Step 7. Self-observer chaining (PR-19) ───────────────────────────
# Offer to install the agent on this same machine so the host
# operator observes their own work. Skipped on Linux (no native
# agent for this push per proposal), skipped in non-interactive
# shells unless --with-agent was passed.
#
# Single-code-path note: uses the existing admin-token API + existing
# silent-install mechanism. No new controller or agent code.
OS_NAME="$(uname -s)"
install_agent() {
  local os arch pkg_url pkg_sha256 installer_tmp token org_id
  case "$OS_NAME" in
    Darwin) os=macos ;;
    *)      log "Skipping agent install (unsupported host: $OS_NAME)"; return 0 ;;
  esac
  case "$(uname -m)" in
    arm64|aarch64) arch=aarch64 ;;
    x86_64)        arch=x86_64 ;;
    *)             warn "Unsupported arch $(uname -m) — skipping agent install"; return 0 ;;
  esac

  log "Fetching default-org id for enrollment-token minting"
  # Read the bootstrap-stamped default org from system_state when
  # available (the bootstrap writer marks it on first run). Falls back
  # to oldest-org-by-created_at for legacy installs that predate the
  # marker.
  org_id="$(docker compose exec -T postgres \
              psql -U seven -d seven_controller -tAc \
                "SELECT value->>'org_id' FROM system_state WHERE key = 'bootstrap'" \
              2>/dev/null | tr -d '[:space:]')" || true
  if [[ -z "$org_id" ]]; then
    org_id="$(docker compose exec -T postgres \
                psql -U seven -d seven_controller -tAc \
                  "SELECT org_id FROM orgs ORDER BY created_at ASC LIMIT 1" \
                2>/dev/null | tr -d '[:space:]')" || true
  fi
  if [[ -z "$org_id" ]]; then
    warn "Could not read default org id — skipping agent install.
         You can install the agent manually from the dashboard."
    return 0
  fi

  # Skip if a device with this hostname is already enrolled (§B6 item 5).
  local host_name
  host_name="$(hostname)"
  local enrolled
  enrolled="$(docker compose exec -T postgres \
                psql -U seven -d seven_controller -tAc \
                  "SELECT 1 FROM devices WHERE hostname = '${host_name//\'/\'\'}' LIMIT 1" \
                2>/dev/null | tr -d '[:space:]')" || true
  if [[ -n "$enrolled" ]]; then
    log "Device '$host_name' already enrolled — skipping agent install"
    return 0
  fi

  log "Minting single-use, 1h-TTL enrollment token"
  local mint_body mint_response token_hash
  mint_body="$(printf '{"label":"install.sh-%s","max_uses":1,"expires_in_hours":1}' "$host_name")"
  mint_response="$(curl -fsSL -X POST \
    -H "Content-Type: application/json" \
    -H "X-Admin-Key: $ADMIN_API_KEY" \
    -d "$mint_body" \
    "http://localhost:${CONTROLLER_PORT}/admin/api/v1/orgs/${org_id}/enrollment-tokens")" \
    || { warn "Token minting failed — skipping agent install"; return 0; }
  # Extract "token" + "token_hash" fields. token is sent to the agent;
  # token_hash is what we poll on to detect successful enrollment
  # (avoids hostname-semantics mismatch between `hostname` and the
  # value the agent's `hostname::get()` returns).
  token="$(printf '%s' "$mint_response" \
             | python3 -c 'import sys,json; print(json.load(sys.stdin)["token"])' \
             2>/dev/null)" || true
  token_hash="$(printf '%s' "$mint_response" \
                  | python3 -c 'import sys,json; print(json.load(sys.stdin)["token_hash"])' \
                  2>/dev/null)" || true
  if [[ -z "$token" ]]; then
    warn "Could not parse enrollment token — skipping agent install"
    return 0
  fi

  pkg_url="${FSEVEN_AGENT_PKG_URL:-}"
  pkg_sha256="${FSEVEN_AGENT_PKG_SHA256:-}"
  if [[ -z "$pkg_url" && -n "$MANIFEST_JSON" ]] && command -v python3 >/dev/null 2>&1; then
    local key="macos_${arch}"
    pkg_url="$(manifest_get "agent.$key.url")"
    if [[ -z "$pkg_url" ]]; then
      pkg_url="$(manifest_get "agent.$key")"
    fi
    if [[ -z "$pkg_sha256" ]]; then
      pkg_sha256="$(manifest_get "agent.$key.sha256")"
    fi
  fi
  if [[ -z "$pkg_url" ]]; then
    pkg_url="https://github.com/f7-platform/public-agent-binaries/releases/latest/download/fseven-agent-${arch}-apple.pkg"
  fi
  log "Downloading agent installer: $pkg_url"
  installer_tmp="$(mktemp -d)/fseven-agent.pkg"
  if ! download_file "$pkg_url" "$installer_tmp"; then
    warn "Agent installer download failed — skipping agent install.
         Grab it manually from the dashboard's Connect an Agent view."
    return 0
  fi
  if [[ -z "$pkg_sha256" ]]; then
    pkg_sha256="$(fetch_sidecar_sha256 "$pkg_url" "agent installer")"
  fi
  verify_sha256 "$installer_tmp" "$pkg_sha256" "agent installer"
  verify_macos_pkg_signature "$installer_tmp"

  log "Installing agent silently (requires sudo)"
  # Write the enrollment seed file before running the installer so the
  # daemon picks it up on first launch. The LaunchDaemon installed by
  # PR-13 does not inherit our shell env, so the conventional
  # FSEVEN_ENROLLMENT_TOKEN env var would be lost across the pkg
  # boundary. /etc/fseven/enrollment-seed is the well-known path the
  # agent config loader consults; if the agent binary shipping in the
  # pkg doesn't yet consume it, the pair-server flow (PR-10) kicks in
  # as the fallback.
  #
  # PB5 (Audit Run 34/37): the seed file is created mode-0600 BEFORE the token
  # is written to it (`install -m 0600 /dev/null`), not created at the umask
  # default and chmod'ed afterwards — otherwise the token is briefly readable by
  # every local user between the write and the chmod. The trailing chmod is kept
  # so a pre-existing file from an earlier install is also tightened.
  sudo mkdir -p /etc/fseven
  sudo install -m 0600 /dev/null /etc/fseven/enrollment-seed.toml
  printf 'enrollment_token = "%s"\ncontroller_url = "http://localhost:%s"\n' \
    "$token" "$CONTROLLER_PORT" \
    | sudo tee /etc/fseven/enrollment-seed.toml >/dev/null
  sudo chmod 0600 /etc/fseven/enrollment-seed.toml

  if ! sudo installer -pkg "$installer_tmp" -target /; then
    warn "Agent install returned non-zero — check /var/log/install.log"
    return 0
  fi
  rm -f "$installer_tmp"

  # Poll the token's use_count to detect enrollment. token_hash is hex
  # (no SQL escaping needed) and avoids hostname-semantics mismatches
  # between `hostname` here and the value the agent's hostname::get()
  # actually reports. Falls back to hostname matching if the controller
  # response didn't include token_hash (older API).
  log "Waiting for agent to enroll (up to 60 s)…"
  local poll_deadline=$(( $(date +%s) + 60 ))
  while [[ $(date +%s) -lt $poll_deadline ]]; do
    local seen=""
    if [[ -n "$token_hash" ]]; then
      seen="$(docker compose exec -T postgres \
                psql -U seven -d seven_controller -tAc \
                  "SELECT 1 FROM enrollment_tokens WHERE token_hash = '${token_hash}' AND use_count > 0" \
                2>/dev/null | tr -d '[:space:]')" || true
    else
      seen="$(docker compose exec -T postgres \
                psql -U seven -d seven_controller -tAc \
                  "SELECT 1 FROM devices WHERE hostname = '${host_name//\'/\'\'}' LIMIT 1" \
                2>/dev/null | tr -d '[:space:]')" || true
    fi
    if [[ -n "$seen" ]]; then
      printf '\n\033[1;32m✓\033[0m Agent enrolled: %s\n' "$host_name"
      return 0
    fi
    sleep 2
  done
  warn "Agent did not enroll within 60 s. Check the daemon logs:
       sudo launchctl list | grep ai.fseven"
}

# Decide whether to run the agent install.
SHOULD_INSTALL_AGENT=no
case "$WITH_AGENT" in
  yes) SHOULD_INSTALL_AGENT=yes ;;
  no)  SHOULD_INSTALL_AGENT=no  ;;
  auto)
    if [[ -t 0 && -t 1 && "$OS_NAME" == "Darwin" ]]; then
      printf '\nInstall the agent on this machine too? [Y/n] '
      read -r reply
      case "${reply:-Y}" in
        y|Y|yes|YES) SHOULD_INSTALL_AGENT=yes ;;
        *)           SHOULD_INSTALL_AGENT=no  ;;
      esac
    fi
    ;;
esac
if [[ "$SHOULD_INSTALL_AGENT" == "yes" ]]; then
  install_agent
fi
