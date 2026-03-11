# public-agent-binaries

Pre-built FSEVEN Agent binaries for all supported platforms.

## Structure

```
v<version>/
  fseven-agent-v<version>-x86_64.msi              # Windows x86_64
  fseven-agent-v<version>-aarch64-apple.pkg        # macOS Apple Silicon
  fseven-agent-v<version>-x86_64-apple.pkg         # macOS Intel
  fseven-agent-v<version>-x86_64-linux.tar.gz      # Linux x86_64
```

## Usage

The fseven-controller dashboard reads `AGENT_RELEASE_BASE_URL` and
serves download links from this repository. Set:

```env
AGENT_RELEASE_BASE_URL=https://github.com/fseven-ai/public-agent-binaries/raw/main
```

The controller constructs download URLs as:
`{AGENT_RELEASE_BASE_URL}/v{version}/{filename}`

## Adding a New Release

1. Build binaries via the `release.yml` workflow in `fseven-agent`, or locally:
   - macOS: `./installer/macos/build-pkg.sh`
   - Windows: `.\installer\windows\build-msi.ps1`
   - Linux: `./installer/linux/build-tarball.sh`
2. Copy artifacts to `v<version>/` in this repo.
3. Commit and push.

## Automated Releases

The `fseven-agent` repo's `.github/workflows/release.yml` workflow
builds all platforms on tag push and commits artifacts here automatically.
