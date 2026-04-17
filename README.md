# F7 Agent — Download & Install

Pre-built FSEVEN Agent binaries for all supported platforms.

---

## Quick Start (IT Admins)

### 1. Get Your Enrollment Token

In the F7 Controller dashboard, go to **Settings → Enrollment** and create a token. Copy it — you'll need it during install. Tokens are time-limited (typically 24–72 hours) and can be single-use or multi-use.

### 2. Download the Installer

> **Current release: v0.1.0.** At present only the **macOS Apple Silicon** installer
> (`fseven-agent-v0.1.0-aarch64-apple.pkg`) is published in this repository.
> Windows (MSI), macOS Intel, and Linux tarball builds are on the near-term release
> roadmap and will appear under future `v<version>/` directories as the per-platform
> CI pipelines come online (see [Adding a New Release](#adding-a-new-release)).

| Platform | File | Architecture | Status |
|----------|------|-------------|--------|
| **macOS (Apple Silicon)** | `fseven-agent-v{version}-aarch64-apple.pkg` | M1/M2/M3/M4 | ✅ Available in `v0.1.0/` |
| **macOS (Intel)** | `fseven-agent-v{version}-x86_64-apple.pkg` | x86_64 | 🚧 Planned |
| **Windows** | `fseven-agent-v{version}-x86_64.msi` | x86_64 | 🚧 Planned |
| **Linux** | `fseven-agent-v{version}-x86_64-linux.tar.gz` | x86_64 | 🚧 Planned |

Download the latest version from the [`v0.1.0/`](v0.1.0/) directory, or use the download links in your Controller dashboard under **Settings → Enrollment**.

### 3. Install & Enroll

#### macOS

```bash
# Open the PKG and follow prompts, then configure:
sudo tee /etc/fseven/agent-config.toml << 'EOF'
[enrollment]
enrollment_token = "YOUR_TOKEN_HERE"

[controller]
api_url = "https://your-controller.example.com"
EOF

# The agent starts automatically via LaunchDaemon
sudo launchctl load /Library/LaunchDaemons/ai.fseven.agent.plist
```

#### Windows

```powershell
# Silent install with enrollment token and controller URL:
msiexec /i fseven-agent-v0.1.0-x86_64.msi /quiet `
  ENROLLMENT_TOKEN="YOUR_TOKEN_HERE" `
  CONTROLLER_URL="https://your-controller.example.com"
```

Or double-click the MSI and enter the token and controller URL when prompted.

#### Linux

```bash
tar xzf fseven-agent-v0.1.0-x86_64-linux.tar.gz
cd fseven-agent-v0.1.0

# Edit config with your token and controller URL
cat > config/agent-config.toml << 'EOF'
[enrollment]
enrollment_token = "YOUR_TOKEN_HERE"

[controller]
api_url = "https://your-controller.example.com"
EOF

# Install systemd service and start
sudo cp systemd/fseven-agent.service /etc/systemd/system/
sudo cp bin/fseven-agent /usr/local/bin/
sudo mkdir -p /etc/fseven && sudo cp config/agent-config.toml /etc/fseven/
sudo systemctl enable --now fseven-agent
```

### 4. Verify Enrollment

On first run the agent sends an enrollment request to your controller. Once enrolled:
- The device appears in your Controller dashboard under **Devices**
- Credentials are stored securely in the OS keychain (macOS/Windows) or a protected file (Linux)
- The agent begins observing and uploading telemetry automatically

Check agent status:
```bash
# macOS
sudo launchctl list | grep fseven

# Linux
systemctl status fseven-agent

# Windows (PowerShell)
Get-Service fseven-agent
```

### 5. MDM Deployment (Optional)

For managed fleets, bake the enrollment token and controller URL into your MDM configuration profile. The agent enrolls silently with no user interaction. See `fseven-docs/docs/prd/` for MDM integration details.

---

## What the Agent Does

- Observes work patterns via **metadata only**: application names, window titles, context-switch timestamps, AI tool usage
- **Never captures**: keystrokes, screen content, file contents, email/messages, browsing URLs, personal communications
- Runs on-device AI inference — raw observations never leave the machine
- Uploads only aggregated metrics to your controller
- Three deployment modes based on system RAM: Mode 1 — Observe (end-of-day LLM summary), Mode 2 — Analyze (16GB+, continuous LLM summarization), Mode 3 — Interpret (32GB+ GPU, continuous LLM interpretation with vision)

---

## For Developers

### Repository Structure

```
v<version>/
  fseven-agent-v<version>-x86_64.msi              # Windows x86_64
  fseven-agent-v<version>-aarch64-apple.pkg        # macOS Apple Silicon
  fseven-agent-v<version>-x86_64-apple.pkg         # macOS Intel
  fseven-agent-v<version>-x86_64-linux.tar.gz      # Linux x86_64
```

### Controller Integration

The fseven-controller dashboard reads `AGENT_RELEASE_BASE_URL` and
serves download links from this repository. Set:

```env
AGENT_RELEASE_BASE_URL=https://github.com/fseven-ai/public-agent-binaries/raw/main
```

The controller constructs download URLs as:
`{AGENT_RELEASE_BASE_URL}/v{version}/{filename}`

### Adding a New Release

1. Build binaries via the `release.yml` workflow in `fseven-agent`, or locally:
   - macOS: `./installer/macos/build-pkg.sh`
   - Windows: `.\installer\windows\build-msi.ps1`
   - Linux: `./installer/linux/build-tarball.sh`
2. Copy artifacts to `v<version>/` in this repo.
3. Commit and push.

### Automated Releases

The `fseven-agent` repo's `.github/workflows/release.yml` workflow
builds all platforms on tag push and commits artifacts here automatically.
