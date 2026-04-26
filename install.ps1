# install.ps1 — fseven-controller one-line installer for Windows
#
# Per PROPOSAL-community-deployment §B3. Mirrors install.sh for
# Windows Docker Desktop users.
#
# Usage (from PowerShell 5.1 or 7+):
#   irm https://get.fseven.ai/install.ps1 | iex
#
# Parameters:
#   -InstallDir <path>  Install into <path> instead of .\fseven
#   -Image <ref>        Override controller image
#                        (default: ghcr.io/f7-platform/public-agent-binaries/controller:latest)
#   -Port <int>         Host port for the controller (default 8080)
#   -WithAgent          Also install the agent on this host
#                        (non-interactive opt-in; PR-19 wires the real flow)
#   -NoAgent            Skip the agent-install prompt
#
# Behaviour matches install.sh:
#   1. Verify Docker Desktop is installed + running.
#   2. Generate .env with strong secrets on first run; never regenerate
#      POSTGRES_PASSWORD on re-run.
#   3. Pull + up the `community` profile.
#   4. Wait for the first-run bootstrap banner.
#   5. Print dashboard and setup URLs.

[CmdletBinding()]
param(
    [string]$InstallDir = (Join-Path $PWD 'fseven'),
    [string]$Image      = 'ghcr.io/f7-platform/public-agent-binaries/controller:latest',
    [int]$Port          = 8080,
    [switch]$WithAgent,
    [switch]$NoAgent
)

$ErrorActionPreference = 'Stop'

function Write-Step($msg)  { Write-Host "▸ $msg" -ForegroundColor Cyan }
function Write-Warn2($msg) { Write-Host "! $msg" -ForegroundColor Yellow }
function Write-Fail($msg)  { Write-Host "✘ $msg" -ForegroundColor Red; exit 1 }

function New-Secret {
    # 32 bytes of cryptographic entropy, hex-encoded (64 chars). Uses
    # RNGCryptoServiceProvider via the BCL — available on both
    # Windows PowerShell 5.1 and PowerShell 7+ without extra modules.
    $bytes = New-Object byte[] 32
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    -join ($bytes | ForEach-Object { '{0:x2}' -f $_ })
}

function Get-JsonPath($Object, [string]$Path) {
    if (-not $Object) { return $null }
    $value = $Object
    foreach ($part in $Path.Split('.')) {
        if ($null -eq $value) { return $null }
        if ($value -is [string]) { return $null }
        $prop = $value.PSObject.Properties[$part]
        if (-not $prop) { return $null }
        $value = $prop.Value
    }
    return $value
}

function Get-FileSha256([string]$Path) {
    (Get-FileHash -Algorithm SHA256 -Path $Path).Hash.ToLowerInvariant()
}

function Assert-Sha256([string]$Path, [string]$Expected, [string]$Label) {
    $normalized = $Expected -replace '^sha256:', ''
    $normalized = $normalized.ToLowerInvariant()
    if ($normalized -notmatch '^[0-9a-f]{64}$') {
        throw "Invalid SHA-256 checksum for $Label"
    }
    $actual = Get-FileSha256 $Path
    if ($actual -ne $normalized) {
        throw "$Label checksum mismatch: expected $normalized, got $actual"
    }
    Write-Step "Verified $Label SHA-256: $actual"
}

function Get-SidecarSha256([string]$Url, [string]$Label) {
    try {
        $text = (Invoke-WebRequest -UseBasicParsing -Uri "$Url.sha256").Content
        if ($text -match '([0-9A-Fa-f]{64})') { return $Matches[1] }
    } catch {}
    throw "No SHA-256 checksum available for $Label. Expected $Url.sha256 or release-manifest checksum metadata."
}

# ── Step 1. Preflight ────────────────────────────────────────────────
Write-Step "fseven controller installer — checking prerequisites"

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Fail @'
Docker is not installed. Install Docker Desktop for Windows first:
    https://www.docker.com/products/docker-desktop/
'@
}

try { docker compose version | Out-Null }
catch {
    Write-Fail "Docker Compose v2 is required ('docker compose'). Update Docker Desktop."
}

try { docker info | Out-Null }
catch {
    Write-Fail "Docker daemon is not running. Start Docker Desktop and re-run."
}

New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
Set-Location $InstallDir
Write-Step "Install directory: $InstallDir"

# ── Step 1b. Resolve release manifest (PR-21 / §D2) ──────────────────
$ManifestUrl = if ($env:FSEVEN_RELEASE_MANIFEST_URL) { $env:FSEVEN_RELEASE_MANIFEST_URL } `
               else { 'https://github.com/f7-platform/public-agent-binaries/releases/latest/download/release-manifest.json' }
$script:ReleaseManifest = $null
try {
    $script:ReleaseManifest = (Invoke-WebRequest -UseBasicParsing -Uri $ManifestUrl).Content | ConvertFrom-Json
} catch {
    Write-Warn2 "Could not fetch release manifest from $ManifestUrl; remote artifacts will require explicit checksums."
}
if ($script:ReleaseManifest -and $Image -eq 'ghcr.io/f7-platform/public-agent-binaries/controller:latest') {
    $resolved = Get-JsonPath $script:ReleaseManifest 'controller.image'
    if ($resolved) {
        $Image = [string]$resolved
        Write-Step "Manifest-resolved controller image: $Image"
    }
}

# ── Step 2. .env handling (idempotent per §B6) ───────────────────────
$EnvFile = Join-Path $InstallDir '.env'
$FreshInstall = $false
if (Test-Path $EnvFile) {
    Write-Step "Existing .env found — reusing all values (no secret rotation)"
} else {
    Write-Step "Generating .env with fresh secrets"
    $PostgresPassword        = New-Secret
    $AdminApiKey             = New-Secret
    $CredentialEncryptionKey = New-Secret
    $timestamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    @"
# Generated by install.ps1 on $timestamp
# Do not commit this file. Back it up — POSTGRES_PASSWORD is required
# to decrypt the database and is never regenerated on re-run.
POSTGRES_PASSWORD=$PostgresPassword
ADMIN_API_KEY=$AdminApiKey
CREDENTIAL_ENCRYPTION_KEY=$CredentialEncryptionKey
DEPLOYMENT_MODE=Community
CONTROLLER_IMAGE=$Image
PORT=$Port
"@ | Set-Content -Path $EnvFile -Encoding ASCII
    # Tighten ACL to current user only.
    $acl = Get-Acl $EnvFile
    $acl.SetAccessRuleProtection($true, $false)
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        [System.Security.Principal.WindowsIdentity]::GetCurrent().Name,
        'FullControl', 'Allow')
    $acl.AddAccessRule($rule)
    Set-Acl -Path $EnvFile -AclObject $acl
    $FreshInstall = $true
}

# ── Step 3. Fetch the compose file ───────────────────────────────────
$ComposeFile = Join-Path $InstallDir 'docker-compose.yml'
if (-not (Test-Path $ComposeFile)) {
    $manifestComposeUrl = Get-JsonPath $script:ReleaseManifest 'artifacts.docker_compose.url'
    $manifestComposeSha256 = Get-JsonPath $script:ReleaseManifest 'artifacts.docker_compose.sha256'
    $ComposeUrl = if ($env:FSEVEN_COMPOSE_URL) { $env:FSEVEN_COMPOSE_URL } `
                  elseif ($manifestComposeUrl) { [string]$manifestComposeUrl } `
                  else { 'https://raw.githubusercontent.com/f7-platform/public-agent-binaries/main/docker-compose.yml' }
    $ComposeSha256 = if ($env:FSEVEN_COMPOSE_SHA256) { $env:FSEVEN_COMPOSE_SHA256 } `
                     else { [string]$manifestComposeSha256 }
    Write-Step "Fetching compose file from $ComposeUrl"
    Invoke-WebRequest -UseBasicParsing -Uri $ComposeUrl -OutFile $ComposeFile
    if (-not $ComposeSha256) {
        Write-Fail "No SHA-256 checksum available for downloaded compose file. Use the release manifest artifacts.docker_compose.sha256 field or set FSEVEN_COMPOSE_SHA256."
    }
    Assert-Sha256 $ComposeFile $ComposeSha256 'compose file'
}

# ── Step 3b. Stale-volume guard ──────────────────────────────────────
# See install.sh for rationale: a named pgdata volume from a prior
# install in a same-basename directory will rebind here with the old
# password, poisoning every controller query.
if ($FreshInstall) {
    $ProjectName = (Split-Path $InstallDir -Leaf).ToLower() -replace '[^a-z0-9_-]', '_'
    $StaleVol = "${ProjectName}_pgdata"
    $volProbe = docker volume inspect $StaleVol 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Warning "Docker volume '$StaleVol' already exists from a previous install but this directory has a freshly-generated POSTGRES_PASSWORD. Postgres will refuse the new password and the controller will fail to start."
        if ([Environment]::UserInteractive -and $Host.UI.RawUI) {
            $reply = Read-Host "  Reset the stale volume now? [y/N]"
            if ($reply -match '^(y|Y|yes|YES)$') {
                docker volume rm $StaleVol | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    Write-Step "Removed stale volume $StaleVol"
                } else {
                    throw "Failed to remove $StaleVol — close other docker compose projects using it, then re-run."
                }
            } else {
                throw "Cannot continue with stale volume + fresh .env. Re-run install.ps1 after:`n    docker volume rm $StaleVol"
            }
        } else {
            throw "Non-interactive shell — cannot prompt for volume reset.`nRemove the stale volume explicitly, then re-run:`n    docker volume rm $StaleVol"
        }
    }
}

# ── Step 4. Pull + up ────────────────────────────────────────────────
Write-Step "Pulling latest controller image"
docker compose --profile community pull

Write-Step "Starting services (profile: community)"
docker compose --profile community up -d

# ── Step 5. Wait for bootstrap to finish ─────────────────────────────
# Poll the persisted secrets file (written as the final bootstrap step)
# rather than grepping logs — much more reliable on slow machines.
Write-Step "Waiting for first-run bootstrap (up to 120 s)…"
$deadline = (Get-Date).AddSeconds(120)
$SecretsPath = "/app/model-storage/bootstrap/secrets.env"
$AdminEmail = $null
$AdminPassword = $null
while ((Get-Date) -lt $deadline) {
    $creds = docker compose exec -T controller cat $SecretsPath 2>$null
    if ($LASTEXITCODE -eq 0 -and $creds) {
        $AdminEmail = ($creds -split "`n" | Where-Object { $_ -match '^FSEVEN_BOOTSTRAP_ADMIN_EMAIL=' } |
            ForEach-Object { ($_ -split '=', 2)[1].Trim() } | Select-Object -First 1)
        $AdminPassword = ($creds -split "`n" | Where-Object { $_ -match '^FSEVEN_BOOTSTRAP_ADMIN_PASSWORD=' } |
            ForEach-Object { ($_ -split '=', 2)[1].Trim() } | Select-Object -First 1)
        if ($AdminEmail -and $AdminPassword) { break }
    }
    if (-not $FreshInstall) {
        $logs = docker compose logs --no-color controller 2>$null
        if ($logs -match 'Listening \(healthcheck ready\)') { break }
    }
    Start-Sleep -Seconds 2
}

# ── Step 6. Print URLs + credentials ─────────────────────────────────
$DashboardUrl = "http://localhost:$Port"
Write-Host ""
Write-Host "✓ fseven controller is running at $DashboardUrl" -ForegroundColor Green
Write-Host ""
if ($AdminEmail -and $AdminPassword) {
    Write-Host "  Admin login" -ForegroundColor White
    Write-Host "  Email:     $AdminEmail"
    Write-Host "  Password:  $AdminPassword"
    Write-Host "  Setup:     $DashboardUrl/setup"
    Write-Host ""
    Write-Host "  (credentials also persisted inside the controller at"
    Write-Host "   $SecretsPath — in the model-storage Docker volume)"
    Write-Host ""
    Write-Host "  -> Log in once, then rotate the password under Admin -> Profile." -ForegroundColor Yellow
    Write-Host ""
} elseif (-not $FreshInstall) {
    Write-Host "Dashboard:  $DashboardUrl"
    Write-Host "(Admin credentials were printed on first run; retrieve them with:"
    Write-Host "   docker compose exec controller cat $SecretsPath"
    Write-Host " if you still have the model-storage volume.)"
} else {
    Write-Host "WARNING: Bootstrap did not complete within 120 s." -ForegroundColor Yellow
    Write-Host "Check logs:  docker compose logs controller"
    Write-Host "Once bootstrap finishes, get credentials with:"
    Write-Host "   docker compose exec controller cat $SecretsPath"
}

# ── Step 7. Self-observer chaining (PR-19) ───────────────────────────
# Offer to install the agent on this Windows host. Single-code-path:
# uses the existing admin-token API + msiexec /quiet silent install.

function Install-FsevenAgent {
    param([string]$AdminApiKey, [int]$Port)

    $arch = switch ($env:PROCESSOR_ARCHITECTURE) {
        'AMD64' { 'x86_64' }
        'ARM64' { 'aarch64' }
        default { Write-Warn2 "Unsupported arch $($env:PROCESSOR_ARCHITECTURE) — skipping"; return }
    }

    Write-Step "Fetching default-org id for enrollment-token minting"
    # Prefer the bootstrap-stamped org id from system_state.
    $orgId = (docker compose exec -T postgres `
                psql -U seven -d seven_controller -tAc `
                  "SELECT value->>'org_id' FROM system_state WHERE key = 'bootstrap'" `
              2>$null).Trim()
    if (-not $orgId) {
        $orgId = (docker compose exec -T postgres `
                    psql -U seven -d seven_controller -tAc `
                      "SELECT org_id FROM orgs ORDER BY created_at ASC LIMIT 1" `
                  2>$null).Trim()
    }
    if (-not $orgId) {
        Write-Warn2 "Could not read default org id — skipping agent install."
        return
    }

    # Skip if a device with this hostname is already enrolled (§B6 item 5).
    $hostName = [System.Net.Dns]::GetHostName()
    $escaped  = $hostName.Replace("'", "''")
    $enrolled = (docker compose exec -T postgres `
                   psql -U seven -d seven_controller -tAc `
                     "SELECT 1 FROM devices WHERE hostname = '$escaped' LIMIT 1" `
                 2>$null).Trim()
    if ($enrolled) {
        Write-Step "Device '$hostName' already enrolled — skipping agent install"
        return
    }

    Write-Step "Minting single-use, 1h-TTL enrollment token"
    $mintBody = @{ label = "install.ps1-$hostName"; max_uses = 1; expires_in_hours = 1 } | ConvertTo-Json -Compress
    try {
        $response = Invoke-RestMethod -Method Post `
            -Uri "http://localhost:$Port/admin/api/v1/orgs/$orgId/enrollment-tokens" `
            -Headers @{ 'X-Admin-Key' = $AdminApiKey } `
            -ContentType 'application/json' -Body $mintBody
    } catch {
        Write-Warn2 "Token minting failed: $($_.Exception.Message) — skipping agent install"
        return
    }
    $token = $response.token
    if (-not $token) { Write-Warn2 "Empty token response — skipping"; return }
    $tokenHash = $response.token_hash

    $msiSha256 = if ($env:FSEVEN_AGENT_MSI_SHA256) { $env:FSEVEN_AGENT_MSI_SHA256 } else { $null }
    if ($env:FSEVEN_AGENT_MSI_URL) {
        $msiUrl = $env:FSEVEN_AGENT_MSI_URL
    } else {
        $manifestEntry = Get-JsonPath $script:ReleaseManifest 'agent.windows_x86_64'
        if ($manifestEntry -is [string]) {
            $msiUrl = $manifestEntry
        } elseif ($manifestEntry) {
            $msiUrl = [string](Get-JsonPath $script:ReleaseManifest 'agent.windows_x86_64.url')
            if (-not $msiSha256) { $msiSha256 = [string](Get-JsonPath $script:ReleaseManifest 'agent.windows_x86_64.sha256') }
        } else {
            $msiUrl = "https://github.com/f7-platform/public-agent-binaries/releases/latest/download/fseven-agent-$arch-windows.msi"
        }
    }
    $msiTmp = Join-Path $env:TEMP "fseven-agent-$([guid]::NewGuid()).msi"
    Write-Step "Downloading agent installer: $msiUrl"
    try {
        Invoke-WebRequest -UseBasicParsing -Uri $msiUrl -OutFile $msiTmp
    } catch {
        Write-Warn2 "Agent installer download failed: $($_.Exception.Message)"
        return
    }
    try {
        if (-not $msiSha256) { $msiSha256 = Get-SidecarSha256 $msiUrl 'agent installer' }
        Assert-Sha256 $msiTmp $msiSha256 'agent installer'
        $sig = Get-AuthenticodeSignature -FilePath $msiTmp
        if ($sig.Status -ne 'Valid') {
            throw "Invalid Authenticode signature: status=$($sig.Status) message=$($sig.StatusMessage)"
        }
        Write-Step "Verified Authenticode signature: $($sig.SignerCertificate.Subject)"
    } catch {
        Write-Warn2 "Agent installer verification failed: $($_.Exception.Message) — skipping agent install"
        Remove-Item $msiTmp -ErrorAction SilentlyContinue
        return
    }

    Write-Step "Installing agent silently (requires admin)"
    $msiArgs = @(
        '/i', $msiTmp,
        '/quiet',
        '/norestart',
        "ENROLLMENT_TOKEN=$token",
        "CONTROLLER_URL=http://localhost:$Port"
    )
    $proc = Start-Process msiexec.exe -ArgumentList $msiArgs -Wait -PassThru
    Remove-Item $msiTmp -ErrorAction SilentlyContinue
    if ($proc.ExitCode -ne 0) {
        Write-Warn2 "msiexec exited with code $($proc.ExitCode). See %TEMP%\MSI*.log."
        return
    }

    Write-Step "Waiting for agent to enroll (up to 60 s)…"
    $deadline = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $deadline) {
        $seen = ""
        if ($tokenHash) {
            $seen = (docker compose exec -T postgres `
                       psql -U seven -d seven_controller -tAc `
                         "SELECT 1 FROM enrollment_tokens WHERE token_hash = '$tokenHash' AND use_count > 0" `
                     2>$null).Trim()
        } else {
            $seen = (docker compose exec -T postgres `
                       psql -U seven -d seven_controller -tAc `
                         "SELECT 1 FROM devices WHERE hostname = '$escaped' LIMIT 1" `
                     2>$null).Trim()
        }
        if ($seen) {
            Write-Host ""
            Write-Host "✓ Agent enrolled: $hostName" -ForegroundColor Green
            return
        }
        Start-Sleep -Seconds 2
    }
    Write-Warn2 "Agent did not enroll within 60 s. Check the Windows Service 'FsevenAgent' and Event Viewer."
}

# Decide whether to run the agent install.
$shouldInstall = $false
if ($WithAgent)     { $shouldInstall = $true }
elseif ($NoAgent)   { $shouldInstall = $false }
elseif ([Environment]::UserInteractive -and [Console]::In.Peek -and -not [Console]::IsInputRedirected) {
    $reply = Read-Host 'Install the agent on this machine too? [Y/n]'
    if ($reply -eq '' -or $reply -match '^[Yy]') { $shouldInstall = $true }
}
if ($shouldInstall) {
    # Re-read the freshly-generated ADMIN_API_KEY from .env (important
    # on re-runs where we reused the existing file).
    $envText = Get-Content $EnvFile -Raw
    if ($envText -match 'ADMIN_API_KEY=(\S+)') {
        Install-FsevenAgent -AdminApiKey $Matches[1] -Port $Port
    } else {
        Write-Warn2 "ADMIN_API_KEY not found in .env — cannot mint token"
    }
}
