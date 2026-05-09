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
  "$ROOT_DIR/docker-compose.yml" \
  'CREDENTIAL_ENCRYPTION_KEY: "${CREDENTIAL_ENCRYPTION_KEY:-}"' \
  'compose credential encryption key propagation'
assert_contains \
  "$ROOT_DIR/docker-compose.yml" \
  'FSEVEN_LICENSE_PUB_KEY: "${FSEVEN_LICENSE_PUB_KEY:-}"' \
  'compose license public key propagation'

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
else
  printf 'docker compose not available; skipped rendered compose contract\n'
fi

printf 'bootstrap handoff static checks passed\n'
