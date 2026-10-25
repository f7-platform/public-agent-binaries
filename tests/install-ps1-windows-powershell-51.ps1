# ─────────────────────────────────────────────────────────────────────────────
# install.ps1 under WINDOWS POWERSHELL 5.1 (Audit Run 43, PAB5 / PAB6).
#
# README.md tells Windows operators to run install.ps1 from "PowerShell 5.1+ or
# 7+". Nothing in CI ran it under 5.1: the ubuntu contract gate runs it under
# PowerShell Core on Linux, and the windows-latest ACL job runs it under pwsh and
# stops at -ProvisionEnvOnly before the first docker call. The two editions treat
# a native command's stderr differently. Windows PowerShell 5.1 wraps each stderr
# line of a native command whose error stream is redirected (2>$null, 2>&1) in a
# NativeCommandError record, and under $ErrorActionPreference = 'Stop' (which
# install.ps1 sets on line 49) the first such record is a terminating error.
# PowerShell 7.2+ does not apply the preference to native stderr. The real docker
# CLI writes "Error: No such volume" to stderr on every FRESH install at the
# stale-volume probe (`docker volume inspect <project>_pgdata 2>$null`), so if the
# 5.1 behaviour is real, every fresh Windows install on the advertised shell aborts
# there (PAB6).
#
# This gate runs the REAL install.ps1, as a child powershell.exe (the 5.1 engine),
# against a stub `docker.cmd` placed ahead of PATH. The stub never contacts a
# daemon. Unlike the bash stub in tests/bootstrap-handoff-static.sh, whose `volume`
# answer used to exit 1 silently, this one writes to stderr exactly where the real
# CLI does, because that stderr is the whole question. The harness captures the
# child's stdout and stderr to files (Start-Process redirects, which bypass the
# wrapping entirely), prints everything it saw, and only then asserts, so a red run
# shows what 5.1 actually did rather than just that it failed.
#
# Fails closed: not Windows PowerShell 5.x, or the stub not resolving ahead of a
# real docker, is a failure, never a skip (the PB6 lesson: a check that silently
# skips is not a check).
# ─────────────────────────────────────────────────────────────────────────────
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Fail([string]$Message) {
    Write-Host "FAIL: $Message" -ForegroundColor Red
    exit 1
}
function Pass([string]$Message) {
    Write-Host "PASS: $Message (verified)" -ForegroundColor Green
}

$edition = $PSVersionTable['PSEdition']
$version = $PSVersionTable['PSVersion']
Write-Host "Running under PowerShell $version ($edition)"
if ($edition -ne 'Desktop' -or $version.Major -ne 5) {
    Fail @"
this gate MUST run under Windows PowerShell 5.1 (PSEdition Desktop, major version 5).
It is running $edition $version. README.md advertises 5.1 and this is the only job
that executes install.ps1 on that engine; running it anywhere else asserts nothing.
"@
}

$RepoRoot  = Split-Path -Parent $PSScriptRoot
$Installer = Join-Path $RepoRoot 'install.ps1'
$Compose   = Join-Path $RepoRoot 'docker-compose.yml'
foreach ($f in @($Installer, $Compose)) {
    if (-not (Test-Path -LiteralPath $f)) { Fail "$f not found" }
}

$TempRoot = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { $env:TEMP }
$Root     = Join-Path $TempRoot ("ps51-" + [Guid]::NewGuid().ToString('N'))
$StubDir  = Join-Path $Root 'stub-bin'
New-Item -ItemType Directory -Path $StubDir -Force | Out-Null

# ── The docker test double ───────────────────────────────────────────────────
# Written here with CRLF line endings rather than shipped as a file: cmd.exe
# mis-parses `goto` labels in LF-only batch files, and a checkout's line endings
# depend on the client's autocrlf setting.
#
# Test hooks (all environment variables, read by the stub at each call):
#   FSEVEN_DOCKER_LOG           append every invocation's arguments, one per line
#   FSEVEN_TEST_DOCKER_FAIL     info | pull | up: that call fails the way the real
#                               CLI does (a stderr line and exit 1)
#   FSEVEN_TEST_BOOTSTRAP_READY yes: `compose exec ... cat secrets.env` prints the
#                               bootstrap credentials and exits 0; otherwise it
#                               writes to stderr and exits 1, as the real CLI does
#                               while the controller is still starting
#   FSEVEN_TEST_HEALTHCHECK     yes: `compose logs` prints the healthcheck line
#   FSEVEN_TEST_ENV_DUMP        a path: `compose up` dumps its environment there,
#                               so a scenario can read the PORT and CONTROLLER_IMAGE
#                               Compose would actually have used
$stub = @(
    '@echo off'
    'rem docker.cmd: a docker test double for tests/install-ps1-windows-powershell-51.ps1.'
    'rem Never contacts a daemon. Writes to stderr where the real CLI does.'
    'if defined FSEVEN_DOCKER_LOG (>> "%FSEVEN_DOCKER_LOG%" echo %*)'
    'if "%~1"=="info" goto :info'
    'if "%~1"=="volume" goto :volume'
    'if "%~1"=="compose" goto :compose'
    'exit /b 0'
    ''
    ':info'
    'if "%FSEVEN_TEST_DOCKER_FAIL%"=="info" goto :info_fail'
    'echo Server Version: 0.0.0-stub'
    'exit /b 0'
    ':info_fail'
    '>&2 echo error during connect: this error may indicate that the docker daemon is not running'
    'exit /b 1'
    ''
    ':volume'
    'rem A fresh install probes a volume that does not exist. The real CLI prints'
    'rem "[]" on stdout, an Error line on stderr, and exits 1.'
    'echo []'
    '>&2 echo Error: No such volume: %~3'
    'exit /b 1'
    ''
    ':compose'
    'shift'
    ':compose_parse'
    'if "%~1"=="" exit /b 0'
    'if "%~1"=="--profile" (shift & shift & goto :compose_parse)'
    'if "%~1"=="--project-name" (shift & shift & goto :compose_parse)'
    'if "%~1"=="-f" (shift & shift & goto :compose_parse)'
    'if "%~1"=="-p" (shift & shift & goto :compose_parse)'
    'set "FSEVEN_STUB_ARG=%~1"'
    'if "%FSEVEN_STUB_ARG:~0,1%"=="-" (shift & goto :compose_parse)'
    'set "FSEVEN_STUB_SUB=%~1"'
    'if "%FSEVEN_STUB_SUB%"=="version" goto :compose_version'
    'if "%FSEVEN_STUB_SUB%"=="config" goto :compose_config'
    'if "%FSEVEN_STUB_SUB%"=="pull" goto :compose_pull'
    'if "%FSEVEN_STUB_SUB%"=="up" goto :compose_up'
    'if "%FSEVEN_STUB_SUB%"=="exec" goto :compose_exec'
    'if "%FSEVEN_STUB_SUB%"=="logs" goto :compose_logs'
    'exit /b 0'
    ''
    ':compose_version'
    'echo Docker Compose version v2.0.0-stub'
    'exit /b 0'
    ''
    ':compose_config'
    'rem Enough for the installer''s PB4 render check: the PEM it wrote is in .env.'
    'if exist .env type .env'
    'exit /b 0'
    ''
    ':compose_pull'
    'if "%FSEVEN_TEST_DOCKER_FAIL%"=="pull" goto :compose_pull_fail'
    'echo  controller Pulled'
    'exit /b 0'
    ':compose_pull_fail'
    '>&2 echo Error response from daemon: manifest unknown'
    'exit /b 1'
    ''
    ':compose_up'
    'if defined FSEVEN_TEST_ENV_DUMP (set > "%FSEVEN_TEST_ENV_DUMP%")'
    'if "%FSEVEN_TEST_DOCKER_FAIL%"=="up" goto :compose_up_fail'
    'echo  Container fseven-controller Started'
    'exit /b 0'
    ':compose_up_fail'
    '>&2 echo Error response from daemon: stub refused to start the controller'
    'exit /b 1'
    ''
    ':compose_exec'
    'if "%FSEVEN_TEST_BOOTSTRAP_READY%"=="yes" goto :compose_exec_ready'
    '>&2 echo service "controller" is not running'
    'exit /b 1'
    ':compose_exec_ready'
    'echo FSEVEN_BOOTSTRAP_ADMIN_EMAIL=admin@example.test'
    'echo FSEVEN_BOOTSTRAP_ADMIN_PASSWORD=stub-one-time-password'
    'exit /b 0'
    ''
    ':compose_logs'
    'if not "%FSEVEN_TEST_HEALTHCHECK%"=="yes" exit /b 0'
    'echo Listening (healthcheck ready)'
    'exit /b 0'
)
$StubPath = Join-Path $StubDir 'docker.cmd'
[System.IO.File]::WriteAllText($StubPath, (($stub -join "`r`n") + "`r`n"), [System.Text.Encoding]::ASCII)

$env:PATH = "$StubDir;$env:PATH"
$resolved = Get-Command docker -ErrorAction SilentlyContinue
if (-not $resolved -or $resolved.Path -ne $StubPath) {
    $where = if ($resolved) { $resolved.Path } else { '<nothing>' }
    Fail "docker resolves to $where, not to the stub at $StubPath. The runner's real docker would be exercised and the scenarios below would be measuring it, not install.ps1."
}
Write-Host "docker resolves to the stub: $($resolved.Path)"

function Read-TextFile([string]$Path) {
    if (Test-Path -LiteralPath $Path) { return [System.IO.File]::ReadAllText($Path) }
    return ''
}

function Invoke-Installer {
    # Run the real install.ps1 under a child powershell.exe (the 5.1 engine), the
    # way tests/bootstrap-handoff-static.sh's run_install_ps1 does under pwsh: the
    # release manifest pointed at a file that does not exist (both fetchers fail
    # closed to "no manifest"), the compose copied in so nothing is fetched, and
    # the stub docker ahead of PATH. Returns the exit code, everything the child
    # wrote, and the stub's call log; prints all three first.
    param(
        [string]$Name,
        [string[]]$ExtraArgs = @(),
        [hashtable]$EnvOverrides = @{},
        [switch]$ViaIex
    )
    $work = Join-Path $Root $Name
    # README.md's own command is `irm <url> | iex`: the script arrives as a STRING
    # decoded with the HTTP charset and is evaluated by Invoke-Expression, with no
    # parameters, so -InstallDir takes its default of .\fseven. -ViaIex reproduces
    # that path (Get-Content -Raw -Encoding UTF8 stands in for irm) from the
    # scenario directory; the default runs the file the way a downloaded copy or the
    # release asset is run, `powershell -File install.ps1`.
    $dir = if ($ViaIex) { Join-Path $work 'fseven' } else { $work }
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $target = Join-Path $dir 'docker-compose.yml'
    if (-not (Test-Path -LiteralPath $target)) { Copy-Item -LiteralPath $Compose -Destination $target }
    $out = Join-Path $Root "$Name.stdout.txt"
    $err = Join-Path $Root "$Name.stderr.txt"
    $log = Join-Path $Root "$Name.docker.log"
    New-Item -ItemType File -Path $log -Force | Out-Null

    $vars = @{
        FSEVEN_RELEASE_MANIFEST_URL   = 'file:///nonexistent-fseven-release-manifest.json'
        FSEVEN_TEST_BOOTSTRAP_READY   = 'yes'
        FSEVEN_TEST_HEALTHCHECK       = 'no'
        FSEVEN_BOOTSTRAP_TIMEOUT_SECS = '5'
        FSEVEN_DOCKER_LOG             = $log
        FSEVEN_TEST_DOCKER_FAIL       = ''
        FSEVEN_TEST_ENV_DUMP          = ''
    }
    foreach ($k in $EnvOverrides.Keys) { $vars[$k] = $EnvOverrides[$k] }
    foreach ($k in $vars.Keys) {
        # An empty value removes the variable, which is what the stub reads as unset.
        Set-Item -Path "Env:$k" -Value $vars[$k]
    }

    if ($ViaIex) {
        $runner = Join-Path $Root 'iex-runner.ps1'
        $runnerText = @(
            'param([string]$Installer, [string]$Dir)'
            'Set-Location -LiteralPath $Dir'
            '$text = Get-Content -LiteralPath $Installer -Raw -Encoding UTF8'
            'Invoke-Expression $text'
        ) -join "`r`n"
        [System.IO.File]::WriteAllText($runner, $runnerText + "`r`n", [System.Text.Encoding]::ASCII)
        $argv = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
                  '-File', $runner, '-Installer', $Installer, '-Dir', $work) + $ExtraArgs
    } else {
        $argv = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
                  '-File', $Installer, '-InstallDir', $dir, '-NoAgent') + $ExtraArgs
    }
    $quoted = $argv | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }
    $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $quoted -Wait -PassThru -NoNewWindow `
        -RedirectStandardOutput $out -RedirectStandardError $err
    $stdout = Read-TextFile $out
    $stderr = Read-TextFile $err
    $calls  = Read-TextFile $log

    Write-Host ""
    $how = if ($ViaIex) { 'via Invoke-Expression (the irm | iex path)' } else { 'via powershell -File' }
    Write-Host "== scenario '$Name': install.ps1 $($ExtraArgs -join ' ') $how exited $($proc.ExitCode) ==" -ForegroundColor Cyan
    Write-Host "-- stdout --"
    Write-Host $stdout
    Write-Host "-- stderr --"
    Write-Host $stderr
    Write-Host "-- docker calls (stub log) --"
    Write-Host $calls
    Write-Host "-- end of scenario '$Name' --"

    return @{
        ExitCode = $proc.ExitCode
        Output   = $stdout + "`n" + $stderr
        Calls    = $calls
        Dir      = $dir
    }
}

# ── Scenario 1: a FRESH install, bootstrap completes (PAB6 probe) ────────────
# The stale-volume probe runs only on a fresh install, and the stub answers it
# the way the real CLI answers for a volume that does not exist: an Error line
# on stderr and exit 1. Under 5.1 with the Stop preference that line is the
# question PAB6 asks. Run both ways a Windows operator reaches the script: the
# README's `irm | iex` and a downloaded copy run from disk.
function Describe-Stop([hashtable]$Run) {
    # Name the cause the stub log shows, so a red run says what happened rather
    # than blaming one suspect for every non-zero exit. The first probe run of
    # this job did exactly that: install.ps1 never parsed under 5.1 (no BOM), no
    # docker command ran, and the verdict still named the PAB6 stderr.
    $calls = @(($Run.Calls -split "`r?`n") | Where-Object { $_.Trim() -ne '' })
    if ($calls.Count -eq 0) {
        return "install.ps1 never called docker: it did not parse, or stopped before the preflight (read the stderr above; a ParserError there is the encoding defect, not PAB6)"
    }
    $last = $calls[-1].Trim()
    if ($last -match '^volume inspect ') {
        return "install.ps1 stopped right after '$last', the stale-volume probe at which the stub wrote 'Error: No such volume' to stderr: that is PAB6, the redirected native stderr becoming a terminating error under Windows PowerShell 5.1"
    }
    if ($last -match '^compose exec ') {
        return "install.ps1 stopped right after '$last', a bootstrap poll at which the stub wrote to stderr: PAB6 on the bootstrap-wait redirect"
    }
    return "install.ps1 stopped after its last docker call, '$last' (read the stderr above)"
}

function Assert-FreshInstall([hashtable]$Run, [string]$How) {
    if ($Run.ExitCode -ne 0) {
        Fail "a fresh install.ps1 ($How) exited $($Run.ExitCode) under Windows PowerShell 5.1. $(Describe-Stop $Run)"
    }
    if ($Run.Output -notmatch 'admin@example\.test') {
        Fail "a fresh install.ps1 ($How) exited 0 but never printed the bootstrap admin email; it did not reach the credentials step"
    }
    if ($Run.Calls -notmatch '(?m)^compose --profile community pull\s*$') {
        Fail "a fresh install.ps1 ($How) never ran 'docker compose --profile community pull'"
    }
    if ($Run.Calls -notmatch '(?m)^compose --profile community up -d\s*$') {
        Fail "a fresh install.ps1 ($How) never ran 'docker compose --profile community up -d'"
    }
    $envFile = Join-Path $Run.Dir '.env'
    foreach ($key in @('POSTGRES_PASSWORD', 'FSEVEN_APP_DB_PASSWORD', 'ADMIN_API_KEY',
                       'CREDENTIAL_ENCRYPTION_KEY', 'CONTROLLER_JWT_PRIVATE_KEY', 'PORT', 'CONTROLLER_IMAGE')) {
        if (-not (Select-String -Path $envFile -Pattern "^$key=" -Quiet)) {
            Fail "a fresh install.ps1 ($How) did not write $key into .env"
        }
    }
    if (Test-Path (Join-Path $Run.Dir '.env.pb4.bak')) {
        Fail ".env.pb4.bak survived the installer ($How): a full plaintext copy of every secret in .env, left on disk"
    }
    Pass "PAB6: a fresh install.ps1 ($How) completes under Windows PowerShell 5.1 when docker writes 'Error: No such volume' to stderr at the stale-volume probe"
}

$freshIex = Invoke-Installer -Name 'fresh-iex' -ViaIex
$freshFile = Invoke-Installer -Name 'fresh-file'
Assert-FreshInstall $freshIex 'irm | iex path'
Assert-FreshInstall $freshFile 'run from disk'

# A fresh install whose bootstrap never completes: every poll of the secrets
# file makes docker write "service controller is not running" to stderr, as the
# real CLI does while the controller is still starting. The scenario above never
# reaches that branch (the stub answers the first poll), so without this one the
# bootstrap-wait redirect would be unguarded on 5.1. The installer must reach
# its timeout branch and exit 0.
$freshTimeout = Invoke-Installer -Name 'fresh-timeout' -EnvOverrides @{ FSEVEN_TEST_BOOTSTRAP_READY = 'no'; FSEVEN_BOOTSTRAP_TIMEOUT_SECS = '2' }
if ($freshTimeout.ExitCode -ne 0) {
    Fail "a fresh install.ps1 whose bootstrap polls all fail exited $($freshTimeout.ExitCode) under Windows PowerShell 5.1. $(Describe-Stop $freshTimeout)"
}
if ($freshTimeout.Output -notmatch 'Bootstrap did not complete within 2 s') {
    Fail "a fresh install.ps1 whose bootstrap polls all fail did not reach the bootstrap-timeout branch"
}
if (@(($freshTimeout.Calls -split "`r?`n") | Where-Object { $_ -match '^compose exec -T controller cat ' }).Count -lt 1) {
    Fail "the bootstrap-timeout scenario never polled the secrets file, so it exercised nothing"
}
Pass "PAB6: a fresh install.ps1 reaches its bootstrap-timeout branch under Windows PowerShell 5.1 while every poll makes docker write to stderr"

# ── Scenario 2: docker FAILS at info, pull, up (PAB5) ───────────────────────
# A native command's non-zero exit raises no exception, so the try/catch that
# used to wrap the preflight never fired, pull and up were unchecked, and "is
# running" was printed regardless. On the 5.1 engine specifically.
function Get-EnvValue([string]$Path, [string]$Key) {
    $m = Select-String -Path $Path -Pattern "^$Key=(.*)$" | Select-Object -First 1
    if ($m) { return $m.Matches[0].Groups[1].Value.Trim() }
    return $null
}

foreach ($case in @(
    @{ Fail = 'info'; Next = '(?m)^compose --profile community (pull|up)' },
    @{ Fail = 'pull'; Next = '(?m)^compose --profile community up' },
    @{ Fail = 'up';   Next = '(?m)^compose exec' }
)) {
    $run = Invoke-Installer -Name "fail-$($case.Fail)" -EnvOverrides @{ FSEVEN_TEST_DOCKER_FAIL = $case.Fail }
    if ($run.ExitCode -eq 0) {
        Fail "install.ps1 exited 0 although docker $($case.Fail) failed (PAB5)"
    }
    if ($run.Output -match 'is running at') {
        Fail "install.ps1 printed 'is running' although docker $($case.Fail) failed (PAB5)"
    }
    if ($run.Calls -match $case.Next) {
        Fail "install.ps1 went on to the next docker step after $($case.Fail) failed (PAB5): $($run.Calls)"
    }
    Pass "PAB5: install.ps1 exits $($run.ExitCode), never says 'is running' and stops at the failed $($case.Fail)"
}

# ── Scenario 3: -Port / -Image win over .env on a re-run (PAB4) ─────────────
# Over the fresh install from scenario 1 (run from disk). The stub dumps the
# environment `compose up` ran with, which is what Compose would have used.
$reRunDir = $freshFile.Dir
$envFile  = Join-Path $reRunDir '.env'
$before   = @{}
foreach ($key in @('POSTGRES_PASSWORD', 'FSEVEN_APP_DB_PASSWORD', 'ADMIN_API_KEY', 'CREDENTIAL_ENCRYPTION_KEY')) {
    $before[$key] = Get-EnvValue $envFile $key
}
$dump = Join-Path $Root 'pab4-up.env'
$reRun = Invoke-Installer -Name 'fresh-file' -ExtraArgs @('-Port', '9090', '-Image', 'example/override:1') `
    -EnvOverrides @{ FSEVEN_TEST_ENV_DUMP = $dump; FSEVEN_TEST_HEALTHCHECK = 'yes'; FSEVEN_TEST_BOOTSTRAP_READY = 'no' }
if ($reRun.ExitCode -ne 0) { Fail "the re-run with -Port 9090 -Image example/override:1 exited $($reRun.ExitCode)" }
if ($reRun.Output -notmatch 'Existing \.env PORT=8080 replaced by PORT=9090') {
    Fail "the re-run did not log the PORT rewrite (PAB4)"
}
if ($reRun.Output -notmatch 'running at http://localhost:9090') {
    Fail "the re-run did not print the port -Port asked for (PAB4)"
}
$dumpText = Read-TextFile $dump
if ($dumpText -notmatch '(?m)^PORT=9090\s*$') {
    Fail "docker compose up ran with a PORT other than 9090 (PAB4): the printed URL and the bound port disagree"
}
if ($dumpText -notmatch '(?m)^CONTROLLER_IMAGE=example/override:1\s*$') {
    Fail "docker compose up ran with a CONTROLLER_IMAGE other than example/override:1 (PAB4)"
}
if ((Get-EnvValue $envFile 'PORT') -ne '9090') { Fail ".env PORT is not 9090 after the re-run (PAB4)" }
if ((Get-EnvValue $envFile 'CONTROLLER_IMAGE') -ne 'example/override:1') { Fail ".env CONTROLLER_IMAGE was not rewritten (PAB4)" }
foreach ($key in $before.Keys) {
    if ((Get-EnvValue $envFile $key) -ne $before[$key]) { Fail "the .env rewrite changed $key; only PORT and CONTROLLER_IMAGE may change (PAB4)" }
}
foreach ($copy in @('.env.pb4.bak', '.env.pab4.tmp')) {
    if (Test-Path (Join-Path $reRunDir $copy)) { Fail "$copy survived the re-run: a full plaintext copy of every secret in .env, left on disk" }
}
Pass "PAB4: -Port/-Image win over .env on a re-run; URL, Compose and .env agree; secrets untouched"

$flagless = Invoke-Installer -Name 'fresh-file' -EnvOverrides @{ FSEVEN_TEST_ENV_DUMP = $dump; FSEVEN_TEST_HEALTHCHECK = 'yes'; FSEVEN_TEST_BOOTSTRAP_READY = 'no' }
if ($flagless.ExitCode -ne 0) { Fail "the flagless re-run exited $($flagless.ExitCode)" }
if ($flagless.Output -match 'replaced by') { Fail "a flagless re-run rewrote .env (PAB4)" }
if ((Read-TextFile $dump) -notmatch '(?m)^PORT=9090\s*$') { Fail "a flagless re-run moved the port away from 9090 (PAB4)" }
if ($flagless.Output -notmatch 'running at http://localhost:9090') { Fail "a flagless re-run printed a port other than 9090 (PAB4)" }
Pass "PAB4: a flagless re-run keeps what .env says"

$back = Invoke-Installer -Name 'fresh-file' -ExtraArgs @('-Port', '8080') `
    -EnvOverrides @{ FSEVEN_TEST_ENV_DUMP = $dump; FSEVEN_TEST_HEALTHCHECK = 'yes'; FSEVEN_TEST_BOOTSTRAP_READY = 'no' }
if ($back.ExitCode -ne 0) { Fail "the re-run with -Port 8080 exited $($back.ExitCode)" }
if ($back.Output -notmatch 'Existing \.env PORT=9090 replaced by PORT=8080') { Fail "-Port 8080 over 9090 was not honoured (PAB4)" }
if ((Read-TextFile $dump) -notmatch '(?m)^PORT=8080\s*$') { Fail "docker compose up did not run with PORT=8080 after -Port 8080 (PAB4)" }
if ((Get-EnvValue $envFile 'PORT') -ne '8080') { Fail ".env PORT is not 8080 after -Port 8080 (PAB4)" }
Pass "PAB4: -Port 8080 over 9090 moves it back (the default value, given, still wins)"

Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "`ninstall.ps1 Windows PowerShell 5.1 gate passed" -ForegroundColor Green
