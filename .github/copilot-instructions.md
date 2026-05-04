# GitHub Copilot Instructions — public-agent-binaries

See [`CLAUDE.md`](../CLAUDE.md) for the authoritative repo-level contributor guide — Copilot and Claude share the same rules.

## Quick Rules

1. **Binary distribution only.** This repo has NO build system and NO source code.
2. **Never commit secrets.** No credentials, no pre-release builds, no internal docs.
3. **Directory structure:** `v{version}/{platform}/{artifact}` — e.g. `v0.1.0/macos/F7Agent-0.1.0.pkg`.
4. **Checksums:** SHA-256 checksums are published as `SHA256SUMS` next to the binaries.
5. **Signatures:** All binaries are Ed25519-signed by `fseven-agent` release CI. The agent verifies these at self-update time.
6. **Static tests are allowed for installer/compose contracts only.** Run `bash tests/bootstrap-handoff-static.sh` after changing `install.sh`, `install.ps1`, or `docker-compose.yml`; it renders the community Compose profile when Docker Compose is available.

## Release Flow (not done here)

Binaries are built and signed in `fseven-agent`'s GitHub Actions release workflow. They land in this repo via the `publish-to-public-binaries` job. Humans should never `git add` a binary directly.

## What Copilot Should NOT Do

- Generate, modify, or rebuild binaries.
- Suggest adding a CI or build script.
- Edit `SHA256SUMS` manually.
- Reference non-existent platforms (e.g., arm32, FreeBSD) — supported set is macOS (Intel + Apple Silicon), Windows x64, Linux x64.
