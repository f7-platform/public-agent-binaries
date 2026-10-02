# fseven — Install & Binaries

Public distribution point for fseven: install scripts, Docker Compose file
and controller container image index.

> **The fseven agent is shelved.** The current release publishes no agent
> installer, and the agent download instructions that used to be on this page
> have been removed. Agent files attached to older releases are kept as a
> record only and are no longer maintained. The sections below that describe
> enrolling agents explain how the agent worked; they are not instructions you
> can follow with the current release.

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

> **Shelved.** The agent is shelved and the current release has no agent
> installer, so this step cannot be completed with it. The description below
> is kept so that the pairing page on the dashboard is explained.

When an agent installer was published, it was installed normally and on first
launch opened a local browser tab where you pasted:

- **Controller URL** — `http://localhost:8080` if you're on the same machine
  as the controller, otherwise the LAN URL (e.g. `http://192.168.1.5:8080`).
- **Pairing code** — the 6 digits from **Connect an agent**.

Alternatively, scan the QR code from the dashboard with your phone and open
it on the endpoint — the fields pre-fill automatically.

### Step 4 — Verify

The device appears in the dashboard under **Devices** within a few seconds.

Repeat Step 3 for every endpoint you want to enroll. The pairing code keeps
rotating in the background; any valid, unexpired code works.

> **Release trust:** No release has published `.sha256` sidecar files, and
> the agent entries in `release-manifest.json` carry no checksums. A release
> that has a `SHA256SUMS` asset lists the SHA-256 checksum of each file that
> asset covers; in v0.3.0 those are the controller-side files. Check the asset
> list and the release notes for the specific tag you are using to confirm
> which checksums, signing and notarization steps it has.

---

## 2. Install agents against an existing controller

> **Shelved.** The agent is shelved and the current release has no agent
> installer. This section describes how enrollment against an existing
> controller worked.

If someone on your team has already stood up a controller and given you a
URL, skip §1. You only need:

- the **controller URL** (`http://<host>:8080` on LAN, or the public HTTPS
  URL if your team hosts it externally),
- a way to pair — either a **6-digit code** (they read it off the dashboard
  for you) or an **enrollment token** (for silent install; see §3).

### Interactive pairing (6-digit code)

1. Install the agent. No agent installer is currently published.
2. On first launch the agent opens a local browser tab — paste the controller
   URL and the 6-digit code.
3. The device appears in the controller dashboard under **Devices**.

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

> **Shelved.** The agent is shelved and the current release has no agent
> installer, so the silent-install scripts that used to be here have been
> removed: each one downloaded a file that the current release does not have.

When an agent installer was published, the token and controller URL were
written to `/etc/fseven/enrollment-seed.toml` on macOS, passed as the
`ENROLLMENT_TOKEN` and `CONTROLLER_URL` properties to `msiexec` on Windows,
and set in `/etc/fseven/agent-config.toml` on Linux before the agent service
started.

The dashboard shows per-platform silent-install snippets with your token and
URL pre-filled under **Admin → Fleet deployment → Download & install**.

---

## File naming

Agent installers were attached to releases under stable file names with no
version suffix. The current release has none of these files, so a
`releases/latest/download/<file>` link to any of them does not resolve.

| Platform | File |
|---|---|
| macOS Apple Silicon | `fseven-agent-aarch64-apple.pkg` |
| macOS Intel         | `fseven-agent-x86_64-apple.pkg` |
| Windows x86_64      | `fseven-agent-x86_64-windows.msi` |
| Linux x86_64        | `fseven-agent-x86_64-linux.tar.gz` |

---

## Platform support boundaries

This table describes the platforms the agent was built for before it was
shelved. No agent installer is currently published for any of them.

| Platform | Status | Notes |
|---|---|---|
| macOS Apple Silicon (aarch64) | ✅ Supported | Native |
| macOS Intel (x86_64) | ✅ Supported | Native |
| Windows x86_64 | ✅ Supported | Native |
| Windows ARM64 | ⚠️ Emulation only | x86_64 MSI runs via WOW64 emulation; native build planned |
| Linux x86_64 | ✅ Supported | tar.gz + systemd |
| Linux ARM64 | ❌ Not yet available | Planned |
| Linux GPU / CUDA / ONNX | ❌ Not applicable | The agent does not currently use GPU acceleration |
| Cloud-managed / SaaS controller | ❌ Not yet available | Self-hosted only at this time |

---

A controller release tag (`vX.Y.Z`) produces:

| Artifact | Location |
|---|---|
| Controller container image | `ghcr.io/f7-platform/public-agent-binaries/controller:{vX.Y.Z, latest}` |
| `release-manifest.json`    | GitHub Release assets — machine-readable index |
| `install.sh`, `install.ps1`, `docker-compose.yml` | GitHub Release assets + `main` branch |

A controller tag does not produce agent installers. Agent installers were
attached only by the separate agent release workflow, which runs on tags in
its own repository, and the current release, v0.3.0, has none. The `agent`
entries in `release-manifest.json` name the file each platform would use and
carry no checksums.

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
compose and agent installer artifacts before use, and refuse an artifact for
which no checksum is available. Override via
`FSEVEN_RELEASE_MANIFEST_URL`; custom compose or agent package URLs must be
paired with `FSEVEN_COMPOSE_SHA256`, `FSEVEN_AGENT_PKG_SHA256`, or
`FSEVEN_AGENT_MSI_SHA256` unless a `.sha256` sidecar is published next to the
artifact.

---

## How releases are produced

Releases in this repo are produced by two private-repo workflows, each
triggered by a tag pushed to its own repository:

1. **`fseven-controller`** (`.github/workflows/release.yml`) — triggered by
   pushing a `vX.Y.Z` tag to `fseven-controller`. Builds the controller image, pushes to
   `ghcr.io/f7-platform/public-agent-binaries/controller`, publishes
   `release-manifest.json` + install scripts, and syncs `install.sh` /
   `install.ps1` / `docker-compose.yml` to the `main` branch of this repo.
2. **`fseven-agent`** (`.github/workflows/release.yml`) — triggered by
   pushing a tag to `fseven-agent`, not by the controller tag. It built
   PKG / MSI / tarball for each platform and uploaded them to the release of
   the same name here. The agent is shelved; the last release here that the
   agent workflow published to is v0.2.5-rc3, and `fseven-agent` has no
   v0.3.0 tag.

---

## Installer flags (self-host)

| Flag (sh / ps1) | Default | Purpose |
|---|---|---|
| `--dir <path>` / `-InstallDir <path>` | `./fseven` | Install directory (holds `.env`, `docker-compose.yml`) |
| `--image <ref>` / `-Image <ref>` | `ghcr.io/f7-platform/public-agent-binaries/controller:latest` | Override controller image |
| `--port <n>` / `-Port <n>` | `8080` | Host port |
| `--with-agent` / `-WithAgent` | off | Try to install the agent on this host. The agent is shelved and the current release has no agent installer, so this prints a warning, and the download then fails and is skipped unless you supply an agent file and its checksum (`FSEVEN_AGENT_PKG_URL` + `FSEVEN_AGENT_PKG_SHA256` on macOS, `FSEVEN_AGENT_MSI_URL` + `FSEVEN_AGENT_MSI_SHA256` on Windows) |
| `--no-agent` / `-NoAgent` | — | Skip the agent install; this is now the default, because the installers no longer ask |

---

## Issues & support

Report issues at <https://github.com/f7-platform/public-agent-binaries/issues>
(this repo). Source-level issues are triaged internally.

To report a security vulnerability, see [SECURITY.md](SECURITY.md) — do not
open a public issue for security reports.
