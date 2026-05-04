# fseven — Install & Binaries

Public distribution point for fseven: install scripts, Docker Compose file,
controller container image index, and agent binaries for all supported platforms.

Source code for the controller and agent is hosted in private repositories;
this repo is the single public surface users interact with.

---

## What do you want to do?

fseven has two pieces: a **controller** (the server that holds data + serves
the dashboard) and an **agent** (runs on each endpoint you want to observe).

| Your situation | Follow |
|---|---|
| Try it on my laptop / small team, self-host everything | [**§1 Community**](#1-community--self-host--pair-a-few-endpoints) |
| Already have a controller running, just install agents on endpoints | [**§2 Install agents**](#2-install-agents-against-an-existing-controller) |
| Roll it out to a managed fleet via MDM / MSI / Jamf | [**§3 Enterprise / MDM**](#3-enterprise--mdm-silent-deployment) |

If you're unsure, start with §1 — it's the fastest path to a working setup.

---

## 1. Community — self-host + pair a few endpoints

The community path runs the controller and agent on the same laptop (or LAN),
and pairs each agent via a rotating 6-digit code shown in the dashboard. No
tokens, no MDM, no DNS — everything runs on `localhost`.

### Step 1 — Install the controller

On the machine that will host the controller (macOS, Linux, or Windows with
Docker Desktop):

```bash
# macOS / Linux
curl -fsSL https://raw.githubusercontent.com/f7-platform/public-agent-binaries/main/install.sh | bash
```

```powershell
# Windows PowerShell 5.1+ or 7+
irm https://raw.githubusercontent.com/f7-platform/public-agent-binaries/main/install.ps1 | iex
```

The installer brings up PostgreSQL + the controller in Docker Compose, then
prints the one-time admin email + password. First run takes about 30 seconds.

The password is also written inside the controller container at
`/app/model-storage/bootstrap/secrets.env` for the installer handoff. The
controller deletes that file after the first successful admin login; if nobody
logs in, it is treated as stale and removed on a later startup after 24 hours.
Save the printed credentials immediately and rotate the password after login.

**Requirements:** Docker Desktop (macOS / Windows) or Docker Engine (Linux)
with Compose v2; loopback port `8080` free.

### Step 2 — Log in + open the pairing page

Open <http://localhost:8080>, log in with the printed credentials, then go to
**Admin → Settings → Connect an agent**.

You'll see a 6-digit pairing code (rotates every 10 minutes) and a QR code.
Keep this page open for the next step.

### Step 3 — Install an agent on the same or another machine

Download the right file from the
[latest release](https://github.com/f7-platform/public-agent-binaries/releases/latest):

| Platform | File |
|---|---|
| macOS Apple Silicon | `fseven-agent-aarch64-apple.pkg` |
| macOS Intel         | `fseven-agent-x86_64-apple.pkg` |
| Windows x86_64      | `fseven-agent-x86_64-windows.msi` |
| Linux x86_64        | `fseven-agent-x86_64-linux.tar.gz` |

Install it normally — double-click the PKG/MSI, or `tar xzf` + run the
included script on Linux. On first launch the agent opens a local browser tab
where you paste:

- **Controller URL** — `http://localhost:8080` if you're on the same machine
  as the controller, otherwise the LAN URL (e.g. `http://192.168.1.5:8080`).
- **Pairing code** — the 6 digits from **Connect an agent**.

Alternatively, scan the QR code from the dashboard with your phone and open
it on the endpoint — the fields pre-fill automatically.

### Step 4 — Verify

The device appears in the dashboard under **Devices** within a few seconds.

Repeat Step 3 for every endpoint you want to enroll. The pairing code keeps
rotating in the background; any valid, unexpired code works.

> **Release trust:** macOS PKGs are built through the agent release workflow
> with Apple signing/notarization verification, and Windows MSI artifacts are
> verified with Authenticode when release signing secrets are configured.
> Published assets also include checksums from the tagged release workflow.

---

## 2. Install agents against an existing controller

If someone on your team has already stood up a controller and given you a
URL, skip §1. You only need:

- the **controller URL** (`http://<host>:8080` on LAN, or the public HTTPS
  URL if your team hosts it externally),
- a way to pair — either a **6-digit code** (they read it off the dashboard
  for you) or an **enrollment token** (for silent install; see §3).

### Interactive pairing (6-digit code)

1. Download the agent binary from the
   [latest release](https://github.com/f7-platform/public-agent-binaries/releases/latest)
   (same table as §1).
2. Install it normally.
3. On first launch the agent opens a local browser tab — paste the controller
   URL and the 6-digit code.
4. The device appears in the controller dashboard under **Devices**.

This is the right path when you're installing one or two agents yourself.
For rolling out to dozens or hundreds of machines, use §3.

---

## 3. Enterprise / MDM (silent deployment)

For managed fleets, pre-seed each endpoint with an **enrollment token** and
the controller URL. The agent enrolls silently with no user interaction — no
browser popup, no pairing code entry.

### Step 1 — Mint an enrollment token

In the controller dashboard: **Admin → Fleet deployment → New token**. Set a
label, max uses, and expiry. The plaintext token is shown **once** — copy it
into your MDM config immediately.

### Step 2 — Pre-seed the token at install time

Replace `YOUR_TOKEN_HERE` with the token you minted and
`https://your-controller.example.com` with your controller's public URL.

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

#### Windows (MSI transform / Intune / SCCM)

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
# edit /etc/fseven/agent-config.toml:
#   enrollment_token    = "YOUR_TOKEN_HERE"
#   controller.api_url  = "https://your-controller.example.com"
sudo cp bin/fseven-agent /usr/local/bin/
sudo cp systemd/fseven-agent.service /etc/systemd/system/
sudo systemctl enable --now fseven-agent
```

The dashboard shows per-platform silent-install snippets with your token and
URL pre-filled under **Admin → Fleet deployment → Download & install**.

---

## File naming

Agent binary filenames are **stable** (no version suffix) so the
`releases/latest/download/<file>` URL always resolves to the current release.
This keeps MDM packages and documentation evergreen.

| Platform | File |
|---|---|
| macOS Apple Silicon | `fseven-agent-aarch64-apple.pkg` |
| macOS Intel         | `fseven-agent-x86_64-apple.pkg` |
| Windows x86_64      | `fseven-agent-x86_64-windows.msi` |
| Linux x86_64        | `fseven-agent-x86_64-linux.tar.gz` |

---

## Release artifacts

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
  "schema_version": 2,
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
  },
  "artifacts": {
    "docker_compose": {
      "url":    "…/docker-compose.yml",
      "sha256": "…"
    },
    "install_sh": {
      "url":    "…/install.sh",
      "sha256": "…"
    },
    "install_ps1": {
      "url":    "…/install.ps1",
      "sha256": "…"
    }
  }
}
```

`install.sh` / `install.ps1` fetch this manifest on first run and pin the
controller image to the matching `vX.Y.Z` tag. They also verify downloaded
compose and agent installer artifacts before use. Override via
`FSEVEN_RELEASE_MANIFEST_URL`; custom compose or agent package URLs must be
paired with `FSEVEN_COMPOSE_SHA256`, `FSEVEN_AGENT_PKG_SHA256`, or
`FSEVEN_AGENT_MSI_SHA256` unless a `.sha256` sidecar is published next to the
artifact.

---

## How releases are produced

Releases in this repo are **fully automated** and produced by two
private-repo workflows:

1. **`fseven-controller`** (`.github/workflows/release.yml`) — triggered by
   pushing a `vX.Y.Z` tag. Builds the controller image, pushes to
   `ghcr.io/f7-platform/public-agent-binaries/controller`, publishes
   `release-manifest.json` + install scripts, and syncs `install.sh` /
   `install.ps1` / `docker-compose.yml` to the `main` branch of this repo.
2. **`fseven-agent`** (`.github/workflows/release.yml`) — triggered by the
   same tag. Builds PKG / MSI / tarball for each platform, renames to
   canonical filenames, and uploads to the same release.

Both workflows idempotently target the same GitHub Release, so order does
not matter.

---

## Installer flags (self-host)

| Flag (sh / ps1) | Default | Purpose |
|---|---|---|
| `--dir <path>` / `-InstallDir <path>` | `./fseven` | Install directory (holds `.env`, `docker-compose.yml`) |
| `--image <ref>` / `-Image <ref>` | `ghcr.io/f7-platform/public-agent-binaries/controller:latest` | Override controller image |
| `--port <n>` / `-Port <n>` | `8080` | Host port |
| `--with-agent` / `-WithAgent` | prompt | Also install the agent on this host (non-interactive opt-in) |
| `--no-agent` / `-NoAgent` | — | Skip the agent-install prompt |

---

## Issues & support

Report issues at <https://github.com/f7-platform/public-agent-binaries/issues>
(this repo). Source-level issues are triaged internally.
