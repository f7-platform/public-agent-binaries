# fseven — Install & Binaries

Public distribution point for fseven: install scripts, Docker Compose file, controller container image index, and agent binaries for all supported platforms.

Source code for the controller and agent is hosted in private repositories; this repo is the single public surface users interact with.

---

## Quick Start — Controller (self-hosted)

Installs PostgreSQL + the fseven controller with Docker Compose. No secrets required up front; the installer generates a strong `POSTGRES_PASSWORD` and `ADMIN_API_KEY` on first run and writes them to `.env`.

### macOS / Linux

```bash
curl -fsSL https://raw.githubusercontent.com/f7-platform/public-agent-binaries/main/install.sh | bash
```

### Windows (PowerShell 5.1+ or 7+)

```powershell
irm https://raw.githubusercontent.com/f7-platform/public-agent-binaries/main/install.ps1 | iex
```

When the bootstrap banner prints, open http://localhost:8080 and complete setup.

### Flags

| Flag (sh / ps1) | Default | Purpose |
|---|---|---|
| `--dir <path>` / `-InstallDir <path>` | `./fseven` | Install directory (holds `.env`, `docker-compose.yml`) |
| `--image <ref>` / `-Image <ref>` | `ghcr.io/f7-platform/public-agent-binaries/controller:latest` | Override controller image |
| `--port <n>` / `-Port <n>` | `8080` | Host port |
| `--with-agent` / `-WithAgent` | prompt | Also install the agent on this host (non-interactive opt-in) |
| `--no-agent` / `-NoAgent` | — | Skip the agent-install prompt |

### Requirements

- Docker Desktop (macOS / Windows) or Docker Engine (Linux) with Compose v2
- Loopback port 8080 free (or pass `--port`)

---

## Quick Start — Agent (endpoints)

Agents enroll into a running controller via a single-use token minted in the dashboard under **Settings → Enrollment**.

### 1. Get a token

Dashboard → **Settings → Enrollment → New token**. Copy the token value.

### 2. Download + install

Pick your platform from the [latest release](https://github.com/f7-platform/public-agent-binaries/releases/latest):

| Platform | File |
|---|---|
| macOS Apple Silicon | `fseven-agent-aarch64-apple.pkg` |
| macOS Intel         | `fseven-agent-x86_64-apple.pkg` *(pending — see Known Limitations)* |
| Windows x86_64      | `fseven-agent-x86_64-windows.msi` *(pending — see Known Limitations)* |
| Linux x86_64        | `fseven-agent-x86_64-linux.tar.gz` |

File names are stable (no version suffix). The `releases/latest/download/<file>` URL always resolves to the current release.

> **Known limitations (v0.2.0):**
> - **Windows MSI** is temporarily not produced — `libsqlite3-sys` + SQLCipher requires vcpkg-bundled deps on MSVC and is tracked as follow-up work.
> - **macOS Intel (x86_64) PKG** is temporarily not produced — GitHub-hosted `macos-13` runners are queue-starved. Apple Silicon Macs are unaffected.
> - macOS PKGs and Windows MSI ship unsigned in v0.2.0 (no Apple Developer ID / Authenticode cert provisioned); Gatekeeper / SmartScreen will prompt on manual download — the silent install flow in `install.sh` / `install.ps1` is unaffected.

#### macOS

```bash
curl -fsSLo fseven-agent.pkg \
  https://github.com/f7-platform/public-agent-binaries/releases/latest/download/fseven-agent-aarch64-apple.pkg

sudo mkdir -p /etc/fseven
sudo tee /etc/fseven/enrollment-seed.toml >/dev/null <<EOF
enrollment_token = "YOUR_TOKEN_HERE"
controller_url   = "https://your-controller.example.com"
EOF
sudo chmod 0600 /etc/fseven/enrollment-seed.toml

sudo installer -pkg fseven-agent.pkg -target /
```

#### Windows

```powershell
$msi = "$env:TEMP\fseven-agent.msi"
Invoke-WebRequest -UseBasicParsing `
  -Uri  https://github.com/f7-platform/public-agent-binaries/releases/latest/download/fseven-agent-x86_64-windows.msi `
  -OutFile $msi

Start-Process msiexec.exe -Wait -ArgumentList @(
  '/i', $msi, '/quiet', '/norestart',
  'ENROLLMENT_TOKEN=YOUR_TOKEN_HERE',
  'CONTROLLER_URL=https://your-controller.example.com'
)
```

#### Linux

```bash
curl -fsSL \
  https://github.com/f7-platform/public-agent-binaries/releases/latest/download/fseven-agent-x86_64-linux.tar.gz \
  | tar -xz
cd fseven-agent-v*

sudo mkdir -p /etc/fseven
sudo cp config/agent-config.toml /etc/fseven/
# edit /etc/fseven/agent-config.toml to set enrollment_token + controller.api_url
sudo cp bin/fseven-agent /usr/local/bin/
sudo cp systemd/fseven-agent.service /etc/systemd/system/
sudo systemctl enable --now fseven-agent
```

### 3. Verify

The device appears in the controller dashboard under **Devices** within a few seconds.

---

## Release Artifacts

Each release tag (`vX.Y.Z`) produces:

| Artifact | Location |
|---|---|
| Controller container image | `ghcr.io/f7-platform/public-agent-binaries/controller:{vX.Y.Z, latest}` |
| `release-manifest.json`    | GitHub Release assets — machine-readable index |
| `install.sh`, `install.ps1`, `docker-compose.yml` | GitHub Release assets + `main` branch |
| Agent installers (4)       | GitHub Release assets |

### `release-manifest.json` schema

```jsonc
{
  "schema_version": 1,
  "version":        "v0.2.0",
  "released_at":    "2026-04-24T12:34:56Z",
  "controller": {
    "image":        "ghcr.io/f7-platform/public-agent-binaries/controller:v0.2.0",
    "image_latest": "ghcr.io/f7-platform/public-agent-binaries/controller:latest",
    "digest":       "sha256:…"
  },
  "agent": {
    "macos_aarch64":  "…/fseven-agent-aarch64-apple.pkg",
    "macos_x86_64":   "…/fseven-agent-x86_64-apple.pkg",
    "windows_x86_64": "…/fseven-agent-x86_64-windows.msi",
    "linux_x86_64":   "…/fseven-agent-x86_64-linux.tar.gz"
  },
  "install_scripts": {
    "sh":  "https://raw.githubusercontent.com/f7-platform/public-agent-binaries/main/install.sh",
    "ps1": "https://raw.githubusercontent.com/f7-platform/public-agent-binaries/main/install.ps1"
  }
}
```

`install.sh` / `install.ps1` fetch this manifest on first run and pin the controller image to the matching `vX.Y.Z` tag; override via `FSEVEN_RELEASE_MANIFEST_URL`.

---

## MDM / Fleet Deployment

For managed fleets, bake `enrollment_token` and `controller_url` into your MDM configuration profile (macOS) or MSI transform (Windows). The agent enrolls silently with no user interaction.

---

## How Releases Are Produced

Releases in this repo are **fully automated** and produced by two private-repo workflows:

1. **`fseven-controller`** (`.github/workflows/release.yml`) — triggered by pushing a `vX.Y.Z` tag. Builds the controller image, pushes to `ghcr.io/f7-platform/public-agent-binaries/controller`, publishes `release-manifest.json` + install scripts, and syncs `install.sh` / `install.ps1` / `docker-compose.yml` to the `main` branch of this repo.
2. **`fseven-agent`** (`.github/workflows/release.yml`) — triggered by the same tag. Builds PKG / MSI / tarball for each platform, renames to canonical filenames, and uploads to the same release.

Both workflows idempotently target the same GitHub Release, so order does not matter.

---

## Issues & Support

Report issues at https://github.com/f7-platform/public-agent-binaries/issues (this repo). Source-level issues are triaged internally.
