# GitHub Copilot Instructions — public-agent-binaries

See [`CLAUDE.md`](../CLAUDE.md) for the authoritative repo-level contributor guide — Copilot and Claude share the same rules.

## Quick Rules

1. **Public distribution only.** This repo has installer scripts, release docs,
	static contract tests, and published assets; it has NO controller or agent
	source build system.
2. **Never commit secrets.** No credentials, no pre-release builds, no internal docs.
3. **Release shape:** current releases use GitHub Release assets with canonical
   filenames plus `release-manifest.json`; do not describe or recreate the old
   versioned directory layout.
4. **Checksums:** SHA-256 checksums are published as `.sha256` sidecars and/or
   release-manifest checksum metadata. Do not edit checksum assets manually.
5. **Signatures:** macOS notarization and Windows Authenticode signing are
   per-release trust signals that depend on configured release credentials;
   check the release notes before claiming they ran for a specific tag.
6. **Platform support:** supported agent assets are macOS Intel, macOS Apple
   Silicon, Windows x86_64, and Linux x86_64. Windows ARM64 uses the Windows
   x86_64 MSI under emulation until a native asset exists.
7. **Static tests are allowed for installer/compose/doc contracts only.** Run
   `bash tests/bootstrap-handoff-static.sh` after changing `install.sh`,
   `install.ps1`, `docker-compose.yml`, `README.md`, `CHANGELOG.md`, or this
   instruction file; it renders the community Compose profile when Docker
   Compose is available.

## Release Flow (not done here)

Controller images and agent installers are produced by private `fseven-controller`
and `fseven-agent` release workflows. They land here as GitHub Release assets and
sync `install.sh`, `install.ps1`, `docker-compose.yml`, and `release-manifest.json`
metadata. Humans should never `git add` a binary directly.

## What Copilot Should NOT Do

- Generate, modify, or rebuild binaries.
- Suggest adding a CI or build script.
- Edit checksum assets manually.
- Reference non-existent platforms (e.g., arm32, FreeBSD, native Windows ARM64)
	as supported.
