#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Tests KEDA autoscaling by injecting a processing delay, flooding
    messages, and watching KEDA scale based on pendingEntriesCount.

.DESCRIPTION
    This script:
    1. Checks KEDA is installed and the ScaledObject exists
    2. Injects PROCESSING_DELAY_MS=500 into the processing service
       (each message takes 500ms to ACK, so pending entries build up)
    3. Floods the ingestion API with messages
    4. Monitors replica scaling as pending entries exceed the threshold
    5. Removes the delay and reports results

.PARAMETER Namespace
    Kubernetes namespace (default: energy-pipeline)

.PARAMETER TotalMessages
    Number of readings to send (default: 100)

.PARAMETER ConcurrentBatches
    Number of concurrent HTTP requests per batch (default: 10)

.PARAMETER DelayMs
    Processing delay in ms injected into the processor (default: 500)

.PARAMETER IngressUrl
    External URL (e.g. https://energy.frishchin.com). Uses port-forward if empty.

.EXAMPLE
    .\test-keda-autoscaling.ps1 -IngressUrl "https://energy.frishchin.com"
    .\test-keda-autoscaling.ps1 -TotalMessages 200 -DelayMs 1000
#>

param(
    [string]$Namespace = "energy-pipeline",
    [int]$TotalMessages = 100,
    [int]$ConcurrentBatches = 10,
    [int]$DelayMs = 500,
    [string]$IngressUrl = ""
)

$ErrorActionPreference = "Stop"
$DeploymentName = "energy-pipeline-processing-service"
$ScaledObjectName = "energy-pipeline-processing-scaler"

function Write-Header($msg) { Write-Host "`n=== $msg ===" -ForegroundColor Cyan }
function Write-Ok($msg)     { Write-Host "[OK] $msg" -ForegroundColor Green }
function Write-Info($msg)   { Write-Host "[INFO] $msg" -ForegroundColor Yellow }
function Write-Err($msg)    { Write-Host "[ERROR] $msg" -ForegroundColor Red }

Write-Header "KEDA Autoscaling Test (pendingEntriesCount)"
Write-Host "Namespace:       $Namespace"
Write-Host "Messages:        $TotalMessages"
Write-Host "Processing delay: ${DelayMs}ms per message"
Write-Host ""

# =====================================================================
# Preflight
# =====================================================================
Write-Header "Preflight Checks"

$kedaCRD = kubectl get crd scaledobjects.keda.sh --no-headers 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Err "KEDA CRDs not found. Install KEDA first."
    exit 1
}
Write-Ok "KEDA CRDs found"

$scaledObj = kubectl get scaledobject -n $Namespace --no-headers 2>&1
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($scaledObj)) {
    Write-Err "No ScaledObject found in namespace '$Namespace'"
    exit 1
}
Write-Ok "ScaledObject found"

# =====================================================================
# Initial State
# =====================================================================
Write-Header "Initial State"
kubectl get pods -n $Namespace -l "app.kubernetes.io/component=processing-service" --no-headers
kubectl get scaledobject -n $Namespace

# =====================================================================
# Setup endpoint
# =====================================================================
$portForwardJob = $null

if ([string]::IsNullOrWhiteSpace($IngressUrl)) {
    Write-Header "Setting Up Port Forward"
    $ingestPod = kubectl get pods -n $Namespace `
        -l "app.kubernetes.io/component=ingestion-api" `
        -o jsonpath="{.items[0].metadata.name}" 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Err "Cannot find ingestion-api pod"
        exit 1
    }
    $portForwardJob = Start-Job -ScriptBlock {
        param($ns, $pod)
        kubectl port-forward -n $ns $pod 8080:8000
    } -ArgumentList $Namespace, $ingestPod
    Start-Sleep -Seconds 3
    $ReadingsEndpoint = "http://localhost:8080/readings"
    Write-Ok "Port forward active"
} else {
    $ReadingsEndpoint = $IngressUrl.TrimEnd("/") + "/api/readings"
    Write-Ok "Using: $ReadingsEndpoint"
}

# =====================================================================
# Verify API
# =====================================================================
Write-Header "Verifying API"
$probeBody = @{
    site_id       = "probe-test"
    device_id     = "probe-1"
    power_reading = 1.0
    timestamp     = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
} | ConvertTo-Json

try {
    $probeResult = Invoke-RestMethod -Uri $ReadingsEndpoint `
        -Method Post -ContentType "application/json" -Body $probeBody -TimeoutSec 10
    Write-Ok "API working: stream_id=$($probeResult.stream_id)"
} catch {
    Write-Err "API unreachable at $ReadingsEndpoint"
    if ($portForwardJob) { Stop-Job $portForwardJob; Remove-Job $portForwardJob }
    exit 1
}

# =====================================================================
# PHASE 1: Inject processing delay
# =====================================================================
Write-Header "Phase 1: Injecting Processing Delay (${DelayMs}ms)"
Write-Info "This slows down ACKs so pending entries accumulate naturally."
Write-Info "KEDA will detect pendingEntriesCount > threshold and scale up."

kubectl set env deployment/$DeploymentName -n $Namespace PROCESSING_DELAY_MS="$DelayMs" 2>&1 | Out-Null
Write-Ok "Set PROCESSING_DELAY_MS=$DelayMs on $DeploymentName"

Write-Info "Waiting for rolling restart to complete..."
$waitStart = Get-Date
while ($true) {
    $rolloutStatus = kubectl rollout status deployment/$DeploymentName -n $Namespace --timeout=5s 2>&1
    if ($rolloutStatus -match "successfully rolled out") { break }
    if (((Get-Date) - $waitStart).TotalSeconds -gt 120) {
        Write-Err "Timeout waiting for rollout. Continuing anyway."
        break
    }
    Start-Sleep -Seconds 3
}
Write-Ok "Processing service restarted with ${DelayMs}ms delay"

# Give the new pods a moment to connect to Redis and start consuming
Start-Sleep -Seconds 5

# =====================================================================
# PHASE 2: Flood
# =====================================================================
Write-Header "Phase 2: Flooding Stream with $TotalMessages Messages"
Write-Info "With ${DelayMs}ms delay per message, pending entries will accumulate."
Write-Info "Endpoint: $ReadingsEndpoint"
Write-Host ""

$sent = 0
$errors = 0
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

$batchSize = $ConcurrentBatches
$totalBatches = [Math]::Ceiling($TotalMessages / $batchSize)

for ($batch = 0; $batch -lt $totalBatches; $batch++) {
    $jobs = @()
    $remaining = [Math]::Min($batchSize, $TotalMessages - ($batch * $batchSize))

    for ($i = 0; $i -lt $remaining; $i++) {
        $msgNum = ($batch * $batchSize) + $i + 1
        $ts = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
        $body = @{
            site_id       = "load-test-site-$(($msgNum % 5) + 1)"
            device_id     = "meter-$msgNum"
            power_reading = [Math]::Round((Get-Random -Minimum 100.0 -Maximum 5000.0), 1)
            timestamp     = $ts
        } | ConvertTo-Json

        $jobs += Start-Job -ScriptBlock {
            param($endpoint, $jsonBody)
            try {
                $response = Invoke-RestMethod -Uri $endpoint `
                    -Method Post -ContentType "application/json" -Body $jsonBody -TimeoutSec 30
                return @{ success = $true }
            } catch {
                return @{ success = $false; error = $_.Exception.Message }
            }
        } -ArgumentList $ReadingsEndpoint, $body
    }

    $results = $jobs | Wait-Job | Receive-Job
    $jobs | Remove-Job

    foreach ($r in $results) {
        if ($r.success) { $sent++ } else { $errors++ }
    }

    $pct = [Math]::Round(($sent + $errors) / $TotalMessages * 100, 0)
    $progressMsg = "`r  Sent: $sent / $TotalMessages (" + $pct + "%) | Errors: $errors"
    Write-Host -NoNewline $progressMsg
}

$stopwatch.Stop()
Write-Host ""
Write-Ok "Flood complete: $sent sent, $errors errors in $([Math]::Round($stopwatch.Elapsed.TotalSeconds, 1))s"

if ($sent -eq 0) {
    Write-Err "No messages sent. Removing delay and exiting."
    kubectl set env deployment/$DeploymentName -n $Namespace PROCESSING_DELAY_MS- 2>&1 | Out-Null
    if ($portForwardJob) { Stop-Job $portForwardJob; Remove-Job $portForwardJob }
    exit 1
}

# Show pending entries
try {
    $groupInfo = kubectl exec -n $Namespace sts/energy-pipeline-redis-master `
        -- redis-cli XINFO GROUPS energy_readings 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Info "Consumer group info:"
        Write-Host "  $groupInfo"
    }
} catch {}

# =====================================================================
# PHASE 3: Monitor scaling
# =====================================================================
Write-Header "Phase 3: Monitoring KEDA Scaling"
Write-Info "KEDA polls every 15-30s. Watching for replica changes..."
Write-Info "With ${DelayMs}ms delay, each pod processes ~$([Math]::Round(1000 / $DelayMs * 10, 0)) msg/s (batches of 10)."
Write-Host ""

$maxWait = 180
$elapsed = 0
$prevReplicas = -1
$scaledUp = $false
$maxObservedReplicas = 0
$scaleUpTime = $null

while ($elapsed -lt $maxWait) {
    $replicas = kubectl get deployment $DeploymentName -n $Namespace `
        -o jsonpath="{.status.replicas}" 2>&1
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($replicas)) { $replicas = "0" }

    $readyReplicas = kubectl get deployment $DeploymentName -n $Namespace `
        -o jsonpath="{.status.readyReplicas}" 2>&1
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($readyReplicas)) { $readyReplicas = "0" }

    $hpaDesired = "n/a"
    try {
        $hpaResult = kubectl get hpa -n $Namespace `
            -o jsonpath="{.items[0].status.desiredReplicas}" 2>&1
        if ($LASTEXITCODE -eq 0 -and $hpaResult -match '^\d+$') {
            $hpaDesired = $hpaResult
        }
    } catch {}

    # Check pending entries count
    $pending = "?"
    try {
        $pendingResult = kubectl exec -n $Namespace sts/energy-pipeline-redis-master `
            -- redis-cli XPENDING energy_readings processing_group 2>&1
        if ($LASTEXITCODE -eq 0 -and $pendingResult -match '^\d') {
            $pendingLines = $pendingResult -split "`n"
            $pending = $pendingLines[0].Trim()
        }
    } catch {}

    try { if ([int]$replicas -gt $maxObservedReplicas) { $maxObservedReplicas = [int]$replicas } } catch {}

    if ($replicas -ne $prevReplicas -and $prevReplicas -ne -1) {
        Write-Host ""
        try {
            if ([int]$replicas -gt [int]$prevReplicas) {
                Write-Host "  ** SCALED UP: $prevReplicas -> $replicas replicas **" -ForegroundColor Green
                if (-not $scaledUp) { $scaleUpTime = $elapsed }
                $scaledUp = $true
            } elseif ([int]$replicas -lt [int]$prevReplicas) {
                Write-Host "  ** SCALED DOWN: $prevReplicas -> $replicas replicas **" -ForegroundColor Magenta
            }
        } catch {}
    }
    $prevReplicas = $replicas

    $timestamp = (Get-Date).ToString("HH:mm:ss")
    $statusLine = "  [$timestamp] Replicas: $readyReplicas/$replicas | Pending: $pending | HPA desired: $hpaDesired | ${elapsed}s"
    Write-Host "`r$statusLine   " -NoNewline

    # Early exit: saw scale beyond min replicas and waited 30s to confirm
    if ($maxObservedReplicas -gt 1 -and $null -ne $scaleUpTime -and $elapsed -gt ($scaleUpTime + 30)) {
        Write-Host ""
        Write-Info "Scale-up confirmed. Stopping early."
        break
    }

    Start-Sleep -Seconds 5
    $elapsed += 5
}

Write-Host "`n"

# =====================================================================
# Final State
# =====================================================================
Write-Header "Final State"

Write-Info "Processing Service pods:"
kubectl get pods -n $Namespace -l "app.kubernetes.io/component=processing-service"

Write-Info "ScaledObject:"
kubectl get scaledobject -n $Namespace

Write-Info "HPA (created by KEDA):"
try {
    $hpaOutput = kubectl get hpa -n $Namespace 2>&1
    if ($LASTEXITCODE -eq 0 -and $hpaOutput -notmatch "No resources found") {
        Write-Host $hpaOutput
    } else {
        Write-Host "  No HPA found"
    }
} catch {
    Write-Host "  No HPA found"
}

if ($scaledUp -and $maxObservedReplicas -gt 1) {
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Green
    Write-Ok "SUCCESS: KEDA autoscaling verified!"
    Write-Host "  Max replicas observed: $maxObservedReplicas (max configured: 3)" -ForegroundColor Green
    if ($null -ne $scaleUpTime) {
        Write-Host "  Scale-up triggered at: ${scaleUpTime}s into monitoring" -ForegroundColor Green
    }
    Write-Host "  Trigger: pendingEntriesCount in consumer group" -ForegroundColor Green
    Write-Host "============================================================" -ForegroundColor Green
} elseif ($scaledUp) {
    Write-Host ""
    Write-Info "KEDA scaled from 0 to 1 (minimum), but did not scale beyond 1."
    Write-Info "Pending entries were consumed before exceeding the threshold."
    Write-Info "Try increasing -TotalMessages (e.g. 200) or -DelayMs (e.g. 1000)."
} else {
    Write-Host ""
    Write-Info "Pods did not scale during the monitoring window."
    Write-Info "Debug:"
    Write-Host "  kubectl describe scaledobject -n $Namespace"
    Write-Host "  kubectl logs -n keda -l app=keda-operator --tail=50"
}

# =====================================================================
# Cleanup
# =====================================================================
Write-Header "Cleanup"

Write-Info "Removing processing delay..."
kubectl set env deployment/$DeploymentName -n $Namespace PROCESSING_DELAY_MS- 2>&1 | Out-Null
Write-Ok "Removed PROCESSING_DELAY_MS (processor back to full speed)"

if ($portForwardJob) {
    Stop-Job $portForwardJob -ErrorAction SilentlyContinue
    Remove-Job $portForwardJob -ErrorAction SilentlyContinue
    Write-Ok "Port forward stopped"
}

Write-Info "Load test data in sites: load-test-site-1 through load-test-site-5"
Write-Info "To clean up test data from Redis:"
$delKeys = @(1..5 | ForEach-Object { "site:load-test-site-${_}:readings" }) -join " "
Write-Host "  kubectl exec -n $Namespace sts/energy-pipeline-redis-master -- redis-cli DEL $delKeys"
