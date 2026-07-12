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

# ── Fail-closed tool guard ───────────────────────────────────────────────────
# A check that silently skips is not a check. Several PB4 assertions used to
# no-op whenever python3/openssl were absent, with no guard of any kind — the
# same shape that let PB4 stay open on Windows for three audit runs while CI was
# green. FSEVEN_REQUIRE_TOOLS=1 (set by CI, alongside FSEVEN_REQUIRE_DOCKER and
# FSEVEN_REQUIRE_PWSH) turns every one of those skips into a hard failure, so the
# runner can never quietly stop checking.
#
# Returns 0 when every tool is present; returns 1 when one is missing and the
# guard is OFF (local dev convenience); EXITS non-zero when one is missing and
# the guard is ON.
require_tools() {
  local what="$1"; shift
  local missing="" tool
  for tool in "$@"; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      missing="$missing $tool"
    fi
  done
  if [[ -z "$missing" ]]; then
    return 0
  fi
  if [[ "${FSEVEN_REQUIRE_TOOLS:-0}" == "1" ]]; then
    printf '%s REQUIRES%s (FSEVEN_REQUIRE_TOOLS=1) but it is not available\n' "$what" "$missing" >&2
    exit 1
  fi
  printf '%s:%s unavailable; SKIPPED\n' "$what" "$missing"
  return 1
}

require_real_docker() {
  # Same contract as require_tools, for the captured $REAL_DOCKER path.
  local what="$1"
  if [[ -n "${REAL_DOCKER:-}" ]]; then
    return 0
  fi
  if [[ "${FSEVEN_REQUIRE_DOCKER:-0}" == "1" ]]; then
    printf '%s REQUIRES docker (FSEVEN_REQUIRE_DOCKER=1) but it is not available\n' "$what" >&2
    exit 1
  fi
  printf '%s: docker unavailable; SKIPPED\n' "$what"
  return 1
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

# PB8 (Run 36): install.sh must generate FSEVEN_APP_DB_PASSWORD (fresh installs)
# and backfill it on existing .env files that predate the CD10 cutover. Without
# the secret the updated compose fails closed and the controller cannot provision
# the least-privilege fseven_app role.
assert_contains \
  "$ROOT_DIR/install.sh" \
  'FSEVEN_APP_DB_PASSWORD="$(gen_secret)"' \
  'PB8: install.sh generates a strong fseven_app DB password'
assert_contains \
  "$ROOT_DIR/install.sh" \
  'FSEVEN_APP_DB_PASSWORD=${FSEVEN_APP_DB_PASSWORD}' \
  'PB8: install.sh writes FSEVEN_APP_DB_PASSWORD to .env'
assert_contains \
  "$ROOT_DIR/install.sh" \
  'Added missing FSEVEN_APP_DB_PASSWORD to existing .env' \
  'PB8: install.sh backfills FSEVEN_APP_DB_PASSWORD on existing .env'

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

# PB8 (Run 36): install.ps1 (Windows community installs) must mirror install.sh —
# generate FSEVEN_APP_DB_PASSWORD on fresh installs and backfill it on existing
# .env files predating the CD10 cutover, so Windows installs are not left on the
# owner-role BYPASSRLS path.
assert_contains \
  "$ROOT_DIR/install.ps1" \
  '$FsevenAppDbPassword     = New-Secret' \
  'PB8: install.ps1 generates a strong fseven_app DB password'
assert_contains \
  "$ROOT_DIR/install.ps1" \
  'FSEVEN_APP_DB_PASSWORD=$FsevenAppDbPassword' \
  'PB8: install.ps1 writes FSEVEN_APP_DB_PASSWORD to .env'
assert_contains \
  "$ROOT_DIR/install.ps1" \
  'Added missing FSEVEN_APP_DB_PASSWORD to existing .env' \
  'PB8: install.ps1 backfills FSEVEN_APP_DB_PASSWORD on existing .env'
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

# PB8 (Run 36): the CD10 RLS serving-role cutover (Run 35) was never synced into
# this published compose, so the controller booted as the OWNER role `seven`
# (BYPASSRLS) with an empty-password fallback — silently bypassing all CD10 RLS
# enforcement on every community install. The source-of-truth controller compose
# binds the serving pool to the least-privilege `fseven_app` role over
# DATABASE_URL and keeps the owner role on a separate DATABASE_ADMIN_URL. Assert
# the cutover form so the owner-role regression can never re-enter undetected.
# (The controller falls into main.rs:987-996 "legacy single-role" warning path —
# connecting as owner — only when DATABASE_URL == DATABASE_ADMIN_URL, i.e. when
# the app role is NOT distinct; these assertions guarantee it stays distinct.)
assert_contains \
  "$ROOT_DIR/docker-compose.yml" \
  'DATABASE_URL: "postgres://fseven_app:${FSEVEN_APP_DB_PASSWORD:?' \
  'PB8: controller serving pool connects as least-privilege fseven_app role (fail-closed)'
assert_not_contains \
  "$ROOT_DIR/docker-compose.yml" \
  'DATABASE_URL: "postgres://seven:' \
  'PB8: serving DATABASE_URL no longer uses the owner role (BYPASSRLS regression removed)'
assert_not_contains \
  "$ROOT_DIR/docker-compose.yml" \
  'DATABASE_URL: "postgres://seven:${POSTGRES_PASSWORD:-}@' \
  'PB8: empty-password owner-role serving fallback removed'
assert_contains \
  "$ROOT_DIR/docker-compose.yml" \
  'DATABASE_ADMIN_URL: "postgres://seven:${POSTGRES_PASSWORD:?' \
  'PB8: owner role retained on a distinct fail-closed DATABASE_ADMIN_URL (migrations/bootstrap)'
assert_contains \
  "$ROOT_DIR/docker-compose.yml" \
  'FSEVEN_APP_DB_PASSWORD: "${FSEVEN_APP_DB_PASSWORD:?' \
  'PB8: fseven_app role password propagated fail-closed to the controller service'

# INF2 (Run 34/35/36, HIGH, chronic): the serving DATABASE_URL app password MUST
# NOT use a soft empty-string fallback. The chronic INF2 manifestation was an
# `${...:-}` empty default on the app credential, which would boot the controller's
# serving pool with an empty password instead of aborting. The PB8 fix moved the
# serving pool to `postgres://fseven_app:${FSEVEN_APP_DB_PASSWORD:?...}`; this
# assertion pins the app-password specifically to the fail-closed `:?` form and
# forbids any `${FSEVEN_APP_DB_PASSWORD:-...}` soft fallback re-entering, so the
# INF2 regression is owned by name in the gate (not only implied under PB8).
assert_not_contains \
  "$ROOT_DIR/docker-compose.yml" \
  'fseven_app:${FSEVEN_APP_DB_PASSWORD:-' \
  'INF2: serving app password has no soft empty-string fallback (must fail closed)'
assert_not_contains \
  "$ROOT_DIR/docker-compose.yml" \
  'FSEVEN_APP_DB_PASSWORD: "${FSEVEN_APP_DB_PASSWORD:-' \
  'INF2: fseven_app password env has no soft empty-string fallback (must fail closed)'

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

# INF5 (Run 34) / PB9 (Run 36): the OpenFGA playground exposes the authorization-
# model editing UI and must never ship enabled in the prod profile. The controller
# source-of-truth defaults it OFF (`${OPENFGA_PLAYGROUND_ENABLED:-false}`); the
# published mirror had drifted to a hardcoded "true". Assert the defaulted-false
# form is present and the hardcoded-true form is absent so the drift can never
# re-enter undetected.
assert_contains \
  "$ROOT_DIR/docker-compose.yml" \
  'OPENFGA_PLAYGROUND_ENABLED: "${OPENFGA_PLAYGROUND_ENABLED:-false}"' \
  'INF5/PB9: OpenFGA playground defaults to OFF (opt-in only)'
assert_not_contains \
  "$ROOT_DIR/docker-compose.yml" \
  'OPENFGA_PLAYGROUND_ENABLED: "true"' \
  'INF5/PB9: OpenFGA playground is not hardcoded enabled'

# PB6 (Run 34/35/36, Maintainability): this static gate is the ONLY automated
# check that catches compose drift between releases, and it previously did not
# assert the post-CD10 parity surface — which is exactly how PB8 (owner-role
# serving) and PB9 (hardcoded-true playground) entered main undetected. The four
# post-CD10 parity invariants are now each asserted above; this block fails the
# gate if any of them is silently removed, so a regression to PB8/PB9/INF4/INF5
# cannot re-enter without tripping a PB6-named guard. (Assertions for each live in
# the PB8 + INF5/PB9 blocks above; this is the consolidated completeness check.)
#   (a) serving DATABASE_URL binds the least-privilege fseven_app role
assert_contains \
  "$ROOT_DIR/docker-compose.yml" \
  'DATABASE_URL: "postgres://fseven_app:${FSEVEN_APP_DB_PASSWORD:?' \
  'PB6: gate covers post-CD10 serving-role parity (fseven_app DATABASE_URL)'
#   (b) owner role retained on a distinct fail-closed DATABASE_ADMIN_URL
assert_contains \
  "$ROOT_DIR/docker-compose.yml" \
  'DATABASE_ADMIN_URL: "postgres://seven:${POSTGRES_PASSWORD:?' \
  'PB6: gate covers post-CD10 owner-role parity (distinct DATABASE_ADMIN_URL)'
#   (c) fseven_app password propagated fail-closed to the controller service
assert_contains \
  "$ROOT_DIR/docker-compose.yml" \
  'FSEVEN_APP_DB_PASSWORD: "${FSEVEN_APP_DB_PASSWORD:?' \
  'PB6: gate covers post-CD10 app-password parity (FSEVEN_APP_DB_PASSWORD)'
#   (d) OpenFGA playground uses the defaulted-false form
assert_contains \
  "$ROOT_DIR/docker-compose.yml" \
  'OPENFGA_PLAYGROUND_ENABLED: "${OPENFGA_PLAYGROUND_ENABLED:-false}"' \
  'PB6: gate covers post-CD10 OpenFGA-playground parity (defaulted-false)'

# PB4 (Run 34/35/36/37, LOW, chronic): install.sh must provision a PERSISTENT
# Ed25519 JWT signing key into .env. Without it the community controller
# generates its own key, and on the published image (v0.2.2) that key is
# ephemeral — it logs "generating ephemeral key (tokens won't survive restart)"
# and every container restart invalidates outstanding agent bearer tokens.
# The provisioning must (a) only write when the key is absent (never rotate an
# existing key), (b) verify the multi-line PEM actually renders through
# `docker compose config` before keeping it, and (c) restore the previous .env
# if it does not — a compose-parser gap must degrade to the old behaviour, never
# break the install.
assert_contains \
  "$ROOT_DIR/install.sh" \
  "openssl genpkey -algorithm ed25519" \
  'PB4: install.sh generates an Ed25519 JWT signing key'
assert_contains \
  "$ROOT_DIR/install.sh" \
  "if ! grep -q '^CONTROLLER_JWT_PRIVATE_KEY=' \"\$ENV_FILE\"; then" \
  'PB4: JWT key is only provisioned when absent (existing key never rotated)'
assert_contains \
  "$ROOT_DIR/install.sh" \
  'CONTROLLER_JWT_PRIVATE_KEY="%s\n"' \
  'PB4: PEM written as a multi-line double-quoted .env value'
assert_contains \
  "$ROOT_DIR/install.sh" \
  'docker compose --profile community config 2>/dev/null' \
  'PB4: provisioned PEM is rendered through docker compose config before it is kept'
assert_contains \
  "$ROOT_DIR/install.sh" \
  "grep -q 'BEGIN PRIVATE KEY'" \
  'PB4: rendered compose is checked for the PEM (render verification, not blind write)'
assert_contains \
  "$ROOT_DIR/install.sh" \
  'mv "$ENV_FILE.pb4.bak" "$ENV_FILE"' \
  'PB4: .env is restored if the compose build cannot parse the multi-line PEM'
assert_contains \
  "$ROOT_DIR/docker-compose.yml" \
  'CONTROLLER_JWT_PRIVATE_KEY: "${CONTROLLER_JWT_PRIVATE_KEY:-}"' \
  'PB4: compose propagates the JWT signing key to the controller'

# PB4 — WINDOWS PARITY (Run 37). The Run-34/36 fix landed on install.sh ONLY:
# install.ps1 contained no CONTROLLER_JWT_PRIVATE_KEY at all, so every Windows
# community install still booted the controller on a self-generated EPHEMERAL
# signing key — the exact defect PB4 names — while the CHANGELOG claimed the
# finding was fixed. Windows cannot shell out to openssl (not present) and
# neither .NET Framework 4.x nor .NET 8 exposes an Ed25519 API, so install.ps1
# builds the PKCS#8 document from the fixed RFC 8410 prefix + 32 CSPRNG bytes.
# The behavioral half of this (the generated key really is a valid Ed25519 key,
# and it really survives Compose's dotenv parser) is asserted in the pwsh
# scenarios further down; these are the structural guards.
assert_contains \
  "$ROOT_DIR/install.ps1" \
  'function New-Ed25519PrivateKeyPem' \
  'PB4: install.ps1 mints an Ed25519 JWT signing key (Windows parity)'
assert_contains \
  "$ROOT_DIR/install.ps1" \
  'CONTROLLER_JWT_PRIVATE_KEY=`"$pem`n`"' \
  'PB4: install.ps1 writes the PEM as a multi-line double-quoted .env value'
assert_contains \
  "$ROOT_DIR/install.ps1" \
  "if (\$envText -match '(?m)^CONTROLLER_JWT_PRIVATE_KEY=') { return }" \
  'PB4: install.ps1 never rotates an existing JWT key'
assert_contains \
  "$ROOT_DIR/install.ps1" \
  'Move-Item -Path $backup -Destination $EnvFile -Force' \
  'PB4: install.ps1 restores .env if the compose build cannot parse the PEM'
assert_contains \
  "$ROOT_DIR/install.ps1" \
  'Add-PersistentJwtKey -EnvFile $EnvFile -VerifyRender' \
  'PB4: install.ps1 provisions + render-verifies the key on the normal install path'

# PB5 (Run 34/37, INFO): the agent enrollment seed carries a single-use 1h-TTL
# token. The file must be CREATED mode-0600 before the token is written to it —
# a create-at-umask-then-chmod sequence leaves the token world-readable for the
# window in between.
assert_contains \
  "$ROOT_DIR/install.sh" \
  'sudo install -m 0600 /dev/null /etc/fseven/enrollment-seed.toml' \
  'PB5: enrollment seed file is created 0600 before the token is written'
assert_contains \
  "$ROOT_DIR/install.sh" \
  'sudo chmod 0600 /etc/fseven/enrollment-seed.toml' \
  'PB5: enrollment seed file permissions are enforced after the write'

# PB5 — THE .env WINDOW (Run 37). The Run-34 fix closed the TOCTOU window on the
# enrollment seed but NOT on `.env`, which by then held four secrets (and, after
# the PB4 fix, the JWT private key too). `.env` was created with `cat >` at the
# AMBIENT umask and chmod'ed 0600 only afterwards, so POSTGRES_PASSWORD /
# FSEVEN_APP_DB_PASSWORD / ADMIN_API_KEY / CREDENTIAL_ENCRYPTION_KEY were
# world-readable in between. install.sh now sets `umask 077` before creating any
# file; install.ps1 creates .env empty, restricts it, and only then writes the
# secrets. Both are proven behaviorally in the scenarios below.
assert_contains \
  "$ROOT_DIR/install.sh" \
  'umask 077' \
  'PB5: install.sh restricts the creation mode of every file it writes'
assert_contains \
  "$ROOT_DIR/install.ps1" \
  'function Protect-FilePath' \
  'PB5: install.ps1 has an owner-only file restriction helper'
assert_contains \
  "$ROOT_DIR/install.ps1" \
  'Write-SecretFile $EnvFile' \
  'PB5: install.ps1 writes .env through the create-restricted-then-write path'
assert_not_contains \
  "$ROOT_DIR/install.ps1" \
  '"@ | Set-Content -Path $EnvFile -Encoding ASCII' \
  'PB5: install.ps1 no longer writes secrets at the inherited ACL and tightens afterwards'

# PB3 (Run 34/37, LOW): the controller writes the one-time bootstrap password in
# cleartext to the model-storage volume. The installer cannot stop that write
# (it is controller-side), but it MUST tell the operator to scrub the file after
# the first login instead of leaving it at rest indefinitely.
#
# The Run-34 fix printed the guidance ONLY on the happy path. The re-run branch
# and the bootstrap-timeout branch both leave the same cleartext credential on
# disk and both told the operator how to REVEAL it while never telling them to
# delete it; install.ps1 said nothing at all. Both installers now emit the
# guidance from a single function called by every branch. The per-branch proof is
# behavioral (below); this asserts the shared emitter exists and is wired into
# all three branches of each script.
assert_contains \
  "$ROOT_DIR/install.sh" \
  'docker compose exec controller rm -f %s' \
  'PB3: installer tells the operator to delete the cleartext bootstrap secrets file'
if [[ "$(grep -c '^  print_scrub_guidance$' "$ROOT_DIR/install.sh")" -ne 3 ]]; then
  printf 'PB3: install.sh must call print_scrub_guidance from all THREE bootstrap branches\n' >&2
  exit 1
fi
assert_contains \
  "$ROOT_DIR/install.ps1" \
  'function Write-ScrubGuidance' \
  'PB3: install.ps1 has scrub guidance at all (Windows had none)'
if [[ "$(grep -c '^    Write-ScrubGuidance \$SecretsPath$' "$ROOT_DIR/install.ps1")" -ne 3 ]]; then
  printf 'PB3: install.ps1 must call Write-ScrubGuidance from all THREE bootstrap branches\n' >&2
  exit 1
fi

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
      FSEVEN_APP_DB_PASSWORD='test-app-db-password' \
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
  # PB8: the rendered serving DATABASE_URL must resolve to the least-privilege
  # fseven_app role (NOT the owner role `seven`), and the owner role must stay on
  # a DISTINCT DATABASE_ADMIN_URL. If these two ever collapse to the same value
  # the controller falls into the legacy single-role owner path (BYPASSRLS).
  assert_contains \
    "$rendered_compose" \
    'DATABASE_URL: postgres://fseven_app:test-app-db-password@postgres:5432/seven_controller' \
    'PB8: rendered serving DATABASE_URL uses the fseven_app role (not owner)'
  assert_not_contains \
    "$rendered_compose" \
    'DATABASE_URL: postgres://seven:test-postgres-password@postgres:5432/seven_controller' \
    'PB8: rendered serving DATABASE_URL is not the owner role'
  assert_contains \
    "$rendered_compose" \
    'DATABASE_ADMIN_URL: postgres://seven:test-postgres-password@postgres:5432/seven_controller' \
    'PB8: rendered DATABASE_ADMIN_URL keeps the owner role for migrations/bootstrap'
  assert_contains \
    "$rendered_compose" \
    'FSEVEN_APP_DB_PASSWORD: test-app-db-password' \
    'PB8: rendered compose propagates the fseven_app role password'
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

  # INF5 / PB9: render the `prod` profile (which includes the openfga service) and
  # assert the OpenFGA playground resolves to OFF by default. The community profile
  # does not start openfga, so this needs its own render. A future regression to a
  # hardcoded `true` (or a defaulted-true form) would render the model editor
  # enabled here and fail this assertion.
  rendered_prod_compose="$(mktemp)"
  trap 'rm -f "$rendered_compose" "$rendered_prod_compose"' EXIT
  (
    cd "$ROOT_DIR"
    POSTGRES_PASSWORD='test-postgres-password' \
      FSEVEN_APP_DB_PASSWORD='test-app-db-password' \
      ADMIN_API_KEY='test-admin-key' \
      CREDENTIAL_ENCRYPTION_KEY='0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef' \
      FSEVEN_LICENSE_PUB_KEY='test-license-public-key' \
      docker compose --profile prod config > "$rendered_prod_compose"
  )
  assert_contains \
    "$rendered_prod_compose" \
    'OPENFGA_PLAYGROUND_ENABLED: "false"' \
    'INF5/PB9: rendered prod-profile OpenFGA playground defaults OFF'
  assert_not_contains \
    "$rendered_prod_compose" \
    'OPENFGA_PLAYGROUND_ENABLED: "true"' \
    'INF5/PB9: rendered prod-profile OpenFGA playground is not enabled by default'

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

  # PB8 (Run 36): with POSTGRES_PASSWORD SET but FSEVEN_APP_DB_PASSWORD UNSET, the
  # published compose must still fail closed — the serving DATABASE_URL and the
  # FSEVEN_APP_DB_PASSWORD env both use the `:?` form, so `docker compose config`
  # must error rather than render an empty serving credential. This is the runtime
  # invariant that guarantees a pre-CD10 .env (POSTGRES_PASSWORD only) cannot
  # silently start the controller on the owner-role bypass path.
  if (
        cd "$ROOT_DIR"
        POSTGRES_PASSWORD='test-postgres-password' \
          ADMIN_API_KEY='test-admin-key' \
          docker compose --profile community config >/dev/null 2>&1
     ); then
    printf 'PB8: compose rendered WITHOUT FSEVEN_APP_DB_PASSWORD (expected fail-closed)\n' >&2
    exit 1
  fi
  printf 'PB8: compose fails closed when FSEVEN_APP_DB_PASSWORD is unset (verified)\n'

  # ── PB4: the decisive test ─────────────────────────────────────────────────
  # THE behaviour the entire PB4 fix rests on is that a multi-line Ed25519 PEM,
  # written into a dotenv file, survives Compose v2's dotenv parser and reaches
  # the container's environment INTACT. Until now nothing tested it: every PB4
  # assertion was a `grep -F` for source text in install.sh, and the "rendered
  # compose" half of this gate never rendered a PEM at all. A grep for source
  # text cannot fail if Compose mangles the value — the installer would have
  # silently shipped a broken key to every self-hoster.
  #
  # So: write a REAL PEM into a REAL .env in the exact form the installers
  # serialize it, render it with the REAL `docker compose`, pull the value back
  # out of the CONTAINER's environment, and require it to be byte-for-byte the
  # key we started with (and still parseable as an Ed25519 key). Note the .env
  # is the ONLY source of the value — it is deliberately NOT exported into the
  # process environment, because that would bypass the dotenv parser under test.
  if require_tools 'PB4 rendered-PEM round-trip' openssl python3; then
    pem_dir="$(mktemp -d)"
    trap 'rm -f "$rendered_compose" "$rendered_prod_compose"; rm -rf "$pem_dir"' EXIT
    cp "$ROOT_DIR/docker-compose.yml" "$pem_dir/docker-compose.yml"
    openssl genpkey -algorithm ed25519 -out "$pem_dir/original.pem" 2>/dev/null

    # Serialize exactly as install.sh does (printf 'CONTROLLER_JWT_PRIVATE_KEY="%s\n"\n').
    {
      printf 'POSTGRES_PASSWORD=test-postgres-password\n'
      printf 'FSEVEN_APP_DB_PASSWORD=test-app-db-password\n'
      printf 'ADMIN_API_KEY=test-admin-key\n'
      printf 'CREDENTIAL_ENCRYPTION_KEY=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\n'
      printf 'CONTROLLER_JWT_PRIVATE_KEY="%s\n"\n' "$(cat "$pem_dir/original.pem")"
    } > "$pem_dir/.env"

    (
      cd "$pem_dir"
      # Must not leak in from the ambient environment: the .env file is the
      # subject of the test.
      unset CONTROLLER_JWT_PRIVATE_KEY
      docker compose --profile community config --format json > rendered.json 2>/dev/null
    )

    python3 - "$pem_dir" <<'PY' || exit 1
import json, os, sys

d = sys.argv[1]
with open(os.path.join(d, "rendered.json")) as fh:
    rendered = json.load(fh)
with open(os.path.join(d, "original.pem")) as fh:
    original = fh.read()

env = rendered["services"]["controller"]["environment"]
if "CONTROLLER_JWT_PRIVATE_KEY" not in env:
    sys.exit("PB4: CONTROLLER_JWT_PRIVATE_KEY never reached the controller's container environment")

got = env["CONTROLLER_JWT_PRIVATE_KEY"]
if got is None:
    sys.exit("PB4: CONTROLLER_JWT_PRIVATE_KEY rendered as null")

# The PEM must arrive multi-line and unmangled: Compose must not have collapsed
# the newlines, dropped the armour, or truncated at the first line.
if got.strip() != original.strip():
    sys.exit(
        "PB4: the PEM did NOT survive Compose's dotenv parser intact.\n"
        f"  expected {len(original.strip().splitlines())} lines: {original.strip()!r}\n"
        f"  got      {len(got.strip().splitlines())} lines: {got!r}"
    )
if len(got.strip().splitlines()) < 3:
    sys.exit(f"PB4: rendered PEM is not multi-line: {got!r}")
if "-----BEGIN PRIVATE KEY-----" not in got or "-----END PRIVATE KEY-----" not in got:
    sys.exit(f"PB4: rendered PEM lost its armour: {got!r}")

with open(os.path.join(d, "roundtripped.pem"), "w") as fh:
    fh.write(got if got.endswith("\n") else got + "\n")
PY

    # Final proof: the exact bytes the CONTAINER receives still parse as an
    # Ed25519 private key. If Compose had mangled whitespace or line endings,
    # openssl would reject this even when the string comparison above passed.
    if ! openssl pkey -in "$pem_dir/roundtripped.pem" -noout -text 2>/dev/null \
         | grep -q 'ED25519 Private-Key'; then
      printf 'PB4: the PEM delivered to the container is not a parseable Ed25519 key\n' >&2
      exit 1
    fi
    printf 'PB4: multi-line Ed25519 PEM survives Compose dotenv -> container env intact (verified)\n'
  fi
elif [[ "${FSEVEN_REQUIRE_DOCKER:-0}" == "1" ]]; then
  # PB6 class of failure: a check that silently skips is not a check. CI sets
  # FSEVEN_REQUIRE_DOCKER=1 so the rendered half can never quietly no-op there.
  printf 'docker compose is REQUIRED (FSEVEN_REQUIRE_DOCKER=1) but not available\n' >&2
  exit 1
else
  printf 'docker compose not available; skipped rendered compose contract\n'
fi

# ─────────────────────────────────────────────────────────────────────────────
# Installer behaviour scenarios (PB3 / PB5)
#
# The Run-34 PB3+PB5 fixes were asserted only by grepping install.sh for source
# text, which is how "fixed on the happy path only" and "fixed on bash only"
# both passed CI. These scenarios RUN the installers end-to-end against a stub
# `docker` and assert on what the operator actually sees and what actually lands
# on disk.
# ─────────────────────────────────────────────────────────────────────────────

file_mode() {
  # 0644-style mode, portable across GNU coreutils and BSD/macOS stat.
  if stat -c '%a' "$1" >/dev/null 2>&1; then stat -c '%a' "$1"; else stat -f '%Lp' "$1"; fi
}

first_pem_body_line() {
  # The first base64 line of the PEM inside CONTROLLER_JWT_PRIVATE_KEY: a stable
  # fingerprint of the provisioned key that needs neither python3 nor openssl.
  # The "did the re-run rotate the key?" assertions used to read this out of a
  # .pem file that was only produced when openssl AND python3 were both present —
  # so on a runner missing either, the no-rotation check compared against an
  # empty string and could not fail.
  sed -n '/^CONTROLLER_JWT_PRIVATE_KEY="-----BEGIN PRIVATE KEY-----$/{n;p;q;}' "$1"
}

assert_no_backup_left() {
  # PB5: `.env.pb4.bak` is a byte-for-byte copy of .env — POSTGRES_PASSWORD,
  # FSEVEN_APP_DB_PASSWORD, ADMIN_API_KEY, CREDENTIAL_ENCRYPTION_KEY, and the JWT
  # PEM on a re-run. It exists only as a rollback for the compose-render check and
  # MUST NOT survive the installer, or every secret sits in a second file that no
  # operator knows to delete.
  local dir="$1" label="$2"
  if [[ -e "$dir/.env.pb4.bak" ]]; then
    printf 'PB5 [%s]: left .env.pb4.bak behind — a full plaintext copy of every secret in .env\n' "$label" >&2
    exit 1
  fi
}

make_docker_stub() {
  # A `docker` test double. It never contacts a daemon.
  #
  # `compose config` is delegated to the REAL docker when FSEVEN_REAL_DOCKER
  # points at one, so the installers' own PB4 render-verification step runs for
  # real inside these scenarios. Where no real docker exists it echoes the
  # project's .env, which is only enough to let the installer proceed — the
  # AUTHORITATIVE proof that a PEM survives Compose's dotenv parser is the
  # round-trip test above, which uses the real `docker compose` directly.
  local stub="$1/docker"
  cat > "$stub" <<'STUB'
#!/usr/bin/env bash
set -u
[[ "${1:-}" == "info" ]]   && exit 0
[[ "${1:-}" == "volume" ]] && exit 1   # never report a stale volume
[[ "${1:-}" != "compose" ]] && exit 0
shift
sub=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile|-f|--project-name|-p) shift 2 ;;
    -*) shift ;;
    *)  [[ -z "$sub" ]] && sub="$1"; shift ;;
  esac
done
case "$sub" in
  version) echo 'Docker Compose version v2.0.0-stub' ;;
  config)
    if [[ -n "${FSEVEN_REAL_DOCKER:-}" && -x "${FSEVEN_REAL_DOCKER:-}" ]]; then
      "$FSEVEN_REAL_DOCKER" compose --profile community config
    else
      cat .env 2>/dev/null || true
    fi
    ;;
  pull|up) exit 0 ;;
  exec)
    if [[ "${FSEVEN_TEST_BOOTSTRAP_READY:-no}" == "yes" ]]; then
      printf 'FSEVEN_BOOTSTRAP_ADMIN_EMAIL=admin@example.test\n'
      printf 'FSEVEN_BOOTSTRAP_ADMIN_PASSWORD=stub-one-time-password\n'
      exit 0
    fi
    exit 1
    ;;
  logs)
    [[ "${FSEVEN_TEST_HEALTHCHECK:-no}" == "yes" ]] && echo 'Listening (healthcheck ready)'
    exit 0
    ;;
esac
exit 0
STUB
  chmod +x "$stub"
}

assert_output_contains() {
  local out="$1" needle="$2" description="$3"
  if ! grep -Fq -- "$needle" "$out"; then
    printf 'missing %s in installer output\n---\n%s\n---\n' "$description" "$(cat "$out")" >&2
    exit 1
  fi
}

assert_env_pem_renders() {
  # Take an install directory that a REAL installer just produced (.env +
  # docker-compose.yml) and render it with the REAL `docker compose`, then pull
  # CONTROLLER_JWT_PRIVATE_KEY back out of the controller's container
  # environment and require it to still be a valid, multi-line Ed25519 PEM.
  #
  # This is deliberately fed the installer's OWN output rather than a PEM the
  # test serialized itself: the thing that must not break is the exact byte
  # sequence the installer writes, passed through the exact parser Compose uses.
  local dir="$1" label="$2"
  # Fail closed on CI (FSEVEN_REQUIRE_DOCKER / FSEVEN_REQUIRE_TOOLS): these used to
  # be three bare `|| return 0`s, so on a runner that lost python3 or openssl this
  # entire assertion would evaporate and the gate would still go green.
  require_real_docker "PB4 [$label] installer-written PEM round-trip" || return 0
  require_tools "PB4 [$label] installer-written PEM round-trip" python3 openssl || return 0

  ( cd "$dir" && unset CONTROLLER_JWT_PRIVATE_KEY \
      && "$REAL_DOCKER" compose --profile community config --format json > rendered.json 2>/dev/null )

  python3 - "$dir" "$label" <<'PY' || exit 1
import json, os, re, sys

d, label = sys.argv[1], sys.argv[2]
with open(os.path.join(d, "rendered.json")) as fh:
    env = json.load(fh)["services"]["controller"]["environment"]
got = env.get("CONTROLLER_JWT_PRIVATE_KEY")
if not got:
    sys.exit(f"PB4 [{label}]: the installer's key never reached the container environment")

on_disk = re.search(
    r'^CONTROLLER_JWT_PRIVATE_KEY="(.*?)"', open(os.path.join(d, ".env")).read(), re.S | re.M
)
if not on_disk:
    sys.exit(f"PB4 [{label}]: no CONTROLLER_JWT_PRIVATE_KEY in the .env the installer wrote")

if got.strip() != on_disk.group(1).strip():
    sys.exit(
        f"PB4 [{label}]: the installer's PEM did NOT survive Compose's dotenv parser.\n"
        f"  on disk ({len(on_disk.group(1).strip().splitlines())} lines): {on_disk.group(1)!r}\n"
        f"  in container ({len(got.strip().splitlines())} lines): {got!r}"
    )
if len(got.strip().splitlines()) < 3:
    sys.exit(f"PB4 [{label}]: PEM reached the container collapsed to one line: {got!r}")

with open(os.path.join(d, "roundtripped.pem"), "w") as fh:
    fh.write(got if got.endswith("\n") else got + "\n")
PY

  if ! openssl pkey -in "$dir/roundtripped.pem" -noout -text 2>/dev/null \
       | grep -q 'ED25519 Private-Key'; then
    printf 'PB4 [%s]: the key delivered to the container is not a parseable Ed25519 key\n' "$label" >&2
    exit 1
  fi
  rm -f "$dir/rendered.json" "$dir/roundtripped.pem"
  printf 'PB4: the key %s wrote survives Compose dotenv -> container env intact (verified)\n' "$label"
}

make_chmod_stub() {
  # A `chmod` interceptor, used to prove ORDER OF OPERATIONS rather than final
  # state. Both installers restrict files by shelling out to chmod on this
  # platform (install.sh directly; install.ps1 via Protect-FilePath's non-Windows
  # branch — the exact call site the Windows Set-Acl branch replaces), so it sees
  # every restriction as it happens.
  #
  #   * records "<path>|<size>" — the file's size AT THE MOMENT it is restricted,
  #     which is what says whether secret bytes were already on disk at the
  #     permissive inherited mode/ACL;
  #   * FSEVEN_TEST_CHMOD_FAIL=<suffix> makes the matching chmod FAIL, which under
  #     `set -e` kills install.sh mid-flight — used to prove the secret-copy
  #     cleanup survives a crash.
  #
  # It delegates to the real chmod, so it is transparent to any scenario that does
  # not set FSEVEN_CHMOD_TRACE.
  local stub="$1/chmod"
  local real_chmod
  real_chmod="$(command -v chmod)"
  cat > "$stub" <<TRACE_STUB
#!/usr/bin/env bash
set -u
if [[ -n "\${FSEVEN_CHMOD_TRACE:-}" ]]; then
  for arg in "\$@"; do
    case "\$arg" in
      /*) ;;
      *) continue ;;
    esac
    [[ -f "\$arg" ]] || continue
    if size=\$(stat -c '%s' "\$arg" 2>/dev/null); then :; else size=\$(stat -f '%z' "\$arg"); fi
    printf '%s|%s\n' "\$arg" "\$size" >> "\$FSEVEN_CHMOD_TRACE"
    if [[ -n "\${FSEVEN_TEST_CHMOD_FAIL:-}" && "\$arg" == *"\$FSEVEN_TEST_CHMOD_FAIL" ]]; then
      # Fail on the Nth chmod of this path (the trace line was just appended, so
      # the occurrence count IS the call index). Lets a scenario pick the chmod
      # that sits INSIDE a specific window rather than the first one.
      n=\$(grep -c -F "\$arg|" "\$FSEVEN_CHMOD_TRACE" 2>/dev/null || true)
      if [[ "\${n:-0}" -ge "\${FSEVEN_TEST_CHMOD_FAIL_NTH:-1}" ]]; then
        printf 'chmod: injected failure on %s (call %s)\n' "\$arg" "\$n" >&2
        exit 1
      fi
    fi
  done
fi
exec "$real_chmod" "\$@"
TRACE_STUB
  "$real_chmod" +x "$stub"
}

scenario_root="$(mktemp -d)"
stub_bin="$scenario_root/bin"
mkdir -p "$stub_bin"
make_docker_stub "$stub_bin"
trace_bin="$scenario_root/trace-bin"
mkdir -p "$trace_bin"
make_chmod_stub "$trace_bin"
REAL_DOCKER="$(command -v docker || true)"

COMPOSE_SHA256="$(
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$ROOT_DIR/docker-compose.yml" | awk '{print $1}'
  else shasum -a 256 "$ROOT_DIR/docker-compose.yml" | awk '{print $1}'; fi
)"

# The installers must not reach the network in these scenarios: point the release
# manifest at a nonexistent file:// URL (both fetchers fail closed to "no
# manifest") and serve the compose file from the local checkout over file://.
run_install_sh() {
  local dir="$1" ready="$2" healthcheck="$3" timeout="$4" out="$5"
  (
    umask 000   # hostile ambient umask: PB5's window is only closed if the
                # installer sets its own restrictive creation mode.
    PATH="$stub_bin:$PATH" \
    FSEVEN_REAL_DOCKER="$REAL_DOCKER" \
    FSEVEN_TEST_BOOTSTRAP_READY="$ready" \
    FSEVEN_TEST_HEALTHCHECK="$healthcheck" \
    FSEVEN_BOOTSTRAP_TIMEOUT_SECS="$timeout" \
    FSEVEN_RELEASE_MANIFEST_URL="file:///nonexistent-fseven-release-manifest.json" \
    FSEVEN_COMPOSE_URL="file://$ROOT_DIR/docker-compose.yml" \
    FSEVEN_COMPOSE_SHA256="$COMPOSE_SHA256" \
      bash "$ROOT_DIR/install.sh" --dir "$dir" --no-agent
  ) > "$out" 2>&1
}

# ── Scenario 1: fresh install, bootstrap completes (the happy path) ──────────
sh_fresh="$scenario_root/sh-fresh"
sh_out1="$scenario_root/sh-out-1.txt"
run_install_sh "$sh_fresh" yes no 5 "$sh_out1"

assert_output_contains "$sh_out1" 'admin@example.test' \
  'install.sh: bootstrap admin email on the happy path'
assert_output_contains "$sh_out1" 'docker compose exec controller rm -f /app/model-storage/bootstrap/secrets.env' \
  'PB3: install.sh scrub guidance on the bootstrap-ready branch'

# PB5, behaviorally: the ambient umask was 000, so every file the installer
# created would be world-readable (0666/0644) unless the installer restricts the
# creation mode ITSELF. .env holds POSTGRES_PASSWORD, FSEVEN_APP_DB_PASSWORD,
# ADMIN_API_KEY, CREDENTIAL_ENCRYPTION_KEY and the JWT PEM.
sh_env_mode="$(file_mode "$sh_fresh/.env")"
if [[ "$sh_env_mode" != "600" ]]; then
  printf 'PB5: install.sh .env is mode %s under umask 000 (expected 600)\n' "$sh_env_mode" >&2
  exit 1
fi
# The fetched compose file is never chmod'ed by install.sh. It is 0600 here ONLY
# because `umask 077` was in effect when the file was CREATED — which is the
# property that proves the .env secrets were never world-readable even for the
# instant between the write and the chmod. This is the assertion that actually
# closes the PB5 TOCTOU window; a mode check on .env alone cannot distinguish
# "restricted at creation" from "chmod'ed after a world-readable write".
sh_compose_mode="$(file_mode "$sh_fresh/docker-compose.yml")"
if [[ "$sh_compose_mode" != "600" ]]; then
  printf 'PB5: install.sh created docker-compose.yml mode %s under umask 000 (expected 600 => umask 077 was NOT in effect at file-creation time, so .env secrets are written world-readable before the chmod)\n' "$sh_compose_mode" >&2
  exit 1
fi
printf 'PB5: install.sh creates .env + compose 0600 under a hostile umask 000 (verified)\n'

# PB5: no leftover secret copy. .env.pb4.bak is a FULL copy of every secret in
# .env; the installer must never leave one behind on any exit path.
assert_no_backup_left "$sh_fresh" 'install.sh (happy path)'

# PB4, behaviorally: a persistent key was provisioned into .env, in the
# multi-line form, and it is a real Ed25519 key.
if ! grep -q '^CONTROLLER_JWT_PRIVATE_KEY="-----BEGIN PRIVATE KEY-----$' "$sh_fresh/.env"; then
  printf 'PB4: install.sh did not provision a multi-line CONTROLLER_JWT_PRIVATE_KEY into .env\n' >&2
  exit 1
fi
sh_key_fingerprint="$(first_pem_body_line "$sh_fresh/.env")"
if [[ -z "$sh_key_fingerprint" ]]; then
  printf 'PB4: could not read back the key install.sh wrote into .env\n' >&2
  exit 1
fi
if require_tools 'PB4 install.sh key validity' openssl python3; then
  python3 - "$sh_fresh/.env" > "$scenario_root/sh-key.pem" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
m = re.search(r'^CONTROLLER_JWT_PRIVATE_KEY="(.*?)"', text, re.S | re.M)
if not m:
    sys.exit("PB4: no CONTROLLER_JWT_PRIVATE_KEY in .env")
sys.stdout.write(m.group(1).strip() + "\n")
PY
  if ! openssl pkey -in "$scenario_root/sh-key.pem" -noout -text 2>/dev/null \
       | grep -q 'ED25519 Private-Key'; then
    printf 'PB4: install.sh wrote a CONTROLLER_JWT_PRIVATE_KEY that is not a valid Ed25519 key\n' >&2
    exit 1
  fi
  printf 'PB4: install.sh provisions a valid persistent Ed25519 key into .env (verified)\n'
fi

# And the key install.sh ACTUALLY wrote must reach the container intact.
assert_env_pem_renders "$sh_fresh" "install.sh"

# ── Scenario 2: fresh install, bootstrap TIMES OUT ──────────────────────────
# This branch leaves the cleartext credential on disk exactly like the happy
# path, and before this fix it told the operator how to REVEAL the password
# while never telling them to delete it.
sh_timeout="$scenario_root/sh-timeout"
sh_out2="$scenario_root/sh-out-2.txt"
run_install_sh "$sh_timeout" no no 2 "$sh_out2"
assert_output_contains "$sh_out2" 'Bootstrap did not complete within 2 s' \
  'install.sh: reached the bootstrap-timeout branch'
assert_output_contains "$sh_out2" 'docker compose exec controller rm -f /app/model-storage/bootstrap/secrets.env' \
  'PB3: install.sh scrub guidance on the bootstrap-TIMEOUT branch'

# ── Scenario 3: re-run over an existing .env ────────────────────────────────
# Also proves the re-run path's `set -a; source .env` survives the multi-line PEM
# that the PB4 fix now writes into that same file — if the PEM broke `source`,
# every re-run of the installer would abort under `set -e`.
sh_out3="$scenario_root/sh-out-3.txt"
run_install_sh "$sh_fresh" no yes 5 "$sh_out3"
assert_output_contains "$sh_out3" 'Existing .env found' \
  'install.sh: reached the re-run branch'
assert_output_contains "$sh_out3" 'docker compose exec controller rm -f /app/model-storage/bootstrap/secrets.env' \
  'PB3: install.sh scrub guidance on the RE-RUN branch'

# The re-run must NOT rotate the persistent key (rotating it invalidates every
# outstanding agent bearer token). Compared against a fingerprint taken with
# sed — NOT against a .pem file that only exists when openssl+python3 do, which
# is what this assertion used to depend on.
if ! grep -Fqx -- "$sh_key_fingerprint" "$sh_fresh/.env"; then
  printf 'PB4: install.sh ROTATED CONTROLLER_JWT_PRIVATE_KEY on re-run (must be preserved)\n' >&2
  exit 1
fi
assert_no_backup_left "$sh_fresh" 'install.sh (re-run)'
printf 'PB3: install.sh emits scrub guidance on all three branches (verified)\n'
printf 'PB4: install.sh preserves the existing JWT key on re-run (verified)\n'

# ── Scenario 4: the installer DIES inside the backup window ─────────────────
# .env.pb4.bak is a byte-for-byte copy of .env: POSTGRES_PASSWORD,
# FSEVEN_APP_DB_PASSWORD, ADMIN_API_KEY, CREDENTIAL_ENCRYPTION_KEY. It exists only
# as a rollback for the compose-render check, and the happy/rollback paths both
# remove it — but neither installer had any cleanup on the ERROR path, so an
# installer that died in that window (failing command under `set -e`, Ctrl-C,
# closed terminal) left every secret sitting in a second file, permanently, that
# no operator knows to delete.
#
# Kill it there for real: fault-inject a failure into the SECOND chmod of .env,
# which install.sh performs after the `cp` and before the `rm`/`mv` (install.sh
# :396). The exit must be non-zero AND no .env.pb4.bak may survive.
sh_crash="$scenario_root/sh-crash"
sh_out4="$scenario_root/sh-out-4.txt"
crash_trace="$scenario_root/sh-crash-trace.txt"
: > "$crash_trace"
set +e
(
  umask 000
  PATH="$trace_bin:$stub_bin:$PATH" \
  FSEVEN_REAL_DOCKER="$REAL_DOCKER" \
  FSEVEN_CHMOD_TRACE="$crash_trace" \
  FSEVEN_TEST_CHMOD_FAIL='/.env' \
  FSEVEN_TEST_CHMOD_FAIL_NTH=2 \
  FSEVEN_TEST_BOOTSTRAP_READY=no \
  FSEVEN_TEST_HEALTHCHECK=no \
  FSEVEN_BOOTSTRAP_TIMEOUT_SECS=2 \
  FSEVEN_RELEASE_MANIFEST_URL="file:///nonexistent-fseven-release-manifest.json" \
  FSEVEN_COMPOSE_URL="file://$ROOT_DIR/docker-compose.yml" \
  FSEVEN_COMPOSE_SHA256="$COMPOSE_SHA256" \
    bash "$ROOT_DIR/install.sh" --dir "$sh_crash" --no-agent
) > "$sh_out4" 2>&1
sh_crash_rc=$?
set -e

# The injection must actually have killed it inside the window, or this proves
# nothing: require a non-zero exit AND evidence the backup had been taken.
if [[ "$sh_crash_rc" -eq 0 ]]; then
  printf 'PB5: the crash injection did not kill install.sh (rc=0) — the no-leftover proof below would be vacuous\n' >&2
  cat "$sh_out4" >&2
  exit 1
fi
if ! grep -Fq 'injected failure' "$sh_out4"; then
  printf 'PB5: install.sh died before the injected chmod, not inside the backup window — proof would be vacuous\n' >&2
  cat "$sh_out4" >&2
  exit 1
fi
assert_no_backup_left "$sh_crash" 'install.sh (killed inside the backup window)'
printf 'PB5: install.sh leaves no .env.pb4.bak secret copy behind when it dies mid-window (verified)\n'

# ── install.ps1 scenarios (Windows parity) ──────────────────────────────────
# install.ps1 is the file the Run-34/36 PB3+PB4+PB5 work never touched. Windows
# is a first-class community-install target, so its installer gets the same
# behavioural treatment: run it under pwsh against the same stub docker.
#
# What this does and does NOT prove: PowerShell Core runs cross-platform, so the
# ORDERING (restrict-then-write), the key generation, the .env serialization and
# the per-branch scrub guidance are all executed for real here. The Windows-only
# ACL API (Get-Acl/Set-Acl) cannot execute off Windows — on this path the
# equivalent chmod is exercised instead. The ACL code itself remains unverified
# by CI and is called out as such in the PR.
if command -v pwsh >/dev/null 2>&1; then
  run_install_ps1() {
    local dir="$1" ready="$2" healthcheck="$3" timeout="$4" out="$5"
    mkdir -p "$dir"
    cp "$ROOT_DIR/docker-compose.yml" "$dir/docker-compose.yml"   # skip the fetch
    (
      umask 000
      PATH="$stub_bin:$PATH" \
      FSEVEN_REAL_DOCKER="$REAL_DOCKER" \
      FSEVEN_TEST_BOOTSTRAP_READY="$ready" \
      FSEVEN_TEST_HEALTHCHECK="$healthcheck" \
      FSEVEN_BOOTSTRAP_TIMEOUT_SECS="$timeout" \
      FSEVEN_RELEASE_MANIFEST_URL="file:///nonexistent-fseven-release-manifest.json" \
        pwsh -NoProfile -File "$ROOT_DIR/install.ps1" -InstallDir "$dir" -NoAgent
    ) > "$out" 2>&1
  }

  ps_fresh="$scenario_root/ps-fresh"
  ps_out1="$scenario_root/ps-out-1.txt"
  run_install_ps1 "$ps_fresh" yes no 5 "$ps_out1"
  assert_output_contains "$ps_out1" 'admin@example.test' \
    'install.ps1: bootstrap admin email on the happy path'
  assert_output_contains "$ps_out1" 'docker compose exec controller rm -f /app/model-storage/bootstrap/secrets.env' \
    'PB3: install.ps1 scrub guidance on the bootstrap-ready branch'

  # NOTE: this is a FINAL-mode check and it cannot, on its own, prove PB5 — see the
  # creation-time trace scenario below. Write-SecretFile re-asserts the restriction
  # AFTER writing, so a write-then-restrict regression still ends at 600 and would
  # still print "(verified)" here.
  ps_env_mode="$(file_mode "$ps_fresh/.env")"
  if [[ "$ps_env_mode" != "600" ]]; then
    printf 'PB5: install.ps1 .env is mode %s under umask 000 (expected 600)\n' "$ps_env_mode" >&2
    exit 1
  fi
  printf 'PB5: install.ps1 .env ends at 0600 under a hostile umask 000 (final mode; ordering proven below)\n'

  assert_no_backup_left "$ps_fresh" 'install.ps1 (happy path)'

  if ! grep -q '^CONTROLLER_JWT_PRIVATE_KEY="-----BEGIN PRIVATE KEY-----$' "$ps_fresh/.env"; then
    printf 'PB4: install.ps1 did not provision a multi-line CONTROLLER_JWT_PRIVATE_KEY into .env (Windows still boots on an ephemeral key)\n' >&2
    exit 1
  fi
  ps_key_fingerprint="$(first_pem_body_line "$ps_fresh/.env")"
  if [[ -z "$ps_key_fingerprint" ]]; then
    printf 'PB4: could not read back the key install.ps1 wrote into .env\n' >&2
    exit 1
  fi
  if require_tools 'PB4 install.ps1 key validity' openssl python3; then
    python3 - "$ps_fresh/.env" > "$scenario_root/ps-key.pem" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
m = re.search(r'^CONTROLLER_JWT_PRIVATE_KEY="(.*?)"', text, re.S | re.M)
if not m:
    sys.exit("PB4: no CONTROLLER_JWT_PRIVATE_KEY in .env")
sys.stdout.write(m.group(1).strip() + "\n")
PY
    # install.ps1 cannot call openssl (Windows has none) — it builds the PKCS#8
    # document from the RFC 8410 prefix + 32 CSPRNG bytes. Prove that hand-built
    # DER really is a valid Ed25519 private key, or Windows ships a garbage key.
    if ! openssl pkey -in "$scenario_root/ps-key.pem" -noout -text 2>/dev/null \
         | grep -q 'ED25519 Private-Key'; then
      printf 'PB4: install.ps1 wrote a CONTROLLER_JWT_PRIVATE_KEY that is not a valid Ed25519 key\n' >&2
      exit 1
    fi
    printf 'PB4: install.ps1 mints a valid Ed25519 key without openssl (verified against openssl)\n'
  fi

  # The Windows-written .env must render through Compose exactly like the bash
  # one — this is where a CRLF or BOM in the PowerShell writer would surface.
  assert_env_pem_renders "$ps_fresh" "install.ps1"

  ps_timeout="$scenario_root/ps-timeout"
  ps_out2="$scenario_root/ps-out-2.txt"
  run_install_ps1 "$ps_timeout" no no 2 "$ps_out2"
  assert_output_contains "$ps_out2" 'Bootstrap did not complete within 2 s' \
    'install.ps1: reached the bootstrap-timeout branch'
  assert_output_contains "$ps_out2" 'docker compose exec controller rm -f /app/model-storage/bootstrap/secrets.env' \
    'PB3: install.ps1 scrub guidance on the bootstrap-TIMEOUT branch'

  ps_out3="$scenario_root/ps-out-3.txt"
  run_install_ps1 "$ps_fresh" no yes 5 "$ps_out3"
  assert_output_contains "$ps_out3" 'Existing .env found' \
    'install.ps1: reached the re-run branch'
  assert_output_contains "$ps_out3" 'docker compose exec controller rm -f /app/model-storage/bootstrap/secrets.env' \
    'PB3: install.ps1 scrub guidance on the RE-RUN branch'
  if ! grep -Fqx -- "$ps_key_fingerprint" "$ps_fresh/.env"; then
    printf 'PB4: install.ps1 ROTATED CONTROLLER_JWT_PRIVATE_KEY on re-run (must be preserved)\n' >&2
    exit 1
  fi
  assert_no_backup_left "$ps_fresh" 'install.ps1 (re-run)'
  printf 'PB3: install.ps1 emits scrub guidance on all three branches (verified)\n'

  # ── PB5 (install.ps1): CREATION-TIME proof, not final-mode ─────────────────
  # Everything above is final-state. Final state CANNOT distinguish "restricted
  # before any secret byte was written" from "written at the inherited
  # ACL/umask, then restricted" — both end at 0600, because Write-SecretFile
  # re-asserts the restriction after writing. That blind spot is exactly how the
  # PB5 fix shipped with PB5 re-created inside it: the `.env.pb4.bak` backup was
  # taken with `Copy-Item` (which on Windows gives the NEW file the containing
  # directory's INHERITABLE ACL, not the source file's explicit one) and only
  # restricted afterwards — so a full copy of POSTGRES_PASSWORD,
  # FSEVEN_APP_DB_PASSWORD, ADMIN_API_KEY and CREDENTIAL_ENCRYPTION_KEY was
  # other-user-readable on every fresh Windows install, while this gate stayed
  # green.
  #
  # install.sh gets its creation-time proof from the fetched compose file (never
  # chmod'ed => 0600 only if `umask 077` was in force when it was CREATED).
  # PowerShell has no umask: its guarantee is per-file ORDERING, so it has to be
  # proven AS ordering. Protect-FilePath shells out to `chmod` on this platform
  # (the exact call site the Windows Set-Acl branch replaces), so intercept it and
  # record each file's SIZE at the moment it is restricted. The invariant:
  #
  #     the FIRST restriction of a secret file must happen while it is EMPTY.
  #
  # A non-zero size on a path's first chmod means secret bytes were already on
  # disk, at the permissive inherited mode/ACL, when the restriction was applied.
  # That is PB5 — whatever the final mode says.
  assert_restricted_while_empty() {
    local trace="$1" path="$2" label="$3" first
    first="$(awk -F'|' -v p="$path" '$1 == p { print $2; exit }' "$trace")"
    if [[ -z "$first" ]]; then
      printf 'PB5: install.ps1 NEVER restricted %s (%s) — it keeps the install directory'"'"'s inherited ACL/mode\n' "$path" "$label" >&2
      exit 1
    fi
    if [[ "$first" != "0" ]]; then
      printf 'PB5: install.ps1 restricted %s (%s) only AFTER %s bytes of secrets were already in it.\n' "$path" "$label" "$first" >&2
      printf '     The file existed with secrets in it at the inherited directory ACL (Windows) / ambient umask (POSIX)\n' >&2
      printf '     for the window before the restriction landed. That is the write-then-restrict TOCTOU PB5 names.\n' >&2
      printf '     Create the file EMPTY, restrict it, and only THEN write the secrets (see Write-SecretFile / Copy-SecretFile).\n' >&2
      exit 1
    fi
    printf 'PB5: install.ps1 restricted %s while EMPTY, before any secret byte (verified)\n' "$label"
  }

  # -ProvisionEnvOnly runs the real .env writer AND the real backup path, with no
  # Docker and no network — so this exercises both secret files the installer
  # creates.
  ps_order="$scenario_root/ps-order"
  ps_trace="$scenario_root/ps-chmod-trace.txt"
  : > "$ps_trace"
  (
    umask 000
    PATH="$trace_bin:$PATH" \
    FSEVEN_CHMOD_TRACE="$ps_trace" \
      pwsh -NoProfile -File "$ROOT_DIR/install.ps1" -InstallDir "$ps_order" -ProvisionEnvOnly
  ) > "$scenario_root/ps-out-order.txt" 2>&1

  # Vacuity guard: if the interception never fired, every assertion below would
  # pass trivially on an empty trace.
  if [[ ! -s "$ps_trace" ]]; then
    printf 'PB5: captured NO chmod trace from install.ps1 — the Protect-FilePath interception did not fire, so this proof would be vacuous\n' >&2
    cat "$scenario_root/ps-out-order.txt" >&2
    exit 1
  fi
  if ! grep -Fq "$ps_order/.env.pb4.bak" "$ps_trace"; then
    printf 'PB5: install.ps1 never restricted .env.pb4.bak at all — the backup keeps the install directory'"'"'s inherited ACL (every secret in .env, readable by other local users)\n' >&2
    exit 1
  fi

  assert_restricted_while_empty "$ps_trace" "$ps_order/.env" '.env'
  assert_restricted_while_empty "$ps_trace" "$ps_order/.env.pb4.bak" '.env.pb4.bak (a full copy of every secret in .env)'
  assert_no_backup_left "$ps_order" 'install.ps1 (-ProvisionEnvOnly)'
elif [[ "${FSEVEN_REQUIRE_PWSH:-0}" == "1" ]]; then
  # As with docker: CI sets FSEVEN_REQUIRE_PWSH=1 so the Windows-parity half can
  # never silently no-op. A skipped check is how install.ps1 drifted a whole
  # audit finding behind install.sh in the first place.
  printf 'pwsh is REQUIRED (FSEVEN_REQUIRE_PWSH=1) but not available\n' >&2
  exit 1
else
  printf 'pwsh not available; skipped install.ps1 behaviour scenarios\n'
fi

rm -rf "$scenario_root"

printf 'bootstrap handoff static checks passed\n'
