<#
.SYNOPSIS
    Local (development) deployment for the Image Reconstruction App on Windows.

    Runs frontend (Nginx) + backend (FastAPI) via Docker Compose over plain HTTP
    on localhost — no domain or SSL. Auto-downloads the model weights if missing,
    waits until both services are actually ready, then starts a background log
    collector and prints the URL + management commands.

    Requires Docker Desktop (provides `docker compose`).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\deploy-local.ps1
#>

$ErrorActionPreference = 'Stop'

function Write-Ok   ($m) { Write-Host "[OK] $m" -ForegroundColor Green }
function Write-Err  ($m) { Write-Host "[X]  $m" -ForegroundColor Red }
function Write-Info ($m) { Write-Host "[>]  $m" -ForegroundColor Cyan }
function Write-Warn ($m) { Write-Host "[!]  $m" -ForegroundColor Yellow }

# Run from the repo root regardless of where invoked
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot  = Split-Path -Parent $scriptDir
Set-Location $repoRoot

$composeFile = 'docker-compose.local.yml'

Write-Host ""
Write-Host "==============================================================="
Write-Host "  Image Reconstruction App - Local Deployment (Windows, HTTP)"
Write-Host "==============================================================="
Write-Host ""

############################################################################
# Prerequisites
############################################################################
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Err "Docker is not installed. Install Docker Desktop: https://www.docker.com/products/docker-desktop/"
    exit 1
}

# Detect Docker Compose command (v2 plugin preferred, fall back to v1)
docker compose version 2>$null | Out-Null
if ($LASTEXITCODE -eq 0) {
    $composeExe = 'docker'; $composePrefix = @('compose')
} elseif (Get-Command docker-compose -ErrorAction SilentlyContinue) {
    $composeExe = 'docker-compose'; $composePrefix = @()
} else {
    Write-Err "Docker Compose not found (need 'docker compose' v2 or 'docker-compose' v1)"
    exit 1
}
$composeDisplay = (($composeExe + ' ' + ($composePrefix -join ' ')).Trim())
Write-Ok "Using Docker + $composeDisplay"

# Verify the Docker engine is actually running
docker info 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Err "Docker engine is not running. Start Docker Desktop and retry."
    exit 1
}

if (-not (Test-Path $composeFile)) {
    Write-Err "$composeFile not found in repository"
    exit 1
}
Write-Host ""

############################################################################
# Model files
############################################################################
function Get-Models {
    $modelDir = Join-Path $repoRoot 'backend\model'
    New-Item -ItemType Directory -Force -Path $modelDir | Out-Null

    $base  = 'https://github.com/kusandriadi/image-reconstruction-app/releases/download/models-v1'
    $files = @('ConvNext_REAL-ESRGAN.pth', 'REAL-ESRGAN.pth')

    foreach ($f in $files) {
        $out = Join-Path $modelDir $f
        if ((Test-Path $out) -and ((Get-Item $out).Length -gt 1MB)) {
            Write-Ok "$f already present"
            continue
        }
        Write-Info "Downloading $f from GitHub Release (models-v1)..."
        $url = "$base/$f"
        try {
            Start-BitsTransfer -Source $url -Destination $out -ErrorAction Stop
        } catch {
            $ProgressPreference = 'SilentlyContinue'
            Invoke-WebRequest -Uri $url -OutFile $out -UseBasicParsing
        }
        if ((Test-Path $out) -and ((Get-Item $out).Length -gt 1MB)) {
            Write-Ok "$f downloaded"
        } else {
            Write-Err "Failed to download $f"
            exit 1
        }
    }
}

Write-Info "Checking model files..."
$haveModels = (Test-Path (Join-Path $repoRoot 'backend\model\REAL-ESRGAN.pth')) -and `
              (Test-Path (Join-Path $repoRoot 'backend\model\ConvNext_REAL-ESRGAN.pth'))
if ($haveModels) {
    Write-Ok "Model files already present"
} else {
    Get-Models
}
Write-Host ""

############################################################################
# Build & start
############################################################################
Write-Info "Building & starting containers (first run can take several minutes)..."
& $composeExe @composePrefix -f $composeFile up -d --build
if ($LASTEXITCODE -ne 0) {
    Write-Err "Docker Compose failed to start the stack"
    exit 1
}
Write-Ok "Containers started"
Write-Host ""

############################################################################
# Start the combined log collector in the background
############################################################################
$logDir = Join-Path $repoRoot 'logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$pidFile = Join-Path $logDir '.collector.pid'

$collectorRunning = $false
if (Test-Path $pidFile) {
    $oldPid = Get-Content $pidFile -ErrorAction SilentlyContinue
    if ($oldPid -and (Get-Process -Id $oldPid -ErrorAction SilentlyContinue)) {
        $collectorRunning = $true
    }
}

if ($collectorRunning) {
    Write-Info "Log collector already running (pid $oldPid)"
} else {
    $collector = Join-Path $scriptDir 'save-logs.ps1'
    $proc = Start-Process -FilePath 'powershell' `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $collector, '-ComposeFile', $composeFile) `
        -WindowStyle Hidden -PassThru
    $proc.Id | Out-File -FilePath $pidFile -Encoding ascii
    Write-Ok "Log collector started (pid $($proc.Id)) - logs\app-YYYY-MM-DD.log"
}
Write-Host ""

############################################################################
# Wait until frontend & backend are fully ready
############################################################################
function Test-Url ($url) {
    try {
        Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 5 | Out-Null
        return $true
    } catch {
        return $false
    }
}

Write-Info "Waiting for frontend & backend to become ready..."

Write-Host -NoNewline "[>]  Waiting for backend"
$backendReady = $false
for ($i = 0; $i -lt 40; $i++) {
    if (Test-Url 'http://localhost:8000/api/health') { $backendReady = $true; break }
    Write-Host -NoNewline "."
    Start-Sleep -Seconds 3
}
Write-Host ""
if ($backendReady) {
    Write-Ok "Backend is healthy"
} else {
    Write-Err "Backend did not become healthy in time"
    Write-Info "Check logs with: $composeDisplay -f $composeFile logs backend"
    exit 1
}

Write-Host -NoNewline "[>]  Waiting for frontend"
$frontendReady = $false
for ($i = 0; $i -lt 20; $i++) {
    if (Test-Url 'http://localhost') { $frontendReady = $true; break }
    Write-Host -NoNewline "."
    Start-Sleep -Seconds 3
}
Write-Host ""
if ($frontendReady) {
    Write-Ok "Frontend is serving"
} else {
    Write-Warn "Frontend not responding yet - check: $composeDisplay -f $composeFile logs frontend"
}

############################################################################
# Summary
############################################################################
$today = Get-Date -Format 'yyyy-MM-dd'
Write-Host ""
Write-Host "==============================================================="
Write-Ok "LOCAL DEPLOYMENT COMPLETE - frontend & backend are live!"
Write-Host "==============================================================="
Write-Host ""
Write-Host "Open the app at:"
Write-Host ""
Write-Host "  Website:     http://localhost"
Write-Host "  Backend API: http://localhost:8000/api/"
Write-Host "  Health:      http://localhost:8000/api/health"
Write-Host ""
Write-Host "==============================================================="
Write-Host "Manage the application (PowerShell):"
Write-Host "==============================================================="
Write-Host "  Status:      $composeDisplay -f $composeFile ps"
Write-Host "  Live logs:   $composeDisplay -f $composeFile logs -f"
Write-Host "  Saved logs:  Get-Content logs\app-$today.log -Wait"
Write-Host "  Restart:     re-run scripts\deploy-local.ps1"
Write-Host "  Stop:        $composeDisplay -f $composeFile down"
Write-Host "               then: Stop-Process -Id (Get-Content logs\.collector.pid)"
Write-Host "==============================================================="
Write-Host ""
