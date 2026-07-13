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
#   -ProvisionEnvOnly   Write (or top up) the .env — including the persistent
#                        Ed25519 JWT signing key — then exit WITHOUT touching
#                        Docker. Use this to pre-provision an install directory
#                        offline / in an air-gapped staging step. The installer
#                        contract tests also use it to exercise the real .env
#                        writer.
#
# Behaviour matches install.sh:
#   1. Verify Docker Desktop is installed + running.
#   2. Generate .env with strong secrets on first run; never regenerate
#      POSTGRES_PASSWORD on re-run.
#   3. Pull + up the `community` profile.
#   4. Wait for the first-run bootstrap banner.
#   5. Print dashboard and setup URLs.
#
# Environment:
#   FSEVEN_BOOTSTRAP_TIMEOUT_SECS  How long to wait for first-run bootstrap
#                                  (default 120).

[CmdletBinding()]
param(
    [string]$InstallDir = (Join-Path $PWD 'fseven'),
    [string]$Image      = 'ghcr.io/f7-platform/public-agent-binaries/controller:latest',
    [int]$Port          = 8080,
    [switch]$WithAgent,
    [switch]$NoAgent,
    [switch]$ProvisionEnvOnly
)

$ErrorActionPreference = 'Stop'

# PowerShell 5.1 has no $IsWindows automatic variable (it is Windows-only by
# definition); PowerShell 6+ does. Resolve once so the ACL / chmod split below
# works on both, and so the installer's own contract tests can drive the .env
# writer under pwsh on Linux.
$script:OnWindows = $true
if (Test-Path Variable:\IsWindows) { $script:OnWindows = [bool](Get-Variable -Name IsWindows -ValueOnly) }

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

function New-Ed25519PrivateKeyPem {
    # PB4 (Audit Run 34/37): mint the PERSISTENT Ed25519 JWT signing key that
    # install.sh gets from `openssl genpkey -algorithm ed25519`.
    #
    # We cannot call openssl here (it is not part of a Windows install, and
    # Docker Desktop does not put one on PATH), and neither .NET Framework 4.x
    # (Windows PowerShell 5.1) nor .NET 8 exposes an Ed25519 API. So build the
    # PKCS#8 document directly: an Ed25519 private key is a FIXED 16-byte DER
    # prefix followed by the 32-byte seed (RFC 8410 §7), and the seed is just
    # CSPRNG bytes:
    #
    #   30 2e            SEQUENCE (46 bytes)          -- OneAsymmetricKey
    #     02 01 00       INTEGER 0                    -- version v1
    #     30 05          SEQUENCE (5 bytes)           -- AlgorithmIdentifier
    #       06 03 2b6570 OID 1.3.101.112              -- id-Ed25519
    #     04 22          OCTET STRING (34 bytes)      -- privateKey
    #       04 20        OCTET STRING (32 bytes)      -- CurvePrivateKey
    #         <32 bytes> the seed
    #
    # The bytes below are that prefix, verified byte-for-byte against keys
    # emitted by `openssl genpkey -algorithm ed25519`; openssl parses the result
    # as a valid ED25519 private key. The installer contract tests assert exactly
    # that (they run this function and feed its output to `openssl pkey`), so a
    # botched DER header cannot ship silently.
    $prefix = [byte[]]@(
        0x30, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06,
        0x03, 0x2b, 0x65, 0x70, 0x04, 0x22, 0x04, 0x20
    )
    $seed = New-Object byte[] 32
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($seed)
    $der = New-Object byte[] ($prefix.Length + $seed.Length)
    [Array]::Copy($prefix, 0, $der, 0, $prefix.Length)
    [Array]::Copy($seed, 0, $der, $prefix.Length, $seed.Length)
    $b64 = [Convert]::ToBase64String($der)
    # 64 base64 chars per line, matching openssl's PEM line wrapping.
    $wrapped = ($b64 -split '(.{64})' | Where-Object { $_ }) -join "`n"
    return "-----BEGIN PRIVATE KEY-----`n$wrapped`n-----END PRIVATE KEY-----"
}

function Protect-FilePath([string]$Path) {
    # PB5 (Audit Run 34/37): restrict a file to the current user ONLY.
    # Called on an EMPTY file BEFORE any secret is written into it — writing
    # first and tightening afterwards leaves every secret in the file readable
    # by other local users for the window in between.
    if ($script:OnWindows) {
        $acl = Get-Acl $Path
        $acl.SetAccessRuleProtection($true, $false)   # disable inheritance, drop inherited ACEs
        # Drop every ACE that came from the parent directory (Users, Authenticated
        # Users, ...) so only the rule we add below survives.
        foreach ($ace in @($acl.Access)) { [void]$acl.RemoveAccessRule($ace) }
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            [System.Security.Principal.WindowsIdentity]::GetCurrent().Name,
            'FullControl', 'Allow')
        $acl.AddAccessRule($rule)
        Set-Acl -Path $Path -AclObject $acl
    } else {
        & chmod 600 $Path
    }
}

function Write-SecretFile([string]$Path, [string]$Content) {
    # Create the file EMPTY, lock it down, and only then write the secrets into
    # it (see Protect-FilePath). Written with LF line endings and no BOM: the
    # file is parsed by Compose v2's dotenv parser and `source`d by install.sh's
    # re-run path, and a UTF-8 BOM would corrupt the first key name.
    if (-not (Test-Path $Path)) {
        New-Item -ItemType File -Path $Path -Force | Out-Null
    }
    Protect-FilePath $Path
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
    # Re-assert: a pre-existing .env left world-readable by an older installer
    # is tightened here too (New-Item above is a no-op for it).
    Protect-FilePath $Path
}

function Add-SecretLines([string]$Path, [string]$Content) {
    # Append secrets to .env, preserving LF endings.
    #
    # PB5: restrict BEFORE the append, not after. This used to be
    # AppendAllText-then-Protect-FilePath, which was safe only *by assumption* —
    # "the .env is already restricted". That assumption does not hold on the
    # UPGRADE path (:372 CREDENTIAL_ENCRYPTION_KEY, :389 FSEVEN_APP_DB_PASSWORD),
    # which appends to a `.env` written by an OLDER installer — i.e. one created
    # before the PB5 fix, at the install directory's inherited ACL. Appending a
    # freshly-minted secret to a world-readable file and tightening it afterwards
    # is the write-then-restrict TOCTOU PB5 names, re-created on the upgrade path.
    # Restricting first is correct on every path and costs one Set-Acl/chmod.
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::AppendAllText($Path, $Content, $utf8NoBom)
    Protect-FilePath $Path
}

function Copy-SecretFile([string]$Source, [string]$Destination) {
    # PB5 (Audit Run 37): copy a file that CONTAINS SECRETS without ever exposing
    # them.
    #
    # `Copy-Item` must NOT be used for this. The destination is a NEW file, and
    # Windows gives a new file the INHERITABLE ACL of the CONTAINING DIRECTORY —
    # it does not carry over the source file's explicit ACL. $InstallDir is created
    # with a plain `New-Item -ItemType Directory` (Step 1), so it inherits from its
    # parent, which normally grants read to other local principals. A `Copy-Item`
    # of .env therefore lands POSTGRES_PASSWORD, FSEVEN_APP_DB_PASSWORD,
    # ADMIN_API_KEY, CREDENTIAL_ENCRYPTION_KEY — and the JWT PEM on a re-run — on
    # disk readable by other local users for the whole window before Set-Acl runs.
    # That is the exact write-then-restrict TOCTOU that PB5 names, re-created on
    # the backup instead of on .env.
    #
    # So: create the destination EMPTY, restrict it, and only then stream the bytes
    # in — the same restrict-before-write order as Write-SecretFile.
    #
    # Bytes, never text: this is a rollback copy of the operator's real .env, so it
    # must be byte-for-byte and must not go through an encoding round-trip
    # (Get-Content/Set-Content would re-encode it, and on Windows PowerShell 5.1
    # would mangle any non-ASCII byte an operator had put in the file).
    if (Test-Path $Destination) { Remove-Item $Destination -Force }
    New-Item -ItemType File -Path $Destination -Force | Out-Null
    Protect-FilePath $Destination
    [System.IO.File]::WriteAllBytes($Destination, [System.IO.File]::ReadAllBytes($Source))
}

function Add-PersistentJwtKey {
    # PB4: provision CONTROLLER_JWT_PRIVATE_KEY into .env if (and only if) it is
    # absent — an existing key is NEVER rotated, same contract as
    # POSTGRES_PASSWORD, because rotating it invalidates every outstanding agent
    # bearer token.
    #
    # Without this key the community controller falls back to a signing key it
    # generates itself, and on the published image (<= v0.2.2) that key is
    # EPHEMERAL: every `docker compose restart` / host reboot mints a new one and
    # invalidates every agent bearer token. install.sh has provisioned this key
    # since Run 34; install.ps1 did NOT, so until now every Windows community
    # install still booted on an ephemeral key. This closes that parity gap.
    param(
        [string]$EnvFile,
        [switch]$VerifyRender
    )

    $envText = Get-Content $EnvFile -Raw
    if ($envText -match '(?m)^CONTROLLER_JWT_PRIVATE_KEY=') { return }

    $pem = New-Ed25519PrivateKeyPem
    if ($pem -notmatch 'BEGIN PRIVATE KEY') {
        Write-Warn2 "Could not generate an Ed25519 key — skipping persistent JWT key (PB4)."
        return
    }
    $timestamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $backup = "$EnvFile.pb4.bak"

    # The `try` MUST open BEFORE the copy, not after it. Copy-SecretFile creates the
    # backup file and can throw part-way through (a Set-Acl failure, an IO error mid
    # WriteAllBytes) — with the copy outside the try, such a throw left a partial or
    # complete plaintext copy of every secret in .env on disk with no cleanup at all,
    # which is the leak the `finally` exists to prevent. install.sh deliberately arms
    # its trap BEFORE the `cp` for exactly this reason (install.sh :383-390); this is
    # the PowerShell equivalent, and without it the claimed parity did not hold.
    try {
        # Restricted BEFORE the secrets land in it — see Copy-SecretFile. (`Copy-Item`
        # here is what re-created PB5 on Windows: it gave the backup the install
        # directory's inheritable ACL, so every secret in .env was other-user-readable
        # until the following Set-Acl.)
        Copy-SecretFile $EnvFile $backup

        # Multi-line double-quoted value: Compose v2's dotenv parser accepts it and
        # renders it as a YAML block scalar (the installer contract tests render this
        # exact form through `docker compose config` and diff the round-tripped PEM
        # against the original, so a parser regression is caught in CI).
        $block = "`n" +
                 "# Added by install.ps1 on $timestamp — persistent Ed25519 JWT signing`n" +
                 "# key (Audit Run 37, PB4). Keep this value: rotating it invalidates every`n" +
                 "# outstanding agent bearer token and forces each agent to re-authenticate.`n" +
                 "CONTROLLER_JWT_PRIVATE_KEY=`"$pem`n`"`n"
        Add-SecretLines $EnvFile $block

        if (-not $VerifyRender) { return }

        # Verify the PEM actually renders through THIS machine's compose build before
        # committing to it; restore the previous .env if it does not, so a compose
        # parser gap degrades to the old behaviour instead of breaking the install.
        $rendered = $null
        try { $rendered = (docker compose --profile community config 2>$null | Out-String) } catch { $rendered = $null }
        if ($rendered -and $rendered -match 'BEGIN PRIVATE KEY') {
            Write-Step "Provisioned a persistent JWT signing key (agent tokens now survive controller restarts)"
        } else {
            # Restore. Move-Item is a rename within the directory, so .env keeps the
            # backup's explicit (already-restricted) ACL rather than picking the
            # directory's inheritable one back up; Protect-FilePath re-asserts anyway.
            Move-Item -Path $backup -Destination $EnvFile -Force
            Protect-FilePath $EnvFile
            Write-Warn2 @'
This docker compose build could not render a multi-line PEM from .env —
leaving CONTROLLER_JWT_PRIVATE_KEY unset. The controller will generate its own
signing key; on controller images <= v0.2.2 that key is ephemeral, so agent
bearer tokens are invalidated on every restart (PB4).
'@
        }
    } finally {
        # PB5: .env.pb4.bak is a FULL PLAINTEXT COPY of every secret in .env. If the
        # installer throws (or is Ctrl-C'd) anywhere in the window above, that copy
        # would otherwise be left on disk permanently — long after the installer that
        # understood it was temporary has gone. Clear it on EVERY exit from this
        # function, including the early `return` and the error path. The rollback
        # branch moves it onto .env first, so this is a no-op once it has done its job.
        if (Test-Path $backup) { Remove-Item $backup -Force -ErrorAction SilentlyContinue }
    }
}

function Write-ScrubGuidance([string]$SecretsPath) {
    # PB3 (Audit Run 34/37): the controller writes the one-time bootstrap password
    # in CLEARTEXT to the model-storage volume. install.ps1 previously said nothing
    # about it at all (the Run-34 fix touched install.sh only), so Windows operators
    # were told how to REVEAL the password and never told to delete it. Emit this
    # from every branch that can leave the credential on disk.
    Write-Host "  -> After you have logged in, delete the one-time credentials file" -ForegroundColor Yellow
    Write-Host "     (the bootstrap password is stored in cleartext at rest):" -ForegroundColor Yellow
    Write-Host "       docker compose exec controller rm -f $SecretsPath"
    Write-Host "     (newer controller images remove it automatically on first login)"
    Write-Host ""
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

# -ProvisionEnvOnly writes .env and exits; it must work with no Docker and no
# network (offline / air-gapped pre-provisioning), so the Docker preflight and
# the release-manifest fetch are both skipped for it.
if (-not $ProvisionEnvOnly) {
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
}

New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
Set-Location $InstallDir
Write-Step "Install directory: $InstallDir"

# ── Step 1b. Resolve release manifest (PR-21 / §D2) ──────────────────
$script:ReleaseManifest = $null
if (-not $ProvisionEnvOnly) {
    $ManifestUrl = if ($env:FSEVEN_RELEASE_MANIFEST_URL) { $env:FSEVEN_RELEASE_MANIFEST_URL } `
                   else { 'https://github.com/f7-platform/public-agent-binaries/releases/latest/download/release-manifest.json' }
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
}

# ── Step 2. .env handling (idempotent per §B6) ───────────────────────
$EnvFile = Join-Path $InstallDir '.env'
$FreshInstall = $false
if (Test-Path $EnvFile) {
    Write-Step "Existing .env found — reusing all values (no secret rotation)"
    # Backfill CREDENTIAL_ENCRYPTION_KEY for installs that predate the
    # controller's encrypted-credential requirement (controller startup
    # rejects empty key outside dev). Mirrors install.sh behavior.
    $existing = Get-Content $EnvFile -Raw
    if ($existing -match '(?m)^PORT=(\d+)$') {
        $Port = [int]$Matches[1]
        Write-Step "Existing .env PORT detected; using port $Port"
    }
    if ($existing -notmatch '(?m)^CREDENTIAL_ENCRYPTION_KEY=') {
        $CredentialEncryptionKey = New-Secret
        $timestamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        Add-SecretLines $EnvFile @"

# Added by install.ps1 on $timestamp for encrypted telemetry HMAC keys.
CREDENTIAL_ENCRYPTION_KEY=$CredentialEncryptionKey
"@
        Write-Step "Added missing CREDENTIAL_ENCRYPTION_KEY to existing .env"
    }
    # Backfill FSEVEN_APP_DB_PASSWORD for installs that predate the CD10 RLS
    # serving-role cutover (Audit Run 35, CD10; synced to the published compose by
    # Audit Run 36, PB8). The updated compose binds the controller serving pool to
    # the least-privilege fseven_app role via DATABASE_URL=fseven_app:${FSEVEN_APP_DB_PASSWORD:?}
    # — without this secret `docker compose up` fails closed. The controller
    # provisions + verifies the role from this password at startup, so generating a
    # fresh one here is safe. POSTGRES_PASSWORD is never regenerated. Mirrors install.sh.
    if ($existing -notmatch '(?m)^FSEVEN_APP_DB_PASSWORD=') {
        $FsevenAppDbPassword = New-Secret
        $timestamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        Add-SecretLines $EnvFile @"

# Added by install.ps1 on $timestamp for the CD10 RLS serving-role cutover (PB8).
# Password for the least-privilege fseven_app DB role.
FSEVEN_APP_DB_PASSWORD=$FsevenAppDbPassword
"@
        Write-Step "Added missing FSEVEN_APP_DB_PASSWORD to existing .env"
    }
} else {
    Write-Step "Generating .env with fresh secrets"
    $PostgresPassword        = New-Secret
    # Password for the least-privilege fseven_app DB role used by the controller
    # serving pool after the CD10 RLS serving-role cutover (Audit Run 35, CD10;
    # synced into the published compose by Audit Run 36, PB8). The compose binds
    # DATABASE_URL to fseven_app:${FSEVEN_APP_DB_PASSWORD:?}, so a missing value
    # fails `docker compose up` closed — generate a strong one here.
    $FsevenAppDbPassword     = New-Secret
    $AdminApiKey             = New-Secret
    $CredentialEncryptionKey = New-Secret
    $timestamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    # PB5 (Audit Run 34/37): Write-SecretFile creates .env EMPTY, restricts it to
    # the current user, and only THEN writes the secrets into it. The previous
    # sequence wrote all four secrets with `Set-Content` at the inherited
    # directory ACL and tightened the ACL afterwards, leaving POSTGRES_PASSWORD /
    # FSEVEN_APP_DB_PASSWORD / ADMIN_API_KEY / CREDENTIAL_ENCRYPTION_KEY readable
    # by other local users for the window in between.
    Write-SecretFile $EnvFile @"
# Generated by install.ps1 on $timestamp
# Do not commit this file. Back it up — POSTGRES_PASSWORD is required
# to decrypt the database and is never regenerated on re-run.
POSTGRES_PASSWORD=$PostgresPassword
FSEVEN_APP_DB_PASSWORD=$FsevenAppDbPassword
ADMIN_API_KEY=$AdminApiKey
CREDENTIAL_ENCRYPTION_KEY=$CredentialEncryptionKey
DEPLOYMENT_MODE=Community
CONTROLLER_IMAGE=$Image
PORT=$Port
"@
    $FreshInstall = $true
}

# -ProvisionEnvOnly: the .env (including the persistent JWT key) is the whole
# job — do not touch Docker. Used for offline/air-gapped pre-provisioning, and
# by tests/bootstrap-handoff-static.sh to exercise this exact writer.
if ($ProvisionEnvOnly) {
    Add-PersistentJwtKey -EnvFile $EnvFile
    Write-Step "Provisioned $EnvFile (env only; Docker not touched)"
    exit 0
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

# ── Step 3c. Persistent JWT signing key (PB4) ────────────────────────
# Parity with install.sh Step 3c. Runs for BOTH fresh installs and existing .env
# files (the function is a no-op when the key is already present), so a Windows
# install created before this change is topped up on the next run instead of
# staying on the ephemeral key forever. Placed after the compose fetch because it
# verifies the PEM renders through `docker compose config` before keeping it.
Add-PersistentJwtKey -EnvFile $EnvFile -VerifyRender

# ── Step 4. Pull + up ────────────────────────────────────────────────
Write-Step "Pulling latest controller image"
docker compose --profile community pull

Write-Step "Starting services (profile: community)"
docker compose --profile community up -d

# ── Step 5. Wait for bootstrap to finish ─────────────────────────────
# Poll the persisted secrets file (written as the final bootstrap step)
# rather than grepping logs — much more reliable on slow machines.
$BootstrapTimeoutSecs = if ($env:FSEVEN_BOOTSTRAP_TIMEOUT_SECS) { [int]$env:FSEVEN_BOOTSTRAP_TIMEOUT_SECS } else { 120 }
Write-Step "Waiting for first-run bootstrap (up to $BootstrapTimeoutSecs s)…"
$deadline = (Get-Date).AddSeconds($BootstrapTimeoutSecs)
$SecretsPath = "/app/model-storage/bootstrap/secrets.env"
$AdminEmail = $null
$BootstrapReady = $false
while ((Get-Date) -lt $deadline) {
    $creds = docker compose exec -T controller cat $SecretsPath 2>$null
    if ($LASTEXITCODE -eq 0 -and $creds) {
        $AdminEmail = ($creds -split "`n" | Where-Object { $_ -match '^FSEVEN_BOOTSTRAP_ADMIN_EMAIL=' } |
            ForEach-Object { ($_ -split '=', 2)[1].Trim() } | Select-Object -First 1)
        if ($AdminEmail -and (($creds -split "`n") -match '^FSEVEN_BOOTSTRAP_ADMIN_PASSWORD=')) {
            $BootstrapReady = $true
            break
        }
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
if ($BootstrapReady) {
    Write-Host "  Admin login" -ForegroundColor White
    Write-Host "  Email:     $AdminEmail"
    Write-Host "  Password:  stored once at $SecretsPath"
    Write-Host "  Setup:     $DashboardUrl/setup"
    Write-Host ""
    Write-Host "  Reveal the one-time password only when ready to log in:"
    Write-Host "    docker compose exec controller sh -lc 'grep ^FSEVEN_BOOTSTRAP_ADMIN_PASSWORD= $SecretsPath | cut -d= -f2-'"
    Write-Host ""
    Write-Host "  -> Log in once, then rotate the password under Admin -> Profile." -ForegroundColor Yellow
    Write-Host ""
    Write-ScrubGuidance $SecretsPath
} elseif (-not $FreshInstall) {
    Write-Host "Dashboard:  $DashboardUrl"
    Write-Host "(Bootstrap credentials are only shown on demand; retrieve the one-time password with:"
    Write-Host "   docker compose exec controller sh -lc 'grep ^FSEVEN_BOOTSTRAP_ADMIN_PASSWORD= $SecretsPath | cut -d= -f2-'"
    Write-Host " if you still have the model-storage volume.)"
    Write-Host ""
    Write-ScrubGuidance $SecretsPath
} else {
    Write-Host "WARNING: Bootstrap did not complete within $BootstrapTimeoutSecs s." -ForegroundColor Yellow
    Write-Host "Check logs:  docker compose logs controller"
    Write-Host "Once bootstrap finishes, get credentials with:"
    Write-Host "   docker compose exec controller sh -lc 'grep ^FSEVEN_BOOTSTRAP_ADMIN_PASSWORD= $SecretsPath | cut -d= -f2-'"
    Write-Host ""
    Write-ScrubGuidance $SecretsPath
}

# ── Step 7. Self-observer chaining (PR-19) ───────────────────────────
# Offer to install the agent on this Windows host. Single-code-path:
# uses the existing admin-token API + msiexec /quiet silent install.

function Install-FsevenAgent {
    param([string]$AdminApiKey, [int]$Port)

    $arch = switch ($env:PROCESSOR_ARCHITECTURE) {
        'AMD64' { 'x86_64' }
        'ARM64' {
            Write-Warn2 "Windows ARM64 detected — using x86_64 MSI under emulation"
            'x86_64'
        }
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
