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

# PB3 (Run 34/37, LOW): the controller writes the one-time bootstrap password in
# cleartext to the model-storage volume. The installer cannot stop that write
# (it is controller-side), but it MUST tell the operator to scrub the file after
# the first login instead of leaving it at rest indefinitely.
assert_contains \
  "$ROOT_DIR/install.sh" \
  'docker compose exec controller rm -f %s' \
  'PB3: installer tells the operator to delete the cleartext bootstrap secrets file'

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
else
  printf 'docker compose not available; skipped rendered compose contract\n'
fi

printf 'bootstrap handoff static checks passed\n'
