# Changelog

All notable changes to `public-agent-binaries` are documented in this file. This repository distributes pre-built F7 Agent installers; version entries mirror `fseven-agent` release tags.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- `docker-compose.yml` env-doc header and Postgres host-port mapping brought
  back into parity with the `fseven-controller` source-of-truth compose
  (Audit Run 34/35, INF9): documents `CREDENTIAL_ENCRYPTION_KEY`,
  `FSEVEN_LICENSE_PUB_KEY`, `POSTGRES_PORT`, and `POSTGRES_BIND`; adds the
  `POSTGRES_PORT` host-port override (`${POSTGRES_BIND:-127.0.0.1}:${POSTGRES_PORT:-5432}:5432`)
  so hosts where 5432 is taken can remap without editing the file; and declares
  the file a synced mirror of its source of truth. No service topology change.

### Security

- `tests/bootstrap-handoff-static.sh` now asserts the compose `POSTGRES_PASSWORD`
  fail-closed invariant — both statically (the `${POSTGRES_PASSWORD:?…}` form is
  present and the `:-devpassword` weak default is absent) and, when Docker is
  available, at render time (`docker compose config` errors out when the password
  is unset). This is the CI gap that let the PB7 `devpassword` drift reach the
  published artifact undetected (Audit Run 34/35, PB6/PB7/INF2). The test also
  asserts the INF9 `POSTGRES_PORT` parity invariant so future divergent re-syncs
  fail CI here.

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
