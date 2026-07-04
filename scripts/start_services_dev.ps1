#!/usr/bin/env pwsh
# Start Dograh services in development mode (Windows)
# Usage: .\scripts\start_services_dev.ps1 [-NoMigrations] [-IncludeTelephonyWorkers]
#
# Note: Telephony workers (ari_manager, campaign_orchestrator) are disabled by
# default on Windows because they use Unix signal handlers not supported by the
# Windows asyncio event loop.

Param(
    [switch]$NoMigrations,
    [switch]$IncludeTelephonyWorkers
)

$ErrorActionPreference = 'Stop'

###############################################################################
### CONFIGURATION
###############################################################################

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$BaseDir   = Split-Path -Parent $ScriptDir
Set-Location $BaseDir

$EnvFile    = if ($env:DOGRAH_ENV_FILE) { $env:DOGRAH_ENV_FILE } else { Join-Path $BaseDir 'api/.env' }
$RunDir     = Join-Path $BaseDir 'run'
$LogsRoot   = Join-Path $BaseDir 'logs'
$LatestDir  = Join-Path $LogsRoot 'latest'
$VenvPath   = Join-Path $BaseDir 'venv'

Write-Host "Starting Dograh Services (DEV MODE) in BASE_DIR: $BaseDir"
Write-Host "Auto-reload enabled for api/ directory changes"
Write-Host "Environment file: $EnvFile"

###############################################################################
### 1) Load environment variables
###############################################################################

if (Test-Path $EnvFile) {
    Get-Content $EnvFile | ForEach-Object {
        $line = $_.Trim()
        if ($line -and -not $line.StartsWith('#')) {
            $parts = $line -split '=', 2
            if ($parts.Count -eq 2) {
                [Environment]::SetEnvironmentVariable($parts[0].Trim(), $parts[1].Trim().Trim('"'), 'Process')
            }
        }
    }
}

if (-not $env:UVICORN_BASE_PORT)   { $env:UVICORN_BASE_PORT = '8000' }
$DependencyCheckTimeout = if ($env:DEPENDENCY_CHECK_TIMEOUT) { [int]$env:DEPENDENCY_CHECK_TIMEOUT } else { 60 }

$HealthEndpoint    = '/api/v1/health'
$HealthMaxAttempts = if ($env:HEALTH_MAX_ATTEMPTS) { [int]$env:HEALTH_MAX_ATTEMPTS } else { 30 }
$HealthInterval    = if ($env:HEALTH_INTERVAL)     { [int]$env:HEALTH_INTERVAL }     else { 2 }

###############################################################################
### 2) Define services
###############################################################################

$serviceSpecs = @()

if ($IncludeTelephonyWorkers) {
    $serviceSpecs += @{ Name = 'ari_manager';           Cmd = "python -m api.services.telephony.ari_manager" }
    $serviceSpecs += @{ Name = 'campaign_orchestrator';  Cmd = "python -m api.services.campaign.campaign_orchestrator" }
}

$serviceSpecs += @{ Name = 'uvicorn'; Cmd = "uvicorn api.app:app --host 0.0.0.0 --port $($env:UVICORN_BASE_PORT) --reload --reload-dir api" }
$serviceSpecs += @{ Name = 'arq';     Cmd = "python -m arq api.tasks.arq.WorkerSettings --custom-log-dict api.tasks.arq.LOG_CONFIG" }

###############################################################################
### 3) Activate virtual environment
###############################################################################

$VenvActivateScript = Join-Path $VenvPath 'Scripts/Activate.ps1'

if (Test-Path $VenvActivateScript) {
    . $VenvActivateScript
    Write-Host "Virtual environment activated: $VenvPath"
} else {
    Write-Host "Warning: Virtual environment not found at $VenvPath"
    Write-Host "Continuing without virtual environment activation..."
}

function Get-EndpointFromUrl {
    param([string]$Url)

    if ($Url -notmatch '^[a-zA-Z][a-zA-Z0-9+.-]*://') {
        $Url = "http://$Url"
    }

    $uri = [Uri]$Url
    $port = $uri.Port
    if ($port -lt 0) {
        switch ($uri.Scheme) {
            'postgresql+asyncpg' { $port = 5432 }
            'redis' { $port = 6379 }
            'http' { $port = 80 }
            'https' { $port = 443 }
            default { throw "Could not determine a port from $Url" }
        }
    }

    [pscustomobject]@{
        Host = $uri.Host
        Port = $port
    }
}

function Wait-EndpointReady {
    param(
        [string]$Name,
        [string]$Url,
        [int]$TimeoutSeconds
    )

    $endpoint = Get-EndpointFromUrl $Url
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $lastError = $null

    while ((Get-Date) -lt $deadline) {
        try {
            $client = [System.Net.Sockets.TcpClient]::new()
            try {
                $async = $client.BeginConnect($endpoint.Host, $endpoint.Port, $null, $null)
                if ($async.AsyncWaitHandle.WaitOne(2000, $false) -and $client.Connected) {
                    $client.EndConnect($async)
                    return
                }
                throw 'Connection timed out'
            } finally {
                $client.Dispose()
            }
        } catch {
            $lastError = $_.Exception.Message
            Start-Sleep -Seconds 1
        }
    }

    throw "$Name was not reachable at $($endpoint.Host):$($endpoint.Port) after $TimeoutSeconds seconds. Last error: $lastError"
}

if ($env:DATABASE_URL) {
    Write-Host "Checking PostgreSQL at $($env:DATABASE_URL) ..."
    Wait-EndpointReady -Name 'PostgreSQL' -Url $env:DATABASE_URL -TimeoutSeconds $DependencyCheckTimeout
}

if ($env:REDIS_URL) {
    Write-Host "Checking Redis at $($env:REDIS_URL) ..."
    Wait-EndpointReady -Name 'Redis' -Url $env:REDIS_URL -TimeoutSeconds $DependencyCheckTimeout
}

if ($env:MINIO_ENDPOINT) {
    $minioUrl = $env:MINIO_ENDPOINT
    if ([string]::IsNullOrEmpty($minioUrl) -and $env:MINIO_PUBLIC_ENDPOINT) {
        $minioUrl = $env:MINIO_PUBLIC_ENDPOINT
    }
    if ([string]::IsNullOrEmpty($minioUrl)) {
        $minioUrl = 'http://localhost:9000'
    }
    Write-Host "Checking MinIO at $minioUrl ..."
    Wait-EndpointReady -Name 'MinIO' -Url $minioUrl -TimeoutSeconds $DependencyCheckTimeout
}

###############################################################################
### 4) Stop old services
###############################################################################

New-Item -ItemType Directory -Path $RunDir -Force | Out-Null

foreach ($spec in $serviceSpecs) {
    $pidFile = Join-Path $RunDir "$($spec.Name).pid"
    if (Test-Path $pidFile) {
        $oldPid = (Get-Content $pidFile -Raw).Trim()
        if ($oldPid) {
            $prev = $ErrorActionPreference; $ErrorActionPreference = 'SilentlyContinue'
            & taskkill /PID $oldPid /T /F 2>&1 | Out-Null
            $ErrorActionPreference = $prev
        }
        Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
    }
}

###############################################################################
### 5) Run migrations
###############################################################################

if (-not $NoMigrations) {
    alembic -c (Join-Path $BaseDir 'api/alembic.ini') upgrade head
}

###############################################################################
### 6) Prepare logs
###############################################################################

New-Item -ItemType Directory -Path $LatestDir -Force | Out-Null
Get-ChildItem $LatestDir -Filter '*.log' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue

###############################################################################
### 7) Start services
###############################################################################

foreach ($spec in $serviceSpecs) {
    $name    = $spec.Name
    $logPath = Join-Path $LatestDir "$name.log"
    $pidFile = Join-Path $RunDir "$name.pid"

    Write-Host "-> Starting $name"

    $wrapped = "cd /d `"$BaseDir`" && $($spec.Cmd) >> `"$logPath`" 2>&1"
    $proc = Start-Process cmd.exe -ArgumentList '/c', $wrapped -PassThru -WindowStyle Hidden

    Set-Content -Path $pidFile -Value $proc.Id
    Write-Host "   PID $($proc.Id) -> $logPath"
}

###############################################################################
### 8) Wait for uvicorn health check
###############################################################################

$healthUrl = "http://127.0.0.1:$($env:UVICORN_BASE_PORT)$HealthEndpoint"
Write-Host "Waiting for uvicorn health check at $healthUrl ..."

$healthy = $false
for ($attempt = 1; $attempt -le $HealthMaxAttempts; $attempt++) {
    try {
        $resp = Invoke-WebRequest -Uri $healthUrl -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop
        if ($resp.StatusCode -eq 200) {
            Write-Host "OK uvicorn healthy (attempt $attempt)"
            $healthy = $true
            break
        }
    } catch {
        # connection refused / timeout / non-200 — keep polling
    }
    Start-Sleep -Seconds $HealthInterval
}

if (-not $healthy) {
    Write-Host "FAIL uvicorn FAILED health check after $HealthMaxAttempts attempts."
    Write-Host "     Check logs: Get-Content logs/latest/uvicorn.log -Wait"
    exit 1
}

###############################################################################
### 9) Summary
###############################################################################

Write-Host ""
Write-Host "------------------------------------------------------"
Write-Host "Mode: DEVELOPMENT (auto-reload enabled)"
Write-Host ""
foreach ($spec in $serviceSpecs) {
    $procId = (Get-Content (Join-Path $RunDir "$($spec.Name).pid") -Raw).Trim()
    Write-Host "  $($spec.Name) (PID $procId) -> logs/latest/$($spec.Name).log"
}
Write-Host ""
Write-Host "Health: curl.exe http://localhost:$($env:UVICORN_BASE_PORT)/api/v1/health"
Write-Host "Logs:   Get-Content logs/latest/*.log -Wait"
Write-Host "Stop:   .\scripts\stop_services.ps1"
Write-Host "------------------------------------------------------"
