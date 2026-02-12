#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Tests KEDA autoscaling by flooding the ingestion API with readings
    and monitoring the processing service replica count.

.DESCRIPTION
    This script:
    1. Checks KEDA is installed and the ScaledObject exists
    2. Scales the processing service to 0 so messages pile up
    3. Floods the ingestion API with readings to build a backlog
    4. Restores the processor and monitors KEDA-driven scaling
    5. Reports whether scale-up was observed

.PARAMETER Namespace
    Kubernetes namespace where the release is deployed (default: energy-pipeline)

.PARAMETER TotalMessages
    Number of readings to send (default: 50)

.PARAMETER ConcurrentBatches
    Number of parallel batches to send at once (default: 10)

.PARAMETER IngressUrl
    External URL if using ingress/tunnel (e.g. https://energy.frishchin.com).
    When set, requests go through the frontend proxy (/api/readings).
    When empty, port-forwards directly to the ingestion API (/readings).

.EXAMPLE
    .\test-keda-autoscaling.ps1
    .\test-keda-autoscaling.ps1 -Namespace default -TotalMessages 200
    .\test-keda-autoscaling.ps1 -IngressUrl "https://energy.frishchin.com"
#>

param(
    [string]$Namespace = "energy-pipeline",
    [int]$TotalMessages = 50,
    [int]$ConcurrentBatches = 10,
    [string]$IngressUrl = ""
)

$ErrorActionPreference = "Stop"
$DeploymentName = "energy-pipeline-processing-service"

# --- Colors & helpers ---
function Write-Header($msg) { Write-Host "`n=== $msg ===" -ForegroundColor Cyan }
function Write-Ok($msg)     { Write-Host "[OK] $msg" -ForegroundColor Green }
function Write-Info($msg)   { Write-Host "[INFO] $msg" -ForegroundColor Yellow }
function Write-Err($msg)    { Write-Host "[ERROR] $msg" -ForegroundColor Red }

# --- Preflight Checks ---
Write-Header "KEDA Autoscaling Test"
Write-Host "Namespace:       $Namespace"
Write-Host "Total messages:  $TotalMessages"
Write-Host "Concurrency:     $ConcurrentBatches"
Write-Host ""

Write-Header "Preflight Checks"

$kedaCRD = kubectl get crd scaledobjects.keda.sh --no-headers 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Err "KEDA CRDs not found. Install KEDA first:"
    Write-Host "  helm repo add kedacore https://kedacore.github.io/charts"
    Write-Host "  helm install keda kedacore/keda --namespace keda --create-namespace"
    exit 1
}
Write-Ok "KEDA CRDs found"

$scaledObj = kubectl get scaledobject -n $Namespace --no-headers 2>&1
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($scaledObj)) {
    Write-Err "No ScaledObject found in namespace '$Namespace'. Make sure keda.enabled=true in values.yaml"
    exit 1
}
Write-Ok "ScaledObject found"

# --- Show Initial State ---
Write-Header "Initial State"

Write-Info "Processing Service pods:"
kubectl get pods -n $Namespace -l "app.kubernetes.io/component=processing-service" --no-headers

Write-Info "ScaledObject status:"
kubectl get scaledobject -n $Namespace

# --- Setup Port Forward or External URL ---
$portForwardJob = $null
$ReadingsEndpoint = ""

if ([string]::IsNullOrWhiteSpace($IngressUrl)) {
    Write-Header "Setting Up Port Forward"
    $ingestPod = kubectl get pods -n $Namespace -l "app.kubernetes.io/component=ingestion-api" -o jsonpath="{.items[0].metadata.name}" 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Err "Cannot find ingestion-api pod in namespace '$Namespace'"
        exit 1
    }

    $portForwardJob = Start-Job -ScriptBlock {
        param($ns, $pod)
        kubectl port-forward -n $ns $pod 8080:8000
    } -ArgumentList $Namespace, $ingestPod

    Start-Sleep -Seconds 3
    $BaseUrl = "http://localhost:8080"
    $ReadingsEndpoint = "$BaseUrl/readings"
    $HealthEndpoint = "$BaseUrl/health"
    Write-Ok "Port forward active: $BaseUrl -> $ingestPod"
} else {
    $BaseUrl = $IngressUrl.TrimEnd("/")
    $ReadingsEndpoint = "$BaseUrl/api/readings"
    $HealthEndpoint = "$BaseUrl"
    Write-Ok "Using external URL: $BaseUrl (through frontend proxy)"
    Write-Info "Readings endpoint: $ReadingsEndpoint"
}

# --- Verify API ---
Write-Header "Verifying API"
try {
    if ([string]::IsNullOrWhiteSpace($IngressUrl)) {
        $health = Invoke-RestMethod -Uri $HealthEndpoint -Method Get -TimeoutSec 10
        Write-Ok "Ingestion API healthy: $($health.status)"
    } else {
        $null = Invoke-WebRequest -Uri $HealthEndpoint -Method Get -TimeoutSec 10 -UseBasicParsing
        Write-Ok "Frontend reachable at $BaseUrl"

        Write-Info "Testing readings endpoint with a probe..."
        $probeBody = @{
            site_id       = "probe-test"
            device_id     = "probe-1"
            power_reading = 1.0
            timestamp     = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
        } | ConvertTo-Json

        $probeResult = Invoke-RestMethod -Uri $ReadingsEndpoint `
            -Method Post -ContentType "application/json" -Body $probeBody -TimeoutSec 10
        Write-Ok "Readings endpoint working: stream_id=$($probeResult.stream_id)"
    }
} catch {
    Write-Err "Cannot reach API: $($_.Exception.Message)"
    if ($portForwardJob) { Stop-Job $portForwardJob; Remove-Job $portForwardJob }
    exit 1
}

# =======================================================================
# PHASE 1: Pause the processor so messages pile up in the stream
# =======================================================================
Write-Header "Phase 1: Pausing Processing Service"
Write-Info "Scaling processing service to 0 replicas so messages accumulate..."

# Pause the KEDA ScaledObject so it doesn't fight our manual scale
kubectl annotate scaledobject -n $Namespace energy-pipeline-processing-scaler `
    autoscaling.keda.sh/paused-replicas="0" --overwrite 2>&1 | Out-Null
Write-Ok "KEDA ScaledObject paused (annotated with paused-replicas=0)"

# Scale to 0
kubectl scale deployment $DeploymentName -n $Namespace --replicas=0 2>&1 | Out-Null
Write-Info "Waiting for processor pods to terminate..."
kubectl wait --for=delete pod -n $Namespace -l "app.kubernetes.io/component=processing-service" --timeout=30s 2>&1 | Out-Null
Write-Ok "Processing service scaled to 0 — no consumers running"

# =======================================================================
# PHASE 2: Flood the stream (all messages become pending)
# =======================================================================
Write-Header "Phase 2: Flooding Stream with $TotalMessages Messages"
Write-Info "With no consumers, all messages will pile up as pending entries..."
Write-Info "Endpoint: $ReadingsEndpoint"
Write-Host ""

$sent = 0
$errors = 0
$lastError = ""
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
                return @{ success = $true; stream_id = $response.stream_id }
            } catch {
                return @{ success = $false; error = $_.Exception.Message }
            }
        } -ArgumentList $ReadingsEndpoint, $body
    }

    $results = $jobs | Wait-Job | Receive-Job
    $jobs | Remove-Job

    foreach ($r in $results) {
        if ($r.success) { $sent++ } else { $errors++; $lastError = $r.error }
    }

    $pct = [Math]::Round(($sent + $errors) / $TotalMessages * 100, 0)
    Write-Host "`r  Sent: $sent / $TotalMessages ($pct%%) | Errors: $errors" -NoNewline
}

$stopwatch.Stop()
Write-Host ""
Write-Ok "Flood complete: $sent sent, $errors errors in $([Math]::Round($stopwatch.Elapsed.TotalSeconds, 1))s"
if ($sent -gt 0) {
    Write-Host "  Rate: $([Math]::Round($sent / $stopwatch.Elapsed.TotalSeconds, 1)) msg/s"
}
if ($errors -gt 0 -and $lastError) { Write-Err "Last error: $lastError" }

if ($sent -eq 0) {
    Write-Err "No messages sent. Restoring processor and exiting."
    kubectl annotate scaledobject -n $Namespace energy-pipeline-processing-scaler `
        autoscaling.keda.sh/paused-replicas- --overwrite 2>&1 | Out-Null
    kubectl scale deployment $DeploymentName -n $Namespace --replicas=1 2>&1 | Out-Null
    if ($portForwardJob) { Stop-Job $portForwardJob; Remove-Job $portForwardJob }
    exit 1
}

# Check stream length
Write-Info "Checking stream backlog..."
$streamLen = kubectl exec -n $Namespace deploy/energy-pipeline-redis-master -- redis-cli XLEN energy_readings 2>&1
Write-Ok "Stream length (total messages in stream): $($streamLen.Trim())"

# Check pending entries count for the consumer group
$pendingInfo = kubectl exec -n $Namespace deploy/energy-pipeline-redis-master -- redis-cli XPENDING energy_readings processing_group 2>&1
Write-Info "Consumer group pending info:"
Write-Host "  $pendingInfo"

# =======================================================================
# PHASE 3: Un-pause KEDA and let it scale
# =======================================================================
Write-Header "Phase 3: Resuming KEDA — Watching for Autoscaling"
Write-Info "Removing paused annotation from ScaledObject..."
Write-Info "KEDA will detect the $sent pending entries (threshold: 5) and scale up..."

# Remove the paused annotation so KEDA takes control
kubectl annotate scaledobject -n $Namespace energy-pipeline-processing-scaler `
    autoscaling.keda.sh/paused-replicas- --overwrite 2>&1 | Out-Null
Write-Ok "KEDA ScaledObject un-paused — KEDA is now in control"

Write-Host ""
Write-Info "Monitoring replica count (KEDA polls every ~15-30s)..."
Write-Info "Press Ctrl+C to stop monitoring early."
Write-Host ""

$maxWait = 180  # 3 minutes
$elapsed = 0
$prevReplicas = -1
$scaledUp = $false
$maxObservedReplicas = 0

while ($elapsed -lt $maxWait) {
    $replicas = kubectl get deployment $DeploymentName -n $Namespace `
        -o jsonpath="{.status.replicas}" 2>&1
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($replicas)) { $replicas = "0" }

    $readyReplicas = kubectl get deployment $DeploymentName -n $Namespace `
        -o jsonpath="{.status.readyReplicas}" 2>&1
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($readyReplicas)) { $readyReplicas = "0" }

    $hpaDesired = "n/a"
    try {
        $hpaResult = kubectl get hpa -n $Namespace -o jsonpath="{.items[0].status.desiredReplicas}" 2>&1
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($hpaResult) -and $hpaResult -notmatch "error") {
            $hpaDesired = $hpaResult
        }
    } catch {}

    $timestamp = (Get-Date).ToString("HH:mm:ss")

    # Track max replicas
    try { if ([int]$replicas -gt $maxObservedReplicas) { $maxObservedReplicas = [int]$replicas } } catch {}

    if ($replicas -ne $prevReplicas) {
        if ($prevReplicas -ne -1) {
            Write-Host ""
            try {
                if ([int]$replicas -gt [int]$prevReplicas) {
                    Write-Host "  >>> SCALED UP: $prevReplicas -> $replicas replicas <<<" -ForegroundColor Green
                    $scaledUp = $true
                } elseif ([int]$replicas -lt [int]$prevReplicas) {
                    Write-Host "  >>> SCALED DOWN: $prevReplicas -> $replicas replicas <<<" -ForegroundColor Magenta
                }
            } catch {}
        }
        $prevReplicas = $replicas
    }

    Write-Host "`r  [$timestamp] Replicas: $readyReplicas/$replicas ready | HPA desired: $hpaDesired | Elapsed: ${elapsed}s   " -NoNewline

    Start-Sleep -Seconds 5
    $elapsed += 5
}

Write-Host "`n"

# --- Final State ---
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

Write-Info "ScaledObject conditions:"
kubectl describe scaledobject -n $Namespace 2>&1 | Select-String -Pattern "Type|Status|Message|Reason|Ready|Active" | Select-Object -First 10

if ($scaledUp) {
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Green
    Write-Ok "SUCCESS: KEDA autoscaling verified!"
    Write-Host "  Max replicas observed: $maxObservedReplicas (limit: 3)" -ForegroundColor Green
    Write-Host "  KEDA detected $sent pending entries and scaled processing pods." -ForegroundColor Green
    Write-Host "============================================================" -ForegroundColor Green
} else {
    Write-Host ""
    Write-Info "Pods didn't scale during the monitoring window."
    Write-Info "Debug commands:"
    Write-Host "  kubectl describe scaledobject -n $Namespace"
    Write-Host "  kubectl logs -n keda -l app=keda-operator --tail=50"
}

# --- Cleanup ---
Write-Header "Cleanup"
if ($portForwardJob) {
    Stop-Job $portForwardJob -ErrorAction SilentlyContinue
    Remove-Job $portForwardJob -ErrorAction SilentlyContinue
    Write-Ok "Port forward stopped"
}

Write-Info "Load test data in sites: load-test-site-1 through load-test-site-5"
Write-Info "To clean up test data from Redis:"
Write-Host "  kubectl exec -n $Namespace deploy/energy-pipeline-redis-master -- redis-cli DEL site:load-test-site-1:readings site:load-test-site-2:readings site:load-test-site-3:readings site:load-test-site-4:readings site:load-test-site-5:readings"
