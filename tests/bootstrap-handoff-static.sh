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

printf 'bootstrap handoff static checks passed\n'
