# Changelog

All notable changes to `public-agent-binaries` are documented in this file. This repository distributes pre-built F7 Agent installers; version entries mirror `fseven-agent` release tags.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Planned

- Linux `.tar.gz` and `.deb` publish plan (Sprint 5 PB-4)
- Windows MSI Authenticode signing once Azure Code Signing cert is provisioned

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
