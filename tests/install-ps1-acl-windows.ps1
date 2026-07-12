#!/usr/bin/env pwsh
# ─────────────────────────────────────────────────────────────────────────────
# PB5 (Audit Run 37) — the WINDOWS half, actually EXECUTED.
#
# PB5 is a Windows ACL finding: its real home is `Protect-FilePath`'s
# Get-Acl/Set-Acl branch and the fact that a NEW file on Windows inherits the ACL
# of the CONTAINING DIRECTORY rather than the ACL of the file it was copied from.
# None of that code had ever run in CI — this repository had no `windows-latest`
# job at all (`static-checks.yml` was a single ubuntu-latest job), so the Windows
# half of the finding was asserted-by-construction. The ubuntu contract gate runs
# install.ps1 under PowerShell Core on Linux, where Protect-FilePath takes its
# `chmod` branch: it proves the ORDERING logic, and explicitly not the ACL logic.
#
# This gate closes that. It runs the REAL install.ps1 on Windows, in a directory
# deliberately made permissive, and asserts on BOTH properties that matter:
#
#   1. FINAL ACL     — .env ends up readable by the current user ONLY: inheritance
#                      disabled, and no Users / Authenticated Users / Everyone ACE
#                      survives. This executes Get-Acl/Set-Acl for real.
#
#   2. CREATION-TIME ORDER — the final ACL cannot distinguish "restricted before any
#                      secret byte was written" from "written at the directory's
#                      inherited ACL, then restricted", because Write-SecretFile /
#                      Add-SecretLines re-assert the restriction AFTER writing. Both
#                      end at owner-only. That blind spot is exactly how PB5 was
#                      re-created inside the PR that closed it (the `.env.pb4.bak`
#                      backup was taken with `Copy-Item` and restricted afterwards).
#                      So Set-Acl is intercepted and the file's SIZE recorded at each
#                      restriction, and the FIRST restriction of each secret file must
#                      happen while it is still EMPTY (or, on the upgrade path, before
#                      the new secret is appended).
#
# Fails closed: if it is not on Windows, if the interception does not fire, or if the
# hostile directory ACE does not actually reach a new file, it FAILS rather than
# skips. A check that silently skips is not a check — that is how PB4 and PB5 both
# stayed open on Windows for three audit runs while CI was green.
# ─────────────────────────────────────────────────────────────────────────────
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Fail([string]$Message) {
    Write-Host "FAIL: $Message" -ForegroundColor Red
    exit 1
}
function Pass([string]$Message) {
    Write-Host "PB5: $Message (verified)" -ForegroundColor Green
}

if (-not $IsWindows) {
    Fail @'
this gate MUST run on Windows. Get-Acl/Set-Acl is where PB5 actually lives, and it
cannot execute anywhere else — running it on Linux would assert nothing while
reporting green, which is the failure mode it exists to prevent.
'@
}

$RepoRoot  = Split-Path -Parent $PSScriptRoot
$Installer = Join-Path $RepoRoot 'install.ps1'
if (-not (Test-Path $Installer)) { Fail "install.ps1 not found at $Installer" }

$TempRoot = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { $env:TEMP }
$Root     = Join-Path $TempRoot ("pb5-acl-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $Root -Force | Out-Null

$MySid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
$UsersSid = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-545')  # BUILTIN\Users

function New-HostileDir([string]$Path) {
    # A HOSTILE install directory: BUILTIN\Users gets an INHERITABLE Read ACE, like a
    # directory under C:\ or a shared drive. Every file created inside now inherits
    # "other local users may read me" — so a file written first and restricted second
    # is genuinely exposed for that window, and a file restricted first is genuinely
    # safe. Without this, an owner-only assertion could pass for the wrong reason.
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    $acl = Get-Acl -Path $Path
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        $UsersSid, 'ReadAndExecute', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
    $acl.AddAccessRule($rule)
    Set-Acl -Path $Path -AclObject $acl
}

function Assert-DirIsHostile([string]$Dir) {
    # VACUITY GUARD. Prove the inheritable Users ACE really does reach a NEW file in
    # this directory, by creating an unprotected control file and looking at its ACL.
    # If it does not, every "no other-user ACE on .env" assertion below would pass
    # trivially and prove nothing.
    $control = Join-Path $Dir 'control-unprotected.txt'
    Set-Content -Path $control -Value 'not a secret' -Encoding ascii
    $inherited = (Get-Acl -Path $control).Access | Where-Object {
        $_.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]) -eq $UsersSid
    }
    if (-not $inherited) {
        Fail @"
the control file in $Dir did NOT inherit the BUILTIN\Users ACE, so this directory is
not actually hostile and the ACL assertions below would be vacuous. The gate must fail
rather than report a green it has not earned.
"@
    }
    Remove-Item -Path $control -Force
    Write-Host "  (vacuity guard: a new file in this directory DOES inherit BUILTIN\Users:Read)"
}

function Assert-OwnerOnly([string]$Path, [string]$Label) {
    if (-not (Test-Path $Path)) { Fail "$Label does not exist at $Path" }
    $acl = Get-Acl -Path $Path

    if (-not $acl.AreAccessRulesProtected) {
        Fail @"
$Label still INHERITS its ACL from the install directory (inheritance is not disabled).
It therefore carries whatever the parent grants — on a normal Windows host that
includes read access for other local principals, and this file holds
POSTGRES_PASSWORD, FSEVEN_APP_DB_PASSWORD, ADMIN_API_KEY, CREDENTIAL_ENCRYPTION_KEY
and the JWT private key.
"@
    }

    $foreign = @()
    foreach ($ace in $acl.Access) {
        if ($ace.AccessControlType -ne 'Allow') { continue }
        $sid = $null
        try { $sid = $ace.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]) } catch { }
        if ($null -eq $sid -or $sid -ne $MySid) {
            $foreign += ("{0} ({1})" -f $ace.IdentityReference, $ace.FileSystemRights)
        }
    }
    if ($foreign.Count -gt 0) {
        Fail @"
$Label grants access to principals other than the installing user: $($foreign -join '; ').
Every secret in it is readable by those principals. Protect-FilePath must leave exactly
one Allow ACE — the current user.
"@
    }
    Pass "$Label is owner-only on Windows (inheritance disabled, no other-user ACE)"
}

function Get-FirstRestrictionSize([string]$Trace, [string]$Path) {
    # "<path>|<size>" — the file's size at the MOMENT Set-Acl was called on it.
    foreach ($line in Get-Content -Path $Trace) {
        $parts = $line -split '\|', 2
        if ($parts[0] -eq $Path) { return [int]$parts[1] }
    }
    return $null
}

# The child runner: shadow Set-Acl with a tracing function (a PowerShell function
# takes precedence over a cmdlet of the same name), then DOT-SOURCE the real
# install.ps1 so its Protect-FilePath calls resolve to the shim. install.ps1 ends
# -ProvisionEnvOnly with `exit 0`, which would terminate this script too if it were
# dot-sourced here — hence a child process, with the trace read back afterwards.
$Runner = Join-Path $Root 'traced-install.ps1'
Set-Content -Path $Runner -Encoding utf8 -Value @'
param([string]$Installer, [string]$Dir, [string]$Trace)
function Set-Acl {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$AclObject
    )
    $len = -1
    if (Test-Path -LiteralPath $Path) { $len = (Get-Item -LiteralPath $Path).Length }
    Add-Content -LiteralPath $Trace -Value ("{0}|{1}" -f $Path, $len)
    Microsoft.PowerShell.Security\Set-Acl -LiteralPath $Path -AclObject $AclObject
}
. $Installer -InstallDir $Dir -ProvisionEnvOnly
'@

# ── Scenario 1: fresh install — the REAL installer, unshimmed, real ACLs ────────
Write-Host "`n== PB5/Windows: fresh install writes owner-only secret files ==" -ForegroundColor Cyan
$fresh = Join-Path $Root 'fresh'
New-HostileDir $fresh
Assert-DirIsHostile $fresh

& pwsh -NoProfile -File $Installer -InstallDir $fresh -ProvisionEnvOnly
if ($LASTEXITCODE -ne 0) { Fail "install.ps1 -ProvisionEnvOnly exited $LASTEXITCODE" }

$envFile = Join-Path $fresh '.env'
foreach ($key in @('POSTGRES_PASSWORD', 'FSEVEN_APP_DB_PASSWORD', 'ADMIN_API_KEY',
                   'CREDENTIAL_ENCRYPTION_KEY', 'CONTROLLER_JWT_PRIVATE_KEY')) {
    if (-not (Select-String -Path $envFile -Pattern "^$key=" -Quiet)) {
        Fail "install.ps1 did not write $key into .env — the ACL assertions would be about an empty file"
    }
}
Assert-OwnerOnly $envFile '.env'

if (Test-Path (Join-Path $fresh '.env.pb4.bak')) {
    Fail ".env.pb4.bak survived the installer — a full plaintext copy of every secret in .env, left on disk"
}
Pass "install.ps1 leaves no .env.pb4.bak secret copy behind"

# ── Scenario 2: fresh install — CREATION-TIME ORDER (Set-Acl intercepted) ───────
Write-Host "`n== PB5/Windows: secret files are restricted BEFORE any secret byte ==" -ForegroundColor Cyan
$order      = Join-Path $Root 'order'
$orderTrace = Join-Path $Root 'order-trace.txt'
New-HostileDir $order
New-Item -ItemType File -Path $orderTrace -Force | Out-Null

& pwsh -NoProfile -File $Runner -Installer $Installer -Dir $order -Trace $orderTrace
if ($LASTEXITCODE -ne 0) { Fail "traced install.ps1 -ProvisionEnvOnly exited $LASTEXITCODE" }

$traceLines = @(Get-Content -Path $orderTrace)
if ($traceLines.Count -eq 0) {
    Fail @'
captured NO Set-Acl trace: the interception never fired, so this ordering proof would be
vacuous. (If Protect-FilePath stopped calling Set-Acl on Windows, the secret files are
not being restricted at all — which is worse.)
'@
}
Write-Host ("  (Set-Acl trace: {0} restriction(s) recorded)" -f $traceLines.Count)

foreach ($f in @(@{ p = (Join-Path $order '.env');          l = '.env' },
                 @{ p = (Join-Path $order '.env.pb4.bak');  l = '.env.pb4.bak (a full copy of every secret in .env)' })) {
    $size = Get-FirstRestrictionSize $orderTrace $f.p
    if ($null -eq $size) {
        Fail @"
install.ps1 NEVER restricted $($f.l) on Windows. It keeps the install directory's
inherited ACL — on this hostile directory that means BUILTIN\Users can read every
secret in it.
"@
    }
    if ($size -ne 0) {
        Fail @"
install.ps1 restricted $($f.l) only AFTER $size bytes of secrets were already in it.
The file existed, with secrets, at the directory's INHERITED ACL for the window before
Set-Acl landed — other local users could read it. That is the write-then-restrict TOCTOU
PB5 names. Create the file EMPTY, restrict it, and only THEN write the secrets
(Write-SecretFile / Copy-SecretFile). NB a `Copy-Item` backup re-creates this defect:
the new file takes the DIRECTORY's inheritable ACL, not the source file's explicit one.
"@
    }
    Pass "$($f.l) was restricted while EMPTY, before any secret byte reached disk"
}

# ── Scenario 3: the UPGRADE path — restrict BEFORE appending to an old .env ─────
# install.ps1 backfills CREDENTIAL_ENCRYPTION_KEY / FSEVEN_APP_DB_PASSWORD into a .env
# written by an OLDER installer — one created before the PB5 fix, at the directory's
# inherited ACL. Add-SecretLines used to append the freshly minted secret FIRST and
# restrict afterwards, so the new secret landed in a world-readable file. Final ACL
# cannot see this (the restriction is re-asserted after the append); only order can.
Write-Host "`n== PB5/Windows: a pre-existing readable .env is restricted BEFORE new secrets are appended ==" -ForegroundColor Cyan
$upg      = Join-Path $Root 'upgrade'
$upgTrace = Join-Path $Root 'upgrade-trace.txt'
New-HostileDir $upg
Assert-DirIsHostile $upg
New-Item -ItemType File -Path $upgTrace -Force | Out-Null

$upgEnv = Join-Path $upg '.env'
$legacy = @(
    '# Generated by an older install.ps1'
    'POSTGRES_PASSWORD=legacy-postgres-password'
    'ADMIN_API_KEY=legacy-admin-api-key'
    'DEPLOYMENT_MODE=Community'
    'PORT=8080'
) -join "`n"
[System.IO.File]::WriteAllText($upgEnv, $legacy + "`n", (New-Object System.Text.UTF8Encoding($false)))
$legacySize = (Get-Item $upgEnv).Length

# It really is other-user-readable to begin with (it inherited the hostile ACE) — that
# is the state an older installer left behind.
$inheritedAce = (Get-Acl -Path $upgEnv).Access | Where-Object {
    $_.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]) -eq $UsersSid
}
if (-not $inheritedAce) {
    Fail "the pre-existing .env did not inherit BUILTIN\Users:Read — the upgrade-path proof would be vacuous"
}

& pwsh -NoProfile -File $Runner -Installer $Installer -Dir $upg -Trace $upgTrace
if ($LASTEXITCODE -ne 0) { Fail "traced install.ps1 (upgrade path) exited $LASTEXITCODE" }

foreach ($key in @('CREDENTIAL_ENCRYPTION_KEY', 'FSEVEN_APP_DB_PASSWORD', 'CONTROLLER_JWT_PRIVATE_KEY')) {
    if (-not (Select-String -Path $upgEnv -Pattern "^$key=" -Quiet)) {
        Fail "install.ps1 did not backfill $key on the upgrade path — the ordering proof would be vacuous"
    }
}
$firstUpg = Get-FirstRestrictionSize $upgTrace $upgEnv
if ($null -eq $firstUpg) {
    Fail @"
install.ps1 never restricted the pre-existing .env on the upgrade path. It still carries
the older installer's inherited ACL — with a freshly minted CREDENTIAL_ENCRYPTION_KEY and
FSEVEN_APP_DB_PASSWORD now inside it, readable by other local users.
"@
}
if ($firstUpg -gt $legacySize) {
    Fail @"
install.ps1 restricted the pre-existing .env only AFTER appending to it ($firstUpg bytes at
the first Set-Acl; $legacySize bytes before the append). The upgrade path (install.ps1
Add-SecretLines, called at :372 CREDENTIAL_ENCRYPTION_KEY and :389 FSEVEN_APP_DB_PASSWORD)
appended a freshly minted secret to a .env that an OLDER installer left readable by other
local users, and tightened it only afterwards. That is write-then-restrict — PB5, on the
upgrade path. Restrict in Add-SecretLines BEFORE the AppendAllText.
"@
}
Pass "the pre-existing world-readable .env was restricted BEFORE the new secrets were appended"
Assert-OwnerOnly $upgEnv '.env (upgrade path)'

if (Test-Path (Join-Path $upg '.env.pb4.bak')) {
    Fail ".env.pb4.bak survived the upgrade path — a full plaintext copy of every secret in .env"
}

Remove-Item -Path $Root -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "`ninstall.ps1 Windows ACL gate passed" -ForegroundColor Green
