<#
.SYNOPSIS
    Log collector (Windows) — streams combined backend + frontend logs into
    date-rolled files under logs\app-YYYY-MM-DD.log, each line tagged
    [backend] / [frontend]. The filename is recomputed per line so it rolls
    over automatically at midnight. Runs until the process is stopped.

.PARAMETER ComposeFile
    Optional compose file (e.g. docker-compose.local.yml).
#>
param(
    [string]$ComposeFile = ''
)

$ErrorActionPreference = 'SilentlyContinue'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot  = Split-Path -Parent $scriptDir
Set-Location $repoRoot

$logDir = Join-Path $repoRoot 'logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null

# Detect Docker Compose command (v2 plugin preferred, fall back to v1)
docker compose version 2>$null | Out-Null
if ($LASTEXITCODE -eq 0) {
    $exe = 'docker'; $prefix = @('compose')
} elseif (Get-Command docker-compose -ErrorAction SilentlyContinue) {
    $exe = 'docker-compose'; $prefix = @()
} else {
    Write-Error "Docker Compose not found (need 'docker compose' v2 or 'docker-compose' v1)"
    exit 1
}

$fileArgs = @()
if ($ComposeFile -ne '') { $fileArgs = @('-f', $ComposeFile) }

# Follow logs, reconnecting if the stream drops (containers recreated).
# --tail 0 => only new lines, so reconnects do not re-dump history.
while ($true) {
    & $exe @prefix @fileArgs logs -f --no-color --tail 0 2>&1 | ForEach-Object {
        $line = [string]$_
        $svc = ''
        $msg = $line

        # Compose prefixes each line as "service-1  | message"
        $idx = $line.IndexOf('|')
        if ($idx -ge 0) {
            $svc = $line.Substring(0, $idx)
            $msg = $line.Substring($idx + 1).TrimStart()
        }

        if ($svc -match 'backend') {
            $tag = '[backend] '
        } elseif ($svc -match 'frontend') {
            $tag = '[frontend]'
        } else {
            $tag = '[other]   '
        }

        $ts   = Get-Date -Format 'HH:mm:ss'
        $file = Join-Path $logDir ('app-' + (Get-Date -Format 'yyyy-MM-dd') + '.log')
        Add-Content -LiteralPath $file -Value "$ts $tag $msg" -Encoding UTF8
    }

    # Stream ended (stack down or recreated) — wait briefly and reconnect
    Start-Sleep -Seconds 3
}
