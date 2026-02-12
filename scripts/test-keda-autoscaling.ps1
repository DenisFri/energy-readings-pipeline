#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Tests KEDA autoscaling by flooding the ingestion API with readings
    and monitoring the processing service replica count.

.DESCRIPTION
    This script:
    1. Checks KEDA is installed and the ScaledObject exists
    2. Shows current state (replicas, stream pending count)
    3. Floods the ingestion API with readings to build a backlog
    4. Monitors pod scaling in real-time
    5. Waits for scale-down after backlog is cleared

.PARAMETER Namespace
    Kubernetes namespace where the release is deployed (default: energy-pipeline)

.PARAMETER TotalMessages
    Number of readings to send (default: 100)

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
    [int]$TotalMessages = 100,
    [int]$ConcurrentBatches = 10,
    [string]$IngressUrl = ""
)

$ErrorActionPreference = "Stop"

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

# Check KEDA CRDs exist
Write-Header "Preflight Checks"

$kedaCRD = kubectl get crd scaledobjects.keda.sh --no-headers 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Err "KEDA CRDs not found. Install KEDA first:"
    Write-Host "  helm repo add kedacore https://kedacore.github.io/charts"
    Write-Host "  helm install keda kedacore/keda --namespace keda --create-namespace"
    exit 1
}
Write-Ok "KEDA CRDs found"

# Check ScaledObject exists
$scaledObj = kubectl get scaledobject -n $Namespace --no-headers 2>&1
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($scaledObj)) {
    Write-Err "No ScaledObject found in namespace '$Namespace'. Make sure keda.enabled=true in values.yaml"
    exit 1
}
Write-Ok "ScaledObject found: $($scaledObj.Trim())"

# --- Show Initial State ---
Write-Header "Initial State"

Write-Info "Processing Service pods:"
kubectl get pods -n $Namespace -l "app.kubernetes.io/component=processing-service" --no-headers

Write-Info "ScaledObject status:"
kubectl get scaledobject -n $Namespace

# Check ScaledObject health
Write-Info "ScaledObject events (last 5):"
kubectl get events -n $Namespace --field-selector involvedObject.kind=ScaledObject --sort-by='.lastTimestamp' 2>&1 | Select-Object -Last 6

# --- Setup Port Forward or External URL ---
$portForwardJob = $null
$ReadingsEndpoint = ""
$HealthEndpoint = ""

if ([string]::IsNullOrWhiteSpace($IngressUrl)) {
    Write-Header "Setting Up Port Forward"

    # Find ingestion-api pod
    $ingestPod = kubectl get pods -n $Namespace -l "app.kubernetes.io/component=ingestion-api" -o jsonpath="{.items[0].metadata.name}" 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Err "Cannot find ingestion-api pod in namespace '$Namespace'"
        exit 1
    }

    # Port forward in background (directly to ingestion-api service)
    $portForwardJob = Start-Job -ScriptBlock {
        param($ns, $pod)
        kubectl port-forward -n $ns $pod 8080:8000
    } -ArgumentList $Namespace, $ingestPod

    Start-Sleep -Seconds 3
    $BaseUrl = "http://localhost:8080"
    # Direct to ingestion API: paths are /readings and /health
    $ReadingsEndpoint = "$BaseUrl/readings"
    $HealthEndpoint = "$BaseUrl/health"
    Write-Ok "Port forward active: $BaseUrl -> $ingestPod (direct to ingestion API)"
} else {
    $BaseUrl = $IngressUrl.TrimEnd("/")
    # Through frontend nginx proxy: /api/readings -> /readings
    $ReadingsEndpoint = "$BaseUrl/api/readings"
    $HealthEndpoint = "$BaseUrl"  # Frontend serves HTML at /
    Write-Ok "Using external URL: $BaseUrl (through frontend proxy)"
    Write-Info "Readings endpoint: $ReadingsEndpoint"
}

# --- Verify API is reachable ---
Write-Header "Verifying API"
try {
    if ([string]::IsNullOrWhiteSpace($IngressUrl)) {
        # Direct port-forward: check /health
        $health = Invoke-RestMethod -Uri $HealthEndpoint -Method Get -TimeoutSec 10
        Write-Ok "Ingestion API healthy: $($health.status)"
    } else {
        # External URL: test with a simple GET to the frontend
        $response = Invoke-WebRequest -Uri $HealthEndpoint -Method Get -TimeoutSec 10 -UseBasicParsing
        if ($response.StatusCode -eq 200) {
            Write-Ok "Frontend reachable at $BaseUrl"
        }
        # Also test the /api/readings endpoint with a test POST
        Write-Info "Testing readings endpoint with a probe..."
        $probeBody = @{
            site_id       = "probe-test"
            device_id     = "probe-1"
            power_reading = 1.0
            timestamp     = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
        } | ConvertTo-Json

        try {
            $probeResult = Invoke-RestMethod -Uri $ReadingsEndpoint `
                -Method Post `
                -ContentType "application/json" `
                -Body $probeBody `
                -TimeoutSec 10
            Write-Ok "Readings endpoint working: stream_id=$($probeResult.stream_id)"
        } catch {
            Write-Err "Readings endpoint failed: $($_.Exception.Message)"
            Write-Err "URL: $ReadingsEndpoint"
            Write-Info "Make sure the Cloudflare tunnel is routing to the frontend service."
            if ($portForwardJob) { Stop-Job $portForwardJob; Remove-Job $portForwardJob }
            exit 1
        }
    }
} catch {
    Write-Err "Cannot reach API at $HealthEndpoint"
    Write-Err $_.Exception.Message
    if ($portForwardJob) { Stop-Job $portForwardJob; Remove-Job $portForwardJob }
    exit 1
}

# --- Flood the Stream ---
Write-Header "Flooding Stream with $TotalMessages Messages"
Write-Info "This will build a backlog that triggers KEDA to scale up processing pods..."
Write-Info "Endpoint: $ReadingsEndpoint"
Write-Host ""

$sent = 0
$errors = 0
$lastError = ""
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

# Send in batches
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
                    -Method Post `
                    -ContentType "application/json" `
                    -Body $jsonBody `
                    -TimeoutSec 30
                return @{ success = $true; stream_id = $response.stream_id }
            } catch {
                return @{ success = $false; error = $_.Exception.Message }
            }
        } -ArgumentList $ReadingsEndpoint, $body
    }

    # Wait for batch to complete
    $results = $jobs | Wait-Job | Receive-Job
    $jobs | Remove-Job

    foreach ($r in $results) {
        if ($r.success) {
            $sent++
        } else {
            $errors++
            $lastError = $r.error
        }
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
if ($errors -gt 0 -and $lastError) {
    Write-Err "Last error: $lastError"
}

if ($sent -eq 0) {
    Write-Err "No messages were sent successfully. Cannot test scaling."
    Write-Info "Check that the ingestion API is reachable and Redis is running."
    if ($portForwardJob) { Stop-Job $portForwardJob; Remove-Job $portForwardJob }
    exit 1
}

# --- Monitor Scaling ---
Write-Header "Monitoring KEDA Scaling (watching for ~2 minutes)"
Write-Info "KEDA polls every ~15-30s. Watch for replica count changes..."
Write-Info "Press Ctrl+C to stop monitoring early."
Write-Host ""

$maxWait = 120  # seconds
$elapsed = 0
$prevReplicas = -1
$scaledUp = $false

while ($elapsed -lt $maxWait) {
    # Get current replica count
    $replicas = kubectl get deployment -n $Namespace `
        -l "app.kubernetes.io/component=processing-service" `
        -o jsonpath="{.items[0].status.replicas}" 2>&1

    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($replicas)) { $replicas = "?" }

    $readyReplicas = kubectl get deployment -n $Namespace `
        -l "app.kubernetes.io/component=processing-service" `
        -o jsonpath="{.items[0].status.readyReplicas}" 2>&1

    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($readyReplicas)) { $readyReplicas = "0" }

    # Get HPA info (KEDA creates an HPA) — may not exist yet
    $hpaDesired = "n/a"
    try {
        $hpaResult = kubectl get hpa -n $Namespace -o jsonpath="{.items[0].status.desiredReplicas}" 2>&1
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($hpaResult)) {
            $hpaDesired = $hpaResult
        }
    } catch {
        $hpaDesired = "n/a"
    }

    $timestamp = (Get-Date).ToString("HH:mm:ss")

    if ($replicas -ne "?" -and $replicas -ne $prevReplicas) {
        if ($prevReplicas -ne -1) {
            Write-Host ""
            try {
                if ([int]$replicas -gt [int]$prevReplicas) {
                    Write-Host "  >>> SCALED UP: $prevReplicas -> $replicas replicas <<<" -ForegroundColor Green
                    $scaledUp = $true
                } elseif ([int]$replicas -lt [int]$prevReplicas) {
                    Write-Host "  >>> SCALED DOWN: $prevReplicas -> $replicas replicas <<<" -ForegroundColor Magenta
                }
            } catch {
                # Ignore parse errors
            }
        }
        $prevReplicas = $replicas
    }

    Write-Host "`r  [$timestamp] Replicas: $readyReplicas/$replicas ready | HPA desired: $hpaDesired | Elapsed: ${elapsed}s   " -NoNewline

    Start-Sleep -Seconds 5
    $elapsed += 5
}

Write-Host ""

# --- Final State ---
Write-Header "Final State"

Write-Info "Processing Service pods:"
kubectl get pods -n $Namespace -l "app.kubernetes.io/component=processing-service"

Write-Info "ScaledObject:"
kubectl get scaledobject -n $Namespace

Write-Info "HPA (created by KEDA):"
$hpaOutput = kubectl get hpa -n $Namespace 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-Host $hpaOutput
} else {
    Write-Host "  No HPA found (KEDA may not have created one yet)"
}

Write-Info "ScaledObject details:"
kubectl describe scaledobject -n $Namespace 2>&1 | Select-String -Pattern "Type|Status|Message|Reason|Ready|Active" | Select-Object -First 10

if ($scaledUp) {
    Write-Host ""
    Write-Ok "SUCCESS: KEDA autoscaling worked! Pods scaled up in response to stream backlog."
} else {
    Write-Host ""
    Write-Info "Pods didn't scale during the monitoring window."
    Write-Info "This could mean:"
    Write-Info "  - Processing was fast enough to keep up (no backlog > threshold of 5)"
    Write-Info "  - KEDA polling interval hasn't triggered yet (try waiting longer)"
    Write-Info "  - ScaledObject is not READY (check events below)"
    Write-Info "  - Try increasing -TotalMessages (e.g. 500)"
    Write-Host ""
    Write-Info "Debug commands:"
    Write-Host "  kubectl describe scaledobject -n $Namespace"
    Write-Host "  kubectl get events -n $Namespace --field-selector involvedObject.kind=ScaledObject"
    Write-Host "  kubectl logs -n keda -l app=keda-operator --tail=50"
}

# --- Cleanup ---
Write-Header "Cleanup"
if ($portForwardJob) {
    Stop-Job $portForwardJob -ErrorAction SilentlyContinue
    Remove-Job $portForwardJob -ErrorAction SilentlyContinue
    Write-Ok "Port forward stopped"
}

Write-Info "Load test data was written to sites: load-test-site-1 through load-test-site-5"
Write-Info "To clean up test data, you can delete those keys from Redis:"
Write-Host "  kubectl exec -n $Namespace deploy/energy-pipeline-redis-master -- redis-cli DEL site:load-test-site-1:readings site:load-test-site-2:readings site:load-test-site-3:readings site:load-test-site-4:readings site:load-test-site-5:readings"

Write-Host ""
Write-Info "To keep monitoring manually:"
Write-Host "  kubectl get pods -n $Namespace -l app.kubernetes.io/component=processing-service -w"
Write-Host "  kubectl get hpa -n $Namespace -w"
Write-Host "  kubectl describe scaledobject -n $Namespace"
Write-Host "  kubectl logs -n keda -l app=keda-operator --tail=50"
