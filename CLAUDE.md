# public-agent-binaries

Public distribution repository for the F7 Agent installers and the community
controller image. It holds installer scripts, release documentation, static
contract tests and the published assets' metadata. It has no controller or
agent source and no build system. `.github/copilot-instructions.md` is the
paired Copilot file and shares these rules; keep the two in sync.

## Structure

The `main` branch holds exactly these files. There are no versioned
directories; release binaries are GitHub Release assets and are never
committed to the tree.

- `install.sh`, `install.ps1` — Bootstrap installers (macOS/Linux and Windows)
  that start the community controller stack and enroll the local agent
- `docker-compose.yml`, `.env.example` — The community controller Compose
  profile and its environment template
- `README.md` — Download, checksum-verification and installation guide for IT admins
- `CHANGELOG.md`, `CONTRIBUTING.md`, `SECURITY.md`, `LICENSE` — Release
  history and public repository policy
- `tests/` — Static contract checks for the installers, the Compose file and
  the repository documents
- `.github/workflows/` — The static-checks, issue-label-gate and
  audit-evidence-gate workflows
- `.github/ISSUE_TEMPLATE/` — Issue forms

## Release Shape

- Each release is a GitHub Release on this repository whose assets are the
  four agent installers with canonical filenames, `release-manifest.json`
  (the machine-readable index), and copies of `install.sh`, `install.ps1`
  and `docker-compose.yml`
- The controller image is published to
  `ghcr.io/f7-platform/public-agent-binaries/controller` with a version tag
  and `latest`
- Supported agent assets are macOS Intel, macOS Apple Silicon, Windows x86_64
  and Linux x86_64; Windows ARM64 uses the Windows x86_64 MSI under emulation
  until a native asset exists
- SHA-256 checksums are published as `.sha256` sidecars and/or
  `release-manifest.json` checksum metadata; never edit checksum assets by hand
- macOS notarization and Windows Authenticode signing are per-release trust
  signals that depend on configured release credentials; check the release
  notes before claiming they ran for a specific tag
- Installers and images are built by the private `fseven-agent` and
  `fseven-controller` release workflows, which publish the release assets here
  and sync the installer scripts, Compose file and manifest metadata
- This repo is public-facing — never commit secrets, internal docs,
  pre-release builds or binaries

## Pre-Push CI Gate

This repo has no build system, but before pushing verify:
- No secrets, internal docs, pre-release builds or binaries are included
- Installer/static contract checks pass when scripts, compose or the
  repository documents change:
	`bash tests/bootstrap-handoff-static.sh`
	When Docker Compose is available, that script also renders the community
	profile and checks required environment propagation.

## Build Commands

This repo has no build system — it is a distribution repository. Small
static tests under `tests/` are allowed only for installer, manifest,
compose-file and document contracts; they must not build or modify release
binaries.
