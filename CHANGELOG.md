# Changelog

All notable changes to `public-agent-binaries` are documented in this file. This repository distributes pre-built F7 Agent installers; version entries mirror `fseven-agent` release tags.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `tests/bootstrap-handoff-static.sh` pins the public installer bootstrap
  handoff contract: both install scripts read the canonical
  `/app/model-storage/bootstrap/secrets.env` path, parse admin credentials, and
  fall back to controller readiness on already-bootstrapped reruns.

### Planned

- Windows MSI Authenticode signing once Azure Code Signing cert is provisioned
- macOS PKG Developer ID + notarization (Apple Developer ID cert pending)

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
