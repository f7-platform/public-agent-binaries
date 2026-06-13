#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

assert_contains() {
  local file="$1"
  local needle="$2"
  local description="$3"

  if ! grep -Fq -- "$needle" "$file"; then
    printf 'missing %s in %s\n' "$description" "$file" >&2
    exit 1
  fi
}

assert_not_contains() {
  local file="$1"
  local needle="$2"
  local description="$3"

  if grep -Fq -- "$needle" "$file"; then
    printf 'unexpected %s in %s\n' "$description" "$file" >&2
    exit 1
  fi
}

assert_contains \
  "$ROOT_DIR/install.sh" \
  'SECRETS_PATH="/app/model-storage/bootstrap/secrets.env"' \
  'canonical bootstrap secrets path'
assert_contains \
  "$ROOT_DIR/install.sh" \
  'docker compose exec -T controller cat "$SECRETS_PATH"' \
  'container secrets read'
assert_contains \
  "$ROOT_DIR/install.sh" \
  '^FSEVEN_BOOTSTRAP_ADMIN_EMAIL=' \
  'admin email parser'
assert_contains \
  "$ROOT_DIR/install.sh" \
  '^FSEVEN_BOOTSTRAP_ADMIN_PASSWORD=' \
  'admin password readiness check'
assert_not_contains \
  "$ROOT_DIR/install.sh" \
  'ADMIN_PASSWORD="' \
  'shell password variable'
assert_contains \
  "$ROOT_DIR/install.sh" \
  'Listening (healthcheck ready)' \
  'already-bootstrapped readiness fallback'
assert_contains \
  "$ROOT_DIR/install.sh" \
  'CREDENTIAL_ENCRYPTION_KEY=${CREDENTIAL_ENCRYPTION_KEY}' \
  'fresh credential encryption key env write'
assert_contains \
  "$ROOT_DIR/install.sh" \
  'Added missing CREDENTIAL_ENCRYPTION_KEY to existing .env' \
  'existing .env credential key backfill'

# PD2 (Run 28 / Run 29): public-agent-binaries does not ship a Dockerfile or
# controller source. install.sh must NOT attempt a local docker-compose build
# fallback when image pull fails — that path always fails and misleads
# operators. It must also document the lack of a fallback in the failure
# message so operators don't go hunting for a build context.
assert_not_contains \
  "$ROOT_DIR/install.sh" \
  'docker compose --profile community build' \
  'PD2: removed broken local-build fallback'
assert_contains \
  "$ROOT_DIR/install.sh" \
  'There is no local-build fallback (PD2)' \
  'PD2: explicit no-fallback message in pull-failure die'

assert_contains \
  "$ROOT_DIR/install.ps1" \
  '$SecretsPath = "/app/model-storage/bootstrap/secrets.env"' \
  'canonical PowerShell bootstrap secrets path'
assert_contains \
  "$ROOT_DIR/install.ps1" \
  'docker compose exec -T controller cat $SecretsPath' \
  'PowerShell container secrets read'
assert_contains \
  "$ROOT_DIR/install.ps1" \
  '^FSEVEN_BOOTSTRAP_ADMIN_EMAIL=' \
  'PowerShell admin email parser'
assert_contains \
  "$ROOT_DIR/install.ps1" \
  '^FSEVEN_BOOTSTRAP_ADMIN_PASSWORD=' \
  'PowerShell admin password readiness check'
assert_not_contains \
  "$ROOT_DIR/install.ps1" \
  '$AdminPassword' \
  'PowerShell password variable'
assert_contains \
  "$ROOT_DIR/install.ps1" \
  'Listening \(healthcheck ready\)' \
  'PowerShell already-bootstrapped readiness fallback'
assert_contains \
  "$ROOT_DIR/install.ps1" \
  'CREDENTIAL_ENCRYPTION_KEY=$CredentialEncryptionKey' \
  'PowerShell fresh credential encryption key env write'
assert_contains \
  "$ROOT_DIR/install.ps1" \
  'Added missing CREDENTIAL_ENCRYPTION_KEY to existing .env' \
  'PowerShell existing .env credential key backfill'
assert_contains \
  "$ROOT_DIR/install.ps1" \
  'Existing .env PORT detected; using port $Port' \
  'PowerShell existing .env port reuse'
assert_contains \
  "$ROOT_DIR/install.ps1" \
  'Windows ARM64 detected — using x86_64 MSI under emulation' \
  'PowerShell Windows ARM64 emulation warning'
assert_not_contains \
  "$ROOT_DIR/install.ps1" \
  "'ARM64' { 'aarch64' }" \
  'PowerShell Windows ARM64 native asset fallback'

assert_contains \
  "$ROOT_DIR/docker-compose.yml" \
  'CREDENTIAL_ENCRYPTION_KEY: "${CREDENTIAL_ENCRYPTION_KEY:-}"' \
  'compose credential encryption key propagation'
assert_contains \
  "$ROOT_DIR/docker-compose.yml" \
  'FSEVEN_LICENSE_PUB_KEY: "${FSEVEN_LICENSE_PUB_KEY:-}"' \
  'compose license public key propagation'

# PB7 / INF2 / INF3 (Run 34 / Run 35): the published compose MUST fail closed on
# a missing POSTGRES_PASSWORD. The controller source-of-truth removed the
# `${POSTGRES_PASSWORD:-devpassword}` weak default and adopted the `:?` form;
# the public copy lagged by a month and re-shipped the weak credential, which
# this static test did NOT catch (PB6 root cause). Assert the fail-closed form
# is present and the weak default is absent so the drift can never recur silently.
assert_contains \
  "$ROOT_DIR/docker-compose.yml" \
  'POSTGRES_PASSWORD: "${POSTGRES_PASSWORD:?' \
  'PB7: postgres password fails closed (no weak default)'
assert_not_contains \
  "$ROOT_DIR/docker-compose.yml" \
  'POSTGRES_PASSWORD:-devpassword' \
  'PB7: weak devpassword default removed'
# NOTE: DATABASE_URL keeps the controller source-of-truth `${POSTGRES_PASSWORD:-}`
# form verbatim (INF9 parity). That empty fallback is NOT fail-open here: the
# postgres service above aborts `docker compose up` via the `:?` form before the
# controller can connect, so a missing password can never reach the DB. Asserting
# the postgres `:?` invariant (above) is the correct gate; diverging DATABASE_URL
# from the source of truth would itself reintroduce INF9 drift.

# INF9 (Run 34 / Run 35): the published compose must stay in parity with the
# controller source-of-truth. The drift the audit flagged was a missing
# POSTGRES_PORT host-port override and stale env-doc header. Assert the
# parity-relevant invariants so a future divergent re-sync fails CI here.
assert_contains \
  "$ROOT_DIR/docker-compose.yml" \
  '${POSTGRES_BIND:-127.0.0.1}:${POSTGRES_PORT:-5432}:5432' \
  'INF9: POSTGRES_PORT host-port override (controller parity)'
assert_contains \
  "$ROOT_DIR/docker-compose.yml" \
  'published mirror of fseven-controller/docker-compose.yml' \
  'INF9: compose declares itself a synced mirror of the source of truth'

assert_contains \
  "$ROOT_DIR/README.md" \
  'curl -fsSLO "$release_base/$asset.sha256"' \
  'manual macOS/Linux checksum sidecar download'
assert_contains \
  "$ROOT_DIR/README.md" \
  'pkgutil --check-signature "$asset"' \
  'manual macOS package signature verification'
assert_contains \
  "$ROOT_DIR/README.md" \
  'Get-FileHash $msi -Algorithm SHA256' \
  'manual Windows checksum verification'
assert_contains \
  "$ROOT_DIR/README.md" \
  'Get-AuthenticodeSignature $msi' \
  'manual Windows Authenticode verification'
assert_contains \
  "$ROOT_DIR/README.md" \
  'if ($signature.Status -ne '\''Valid'\'') { throw "No valid Authenticode signature for $msi" }' \
  'manual Windows Authenticode fail-closed check'
assert_contains \
  "$ROOT_DIR/README.md" \
  'sha256sum "$asset"' \
  'manual Linux checksum verification'
assert_contains \
  "$ROOT_DIR/CHANGELOG.md" \
  'Release trust is per tag' \
  'changelog release trust posture'
assert_contains \
  "$ROOT_DIR/CHANGELOG.md" \
  'Release notes should say which signing and notarization' \
  'per-release signing/notarization status'
assert_contains \
  "$ROOT_DIR/.github/copilot-instructions.md" \
  'release-manifest.json' \
  'copilot instructions current manifest release flow'
assert_contains \
  "$ROOT_DIR/.github/copilot-instructions.md" \
  '.sha256' \
  'copilot instructions current checksum flow'
assert_contains \
  "$ROOT_DIR/.github/copilot-instructions.md" \
  'Windows ARM64 uses the Windows' \
  'copilot instructions Windows ARM64 emulation posture'
assert_not_contains \
  "$ROOT_DIR/.github/copilot-instructions.md" \
  'v{version}/{platform}/{artifact}' \
  'stale copilot instructions versioned directory flow'
assert_not_contains \
  "$ROOT_DIR/.github/copilot-instructions.md" \
  'SHA256SUMS' \
  'stale copilot instructions SHA256SUMS flow'

if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  rendered_compose="$(mktemp)"
  trap 'rm -f "$rendered_compose"' EXIT
  (
    cd "$ROOT_DIR"
    POSTGRES_PASSWORD='test-postgres-password' \
      ADMIN_API_KEY='test-admin-key' \
      CREDENTIAL_ENCRYPTION_KEY='0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef' \
      FSEVEN_LICENSE_PUB_KEY='test-license-public-key' \
      docker compose --profile community config > "$rendered_compose"
  )
  assert_contains \
    "$rendered_compose" \
    'CREDENTIAL_ENCRYPTION_KEY: 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef' \
    'rendered compose credential encryption key'
  assert_contains \
    "$rendered_compose" \
    'FSEVEN_LICENSE_PUB_KEY: test-license-public-key' \
    'rendered compose license public key'
  assert_contains \
    "$rendered_compose" \
    'DATABASE_URL: postgres://seven:test-postgres-password@postgres:5432/seven_controller' \
    'rendered compose database password propagation'
  # INF9: the default host port for Postgres must render to 5432 (POSTGRES_PORT
  # override defaulting), matching the controller source-of-truth compose.
  # `docker compose config` emits the long-form port mapping.
  assert_contains \
    "$rendered_compose" \
    'host_ip: 127.0.0.1' \
    'rendered compose default POSTGRES_BIND host_ip'
  assert_contains \
    "$rendered_compose" \
    'published: "5432"' \
    'rendered compose default POSTGRES_PORT host mapping'

  # PB7 / INF2: with POSTGRES_PASSWORD unset, the published compose must fail
  # closed — `docker compose config` must error out rather than render a
  # passwordless / weak-default Postgres. This is the runtime invariant whose
  # absence let the PB7 devpassword drift reach CI undetected (PB6).
  if (
        cd "$ROOT_DIR"
        ADMIN_API_KEY='test-admin-key' \
          docker compose --profile community config >/dev/null 2>&1
     ); then
    printf 'PB7: compose rendered WITHOUT POSTGRES_PASSWORD (expected fail-closed)\n' >&2
    exit 1
  fi
  printf 'PB7: compose fails closed when POSTGRES_PASSWORD is unset (verified)\n'
else
  printf 'docker compose not available; skipped rendered compose contract\n'
fi

printf 'bootstrap handoff static checks passed\n'
