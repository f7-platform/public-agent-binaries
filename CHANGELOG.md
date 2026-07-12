# Changelog

All notable changes to `public-agent-binaries` are documented in this file. This repository distributes pre-built F7 Agent installers; version entries mirror `fseven-agent` release tags.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Security

- **(Audit Run 34/36, INF5/PB9):** the published `docker-compose.yml` no longer
  hardcodes `OPENFGA_PLAYGROUND_ENABLED: "true"`. The OpenFGA playground is an
  authorization-model *editing* UI and must never ship enabled; the controller
  source-of-truth compose had already defaulted it off, but the published mirror
  retained the hardcoded `true`, so any operator running `--profile prod` (or
  `--profile dev`) started the model editor enabled — network-reachable if
  `OPENFGA_BIND` was widened from its `127.0.0.1` default. The mirror now uses
  the secure-by-default `"${OPENFGA_PLAYGROUND_ENABLED:-false}"` form (explicit
  opt-in preserved for local dev), and `tests/bootstrap-handoff-static.sh`
  asserts both the static form and the *rendered* `prod`-profile value so the
  drift cannot re-enter undetected. This entry closes the CHANGELOG omission
  tracked as PB11 (Audit Run 37) — the fix shipped without being recorded here.
- **(Audit Run 34/35/36, PB6):** `tests/bootstrap-handoff-static.sh` gained a
  consolidated post-CD10 compose-parity completeness block. This static gate is
  the only automated check that catches compose drift between releases, and its
  coverage gap is how PB8 (owner-role serving credentials) and PB9 (hardcoded-true
  playground) both reached the published artifact undetected.
- **(Audit Run 37, PB4 — Windows parity):** `install.ps1` now provisions the same
  **persistent** Ed25519 JWT signing key that `install.sh` does. The Run-34/36 fix
  landed on `install.sh` only and `install.ps1` was never touched, so *every
  Windows community install still booted the controller on a self-generated
  **ephemeral** signing key* — the exact defect PB4 names — while the entry below
  claimed the finding was fixed. It was not, on Windows. Windows cannot shell out
  to `openssl` (it is not present) and neither .NET Framework 4.x (PowerShell 5.1)
  nor .NET 8 exposes an Ed25519 API, so `install.ps1` constructs the PKCS#8
  document directly from the fixed RFC 8410 §7 prefix plus 32 CSPRNG bytes; the
  contract tests feed the result to `openssl pkey` to prove it really is a valid
  Ed25519 private key.
- **(Audit Run 37, PB4 — evidence):** the behaviour the whole PB4 fix rests on —
  a multi-line Ed25519 PEM surviving Compose v2's dotenv parser — was **never
  tested**. Every PB4 assertion was a `grep` for source text in `install.sh`, and
  the "rendered compose" half of the gate never rendered a PEM at all, so a
  parser mismatch would have shipped a broken key to every self-hoster silently.
  `tests/bootstrap-handoff-static.sh` now takes the `.env` each installer
  *actually writes*, renders it with the real `docker compose`, reads
  `CONTROLLER_JWT_PRIVATE_KEY` back out of the controller's container environment,
  and requires it to be byte-for-byte the key on disk, still multi-line, and still
  parseable by `openssl`.
- **(Audit Run 34/36/37, PB4):** `install.sh` provisions a **persistent** Ed25519
  JWT signing key (`CONTROLLER_JWT_PRIVATE_KEY`) into `.env` (0600) instead
  of leaving the controller to generate its own. On the published controller
  image the self-generated key is *ephemeral* — the controller logs
  `generating ephemeral key (tokens won't survive restart)` — so every
  `docker compose restart` or host reboot invalidated every outstanding agent
  bearer token. The historical blocker (a multi-line Ed25519 PEM "cannot be
  represented in a compose env-file") does not hold: Compose v2's dotenv parser
  accepts multi-line double-quoted values and renders them as a YAML block
  scalar. Both installers **verify** the key renders through
  `docker compose config` before keeping it and restore the previous `.env` if
  it does not, so a compose-parser gap degrades to the previous behaviour rather
  than breaking the install. An existing `CONTROLLER_JWT_PRIVATE_KEY` is never
  rotated. Scope note: admin dashboard sessions use an opaque DB-backed
  `fseven_session` cookie and were never affected by the ephemeral key — the
  blast radius was agent tokens only (the Run-34 description overstated it).
- **(Audit Run 37, PB5 — the `.env` window):** the Run-34 fix closed the
  create-then-`chmod` race on the agent enrollment seed but left it **wide open on
  `.env`**, which by then held `POSTGRES_PASSWORD`, `FSEVEN_APP_DB_PASSWORD`,
  `ADMIN_API_KEY` and `CREDENTIAL_ENCRYPTION_KEY` (and, after the PB4 fix, the JWT
  private key). `install.sh` wrote `.env` with `cat >` at the **ambient umask**
  (typically 0644) and only `chmod 600`-ed it afterwards, so on a multi-user host
  all four secrets were world-readable in between; `install.ps1` did the same with
  `Set-Content` at the inherited directory ACL. `install.sh` now sets `umask 077`
  before it creates any file, and `install.ps1` creates `.env` empty, restricts it
  to the current user, and only then writes the secrets into it. The contract
  tests run both installers under a hostile `umask 000` and assert the resulting
  files are 0600.
- **(Audit Run 34/37, PB5):** the agent enrollment seed
  (`/etc/fseven/enrollment-seed.toml`, single-use 1h-TTL token) is *created*
  mode-0600 (`install -m 0600 /dev/null`) before the token is written into it.
  The previous create-at-umask-then-`chmod` sequence left the token briefly
  world-readable between the write and the `chmod`.
- **(Audit Run 34/37, PB3):** both installers now tell the operator to delete the
  controller's one-time bootstrap credentials file
  (`/app/model-storage/bootstrap/secrets.env`), which is written in cleartext into
  the `model-storage` volume, **on every branch that can leave that file on disk** —
  the successful-bootstrap path, the re-run path, and the bootstrap-timeout path.
  The Run-34 fix printed the guidance only on the happy path, while the re-run and
  timeout branches went on telling the operator how to *reveal* the password and
  never to delete it, and `install.ps1` carried no scrub guidance at all — so the
  previous unqualified claim that "the installer now tells the operator to delete
  the file" was untrue for Windows and for two of three branches on Linux/macOS.
  The write itself is controller-side and remains outside this repository; newer
  controller builds delete the file automatically on the first admin login, but
  the currently published image predates that change.
- **CRITICAL (Audit Run 36, PB8):** synced the CD10 RLS serving-role cutover into
  the published distribution artifacts. The published `docker-compose.yml`
  controller `DATABASE_URL` now connects as the least-privilege `fseven_app` role
  with a fail-closed password (`postgres://fseven_app:${FSEVEN_APP_DB_PASSWORD:?}@…`),
  a distinct `DATABASE_ADMIN_URL` retains the owner role `seven` for
  migrations/bootstrap, and the new `FSEVEN_APP_DB_PASSWORD` env is propagated —
  matching the `fseven-controller` source-of-truth compose. Previously the
  published serving `DATABASE_URL` used the owner role `seven`
  (`BYPASSRLS`) with an empty-password fallback, so every `curl install.sh | bash`
  community deploy collapsed `DATABASE_URL == DATABASE_ADMIN_URL` and silently
  booted on the controller's legacy single-role owner path — bypassing all CD10
  row-level-security enforcement (`FORCE RLS`, the per-request `app.current_org_id`
  GUC, and the `fseven_app` role isolation). `install.sh` and `install.ps1` now
  generate `FSEVEN_APP_DB_PASSWORD` on fresh installs (chmod 600) and backfill it
  on existing `.env` files that predate the cutover (without rotating
  `POSTGRES_PASSWORD`). `.env.example` carries a throwaway value for local dev.
- `tests/bootstrap-handoff-static.sh` now asserts the PB8 invariants so the
  owner-role regression cannot recur silently: the serving `DATABASE_URL` uses the
  `fseven_app` role (fail-closed) and never the owner role; `DATABASE_ADMIN_URL`
  keeps the owner role distinct; `FSEVEN_APP_DB_PASSWORD` is propagated to the
  controller and generated/backfilled by both installers; and — when Docker is
  available — the rendered compose fails closed when `FSEVEN_APP_DB_PASSWORD` is
  unset and resolves the serving role to `fseven_app` (not `seven`).
- `tests/bootstrap-handoff-static.sh` now asserts the compose `POSTGRES_PASSWORD`
  fail-closed invariant — both statically (the `${POSTGRES_PASSWORD:?…}` form is
  present and the `:-devpassword` weak default is absent) and, when Docker is
  available, at render time (`docker compose config` errors out when the password
  is unset). This is the CI gap that let the PB7 `devpassword` drift reach the
  published artifact undetected (Audit Run 34/35, PB6/PB7/INF2). The test also
  asserts the INF9 `POSTGRES_PORT` parity invariant so future divergent re-syncs
  fail CI here.

### Changed

- `docker-compose.yml` env-doc header and Postgres host-port mapping brought
  back into parity with the `fseven-controller` source-of-truth compose
  (Audit Run 34/35, INF9): documents `CREDENTIAL_ENCRYPTION_KEY`,
  `FSEVEN_LICENSE_PUB_KEY`, `POSTGRES_PORT`, and `POSTGRES_BIND`; adds the
  `POSTGRES_PORT` host-port override (`${POSTGRES_BIND:-127.0.0.1}:${POSTGRES_PORT:-5432}:5432`)
  so hosts where 5432 is taken can remap without editing the file; and declares
  the file a synced mirror of its source of truth. No service topology change.

### Added

- `tests/bootstrap-handoff-static.sh` pins the public installer bootstrap
  handoff contract: both install scripts read the canonical
  `/app/model-storage/bootstrap/secrets.env` path, parse admin credentials, and
  fall back to controller readiness on already-bootstrapped reruns.
- PowerShell reruns now reuse an existing `.env` `PORT` for dashboard output,
  token minting, and local agent installer `CONTROLLER_URL`; Windows ARM64
  agent fallback now uses the documented x86_64 MSI emulation path.
- Manual Enterprise/MDM install snippets now verify downloaded agent assets with
  SHA-256 sidecars before installation; macOS snippets also run
  `pkgutil --check-signature`, and Windows snippets require valid Authenticode
  status.
- Static README checks now pin manual checksum/signature verification commands.

### Release Trust

- Release trust is per tag: published assets include SHA-256 `.sha256` sidecars
  and manifest checksum metadata, while macOS notarization and Windows
  Authenticode signatures are present only when release signing credentials are
  active for that tag. Release notes should say which signing and notarization
  steps ran for each release.

### Planned

- Make Windows Authenticode signing and macOS notarization mandatory in release
  CI once the required certificates are provisioned.

## [0.2.0] — 2026-04-24

### Added

- Controller container image at `ghcr.io/f7-platform/public-agent-binaries/controller:v0.2.0` and `:latest` (multi-arch `linux/amd64` + `linux/arm64`)
- `docker-compose.yml`, `install.sh`, `install.ps1`, `env-required.json`, `release-manifest.json` published as Release assets
- Agent binaries for all four platforms:
  - `fseven-agent-aarch64-apple.pkg` (Apple Silicon)
  - `fseven-agent-x86_64-apple.pkg` (Intel Mac)
  - `fseven-agent-x86_64-windows.msi` (Windows)
  - `fseven-agent-x86_64-linux.tar.gz` (Linux)

### Changed

- Agent + controller releases now auto-publish via GitHub Actions to this repo; no manual drops.
- Agent binary filenames dropped the version suffix — canonical names are stable across releases (older binaries remain on historical Releases).

### Infrastructure

- Windows MSI now builds OpenSSL from source via `rusqlite` `bundled-sqlcipher-vendored-openssl` feature + NASM toolchain.
- macOS Intel PKG cross-compiled on Apple Silicon runners to avoid `macos-13` queue starvation.
- Controller image built on native `ubuntu-latest` + `ubuntu-24.04-arm` runners (no QEMU emulation).

## [0.1.0] — 2024-12

### Added

- macOS `.pkg` binaries — x86_64 and aarch64, Apple Developer ID signed
- Windows `.msi` binary — x86_64, WiX-built (not yet Authenticode signed)
- Linux `x86_64-linux.tar.gz` — static musl build
- SHA-256 checksums (`SHA256SUMS`) alongside each artifact
- Ed25519 signatures verified at agent self-update time via key compiled into the agent binary

### Infrastructure

- Release workflow at `fseven-agent/.github/workflows/release.yml` auto-publishes via `BINARIES_DEPLOY_KEY` secret.

---

## Versioning Policy

- Version bumps originate in `fseven-agent` release tags.
- This repo only ever receives binaries; humans should not commit directly.
- For historical releases, see the GitHub Releases page at `github.com/fseven-ai/fseven-agent`.
