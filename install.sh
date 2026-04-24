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
# this version. Falls back silently on network failure — the
# defaults below (latest tag + public-agent-binaries "latest"
# release) are still correct for the bleeding edge.
MANIFEST_URL="${FSEVEN_RELEASE_MANIFEST_URL:-https://github.com/f7-platform/public-agent-binaries/releases/latest/download/release-manifest.json}"
MANIFEST_JSON=""
if command -v curl >/dev/null 2>&1; then
  MANIFEST_JSON="$(curl -fsSL "$MANIFEST_URL" 2>/dev/null || true)"
fi
if [[ -n "$MANIFEST_JSON" ]] && command -v python3 >/dev/null 2>&1; then
  # Resolve controller image unless the user explicitly overrode it.
  if [[ "$CONTROLLER_IMAGE" == "$CONTROLLER_IMAGE_DEFAULT" ]]; then
    resolved="$(printf '%s' "$MANIFEST_JSON" \
                 | python3 -c 'import sys,json; print(json.load(sys.stdin)["controller"]["image"])' \
                 2>/dev/null || true)"
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
  FRESH_INSTALL=no
else
  log "Generating .env with fresh secrets"
  POSTGRES_PASSWORD="$(gen_secret)"
  ADMIN_API_KEY="$(gen_secret)"
  # Credential-encryption key is a single-line hex string — fits
  # cleanly in a docker-compose env-file. The JWT signing key, by
  # contrast, is a multi-line Ed25519 PEM which the env-file format
  # can't represent reliably; in Community mode the controller
  # auto-generates an ephemeral JWT key on first boot (logs a warning
  # — PROPOSAL-community-deployment §4.6 calls for this to move into
  # the DB-persisted bootstrap in a follow-up).
  CREDENTIAL_ENCRYPTION_KEY="$(gen_secret)"
  cat > "$ENV_FILE" <<ENV
# Generated by install.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ)
# Do not commit this file. Back it up — POSTGRES_PASSWORD is required
# to decrypt the database and is never regenerated on re-run.
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
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
  COMPOSE_URL="${FSEVEN_COMPOSE_URL:-https://raw.githubusercontent.com/f7-platform/public-agent-binaries/main/docker-compose.yml}"
  log "Fetching compose file from $COMPOSE_URL"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$COMPOSE_URL" -o docker-compose.yml
  elif command -v wget >/dev/null 2>&1; then
    wget -q "$COMPOSE_URL" -O docker-compose.yml
  else
    die "Neither curl nor wget is available — cannot download compose file"
  fi
fi

# ── Step 4. Pull + up ────────────────────────────────────────────────
log "Pulling latest controller image"
if ! docker compose --profile community pull 2>&1 | tee /tmp/fseven-pull.log; then
  if grep -qiE 'manifest unknown|not found|denied' /tmp/fseven-pull.log; then
    warn "Image pull failed (image may not yet be published for this tag).
         Falling back to a local build from the working tree."
    docker compose --profile community build
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
log "Waiting for first-run bootstrap (up to 120 s)…"
DEADLINE=$(( $(date +%s) + 120 ))
SECRETS_PATH="/app/model-storage/bootstrap/secrets.env"
ADMIN_EMAIL=""
ADMIN_PASSWORD=""
while [[ $(date +%s) -lt $DEADLINE ]]; do
  # Read the secrets file from inside the container. Succeeds the moment
  # bootstrap commits; exits non-zero until then.
  if creds=$(docker compose exec -T controller cat "$SECRETS_PATH" 2>/dev/null); then
    ADMIN_EMAIL=$(printf '%s\n' "$creds" \
      | grep -E '^FSEVEN_BOOTSTRAP_ADMIN_EMAIL=' | cut -d= -f2- | tr -d '\r')
    ADMIN_PASSWORD=$(printf '%s\n' "$creds" \
      | grep -E '^FSEVEN_BOOTSTRAP_ADMIN_PASSWORD=' | cut -d= -f2- | tr -d '\r')
    if [[ -n "$ADMIN_EMAIL" && -n "$ADMIN_PASSWORD" ]]; then
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
DASHBOARD_URL="http://localhost:${CONTROLLER_PORT}"
printf '\n\033[1;32m✓\033[0m fseven controller is running at %s\n\n' "$DASHBOARD_URL"
if [[ -n "$ADMIN_EMAIL" && -n "$ADMIN_PASSWORD" ]]; then
  printf '  \033[1mAdmin login\033[0m\n'
  printf '  Email:     %s\n' "$ADMIN_EMAIL"
  printf '  Password:  %s\n' "$ADMIN_PASSWORD"
  printf '  Setup:     %s/setup\n' "$DASHBOARD_URL"
  printf '\n  (credentials also persisted inside the controller at\n'
  printf '   %s — in the model-storage Docker volume)\n\n' "$SECRETS_PATH"
  printf '  \033[1;33m→ Log in once, then rotate the password under Admin → Profile.\033[0m\n\n'
elif [[ "$FRESH_INSTALL" == "no" ]]; then
  printf 'Dashboard:  %s\n' "$DASHBOARD_URL"
  printf '(Admin credentials were printed on first run; retrieve them with:\n'
  printf '   docker compose exec controller cat %s\n' "$SECRETS_PATH"
  printf ' if you still have the model-storage volume.)\n\n'
else
  # Fresh install but bootstrap did not complete within the deadline.
  printf '\033[1;33m⚠ Bootstrap did not complete within 120 s.\033[0m\n'
  printf 'Check logs:  docker compose logs controller\n'
  printf 'Once bootstrap finishes, get credentials with:\n'
  printf '   docker compose exec controller cat %s\n\n' "$SECRETS_PATH"
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
  local os arch pkg_url installer_tmp token org_id
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
  if [[ -z "$pkg_url" && -n "$MANIFEST_JSON" ]] && command -v python3 >/dev/null 2>&1; then
    local key="macos_${arch}"
    pkg_url="$(printf '%s' "$MANIFEST_JSON" \
                 | python3 -c "import sys,json; print(json.load(sys.stdin)['agent']['$key'])" \
                 2>/dev/null || true)"
  fi
  if [[ -z "$pkg_url" ]]; then
    pkg_url="https://github.com/f7-platform/public-agent-binaries/releases/latest/download/fseven-agent-${arch}-apple.pkg"
  fi
  log "Downloading agent installer: $pkg_url"
  installer_tmp="$(mktemp -d)/fseven-agent.pkg"
  if ! curl -fsSL "$pkg_url" -o "$installer_tmp"; then
    warn "Agent installer download failed — skipping agent install.
         Grab it manually from the dashboard's Connect an Agent view."
    return 0
  fi

  log "Installing agent silently (requires sudo)"
  # Write the enrollment seed file before running the installer so the
  # daemon picks it up on first launch. The LaunchDaemon installed by
  # PR-13 does not inherit our shell env, so the conventional
  # FSEVEN_ENROLLMENT_TOKEN env var would be lost across the pkg
  # boundary. /etc/fseven/enrollment-seed is the well-known path the
  # agent config loader consults; if the agent binary shipping in the
  # pkg doesn't yet consume it, the pair-server flow (PR-10) kicks in
  # as the fallback.
  sudo mkdir -p /etc/fseven
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
