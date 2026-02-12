#!/usr/bin/env bash
#
# KEDA Autoscaling Test (pendingEntriesCount)
#
# Tests KEDA autoscaling by injecting a processing delay, flooding
# messages, and watching KEDA scale based on pendingEntriesCount.
#
# How it works:
#   1. Injects PROCESSING_DELAY_MS into the processing service
#      (each message takes N ms to ACK, so pending entries build up)
#   2. Floods the ingestion API with messages
#   3. Monitors replica scaling as pending entries exceed the threshold
#   4. Removes the delay and reports results
#
# Usage:
#   ./scripts/test-keda-autoscaling.sh [NAMESPACE] [TOTAL_MESSAGES] [INGRESS_URL] [DELAY_MS]
#
# Examples:
#   ./scripts/test-keda-autoscaling.sh energy-pipeline 100
#   ./scripts/test-keda-autoscaling.sh energy-pipeline 200 https://energy.frishchin.com 1000

set -euo pipefail

NAMESPACE="${1:-energy-pipeline}"
TOTAL_MESSAGES="${2:-100}"
INGRESS_URL="${3:-}"
DELAY_MS="${4:-500}"

DEPLOYMENT_NAME="energy-pipeline-processing-service"
SCALED_OBJECT_NAME="energy-pipeline-processing-scaler"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

header() { echo -e "\n${CYAN}=== $1 ===${NC}"; }
ok()     { echo -e "${GREEN}[OK]${NC} $1"; }
info()   { echo -e "${YELLOW}[INFO]${NC} $1"; }
err()    { echo -e "${RED}[ERROR]${NC} $1"; }

# --- Preflight ---
header "KEDA Autoscaling Test (pendingEntriesCount)"
echo "Namespace:        $NAMESPACE"
echo "Total messages:   $TOTAL_MESSAGES"
echo "Processing delay: ${DELAY_MS}ms per message"
echo ""

header "Preflight Checks"

if ! kubectl get crd scaledobjects.keda.sh &>/dev/null; then
    err "KEDA CRDs not found. Install KEDA first:"
    echo "  helm repo add kedacore https://kedacore.github.io/charts"
    echo "  helm install keda kedacore/keda --namespace keda --create-namespace"
    exit 1
fi
ok "KEDA CRDs found"

if ! kubectl get scaledobject -n "$NAMESPACE" --no-headers 2>/dev/null | grep -q .; then
    err "No ScaledObject found in namespace '$NAMESPACE'"
    exit 1
fi
ok "ScaledObject found"

# --- Initial State ---
header "Initial State"
info "Processing Service pods:"
kubectl get pods -n "$NAMESPACE" -l "app.kubernetes.io/component=processing-service" --no-headers
echo ""
info "ScaledObject:"
kubectl get scaledobject -n "$NAMESPACE"

# --- Port Forward or External URL ---
PORT_FORWARD_PID=""
READINGS_ENDPOINT=""

if [ -z "$INGRESS_URL" ]; then
    header "Setting Up Port Forward"
    INGEST_POD=$(kubectl get pods -n "$NAMESPACE" -l "app.kubernetes.io/component=ingestion-api" -o jsonpath="{.items[0].metadata.name}")
    kubectl port-forward -n "$NAMESPACE" "$INGEST_POD" 8080:8000 &>/dev/null &
    PORT_FORWARD_PID=$!
    sleep 3
    BASE_URL="http://localhost:8080"
    READINGS_ENDPOINT="$BASE_URL/readings"
    ok "Port forward active: $BASE_URL -> $INGEST_POD (direct to ingestion API)"
else
    BASE_URL="${INGRESS_URL%/}"
    READINGS_ENDPOINT="$BASE_URL/api/readings"
    ok "Using external URL: $BASE_URL (through frontend proxy)"
    info "Readings endpoint: $READINGS_ENDPOINT"
fi

cleanup() {
    info "Removing processing delay..."
    kubectl set env deployment/$DEPLOYMENT_NAME -n "$NAMESPACE" PROCESSING_DELAY_MS- 2>/dev/null || true
    ok "Removed PROCESSING_DELAY_MS (processor back to full speed)"
    if [ -n "$PORT_FORWARD_PID" ]; then
        kill "$PORT_FORWARD_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# --- Verify API ---
header "Verifying API"
PROBE_TS=$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST "$READINGS_ENDPOINT" \
    -H "Content-Type: application/json" \
    -d "{\"site_id\":\"probe-test\",\"device_id\":\"probe-1\",\"power_reading\":1.0,\"timestamp\":\"$PROBE_TS\"}")

if [ "$HTTP_CODE" = "201" ]; then
    ok "API working (HTTP 201)"
else
    err "API returned HTTP $HTTP_CODE at $READINGS_ENDPOINT"
    exit 1
fi

# =====================================================================
# PHASE 1: Inject processing delay
# =====================================================================
header "Phase 1: Injecting Processing Delay (${DELAY_MS}ms)"
info "This slows down ACKs so pending entries accumulate naturally."
info "KEDA will detect pendingEntriesCount > threshold and scale up."

kubectl set env deployment/$DEPLOYMENT_NAME -n "$NAMESPACE" PROCESSING_DELAY_MS="$DELAY_MS" 2>/dev/null
ok "Set PROCESSING_DELAY_MS=$DELAY_MS on $DEPLOYMENT_NAME"

info "Waiting for rolling restart to complete..."
kubectl rollout status deployment/$DEPLOYMENT_NAME -n "$NAMESPACE" --timeout=120s 2>/dev/null || {
    err "Timeout waiting for rollout. Continuing anyway."
}
ok "Processing service restarted with ${DELAY_MS}ms delay"

# Give the new pods a moment to connect to Redis and start consuming
sleep 5

# =====================================================================
# PHASE 2: Flood
# =====================================================================
header "Phase 2: Flooding Stream with $TOTAL_MESSAGES Messages"
info "With ${DELAY_MS}ms delay per message, pending entries will accumulate."
info "Endpoint: $READINGS_ENDPOINT"
echo ""

SENT=0
ERRORS=0
START_TIME=$(date +%s)

for i in $(seq 1 "$TOTAL_MESSAGES"); do
    SITE_NUM=$(( (i % 5) + 1 ))
    POWER=$(awk "BEGIN{printf \"%.1f\", 100 + rand() * 4900}")
    TS=$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")

    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
        -X POST "$READINGS_ENDPOINT" \
        -H "Content-Type: application/json" \
        -d "{\"site_id\":\"load-test-site-$SITE_NUM\",\"device_id\":\"meter-$i\",\"power_reading\":$POWER,\"timestamp\":\"$TS\"}")

    if [ "$HTTP_CODE" = "201" ]; then
        SENT=$((SENT + 1))
    else
        ERRORS=$((ERRORS + 1))
    fi

    # Progress every 10 messages
    if [ $((i % 10)) -eq 0 ]; then
        PCT=$((i * 100 / TOTAL_MESSAGES))
        printf "\r  Sent: %d / %d (%d%%) | Errors: %d" "$SENT" "$TOTAL_MESSAGES" "$PCT" "$ERRORS"
    fi
done

END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))
echo ""
ok "Flood complete: $SENT sent, $ERRORS errors in ${ELAPSED}s"

if [ "$SENT" -eq 0 ]; then
    err "No messages were sent successfully. Cannot test scaling."
    exit 1
fi

# Show pending entries
kubectl exec -n "$NAMESPACE" sts/energy-pipeline-redis-master \
    -- redis-cli XPENDING energy_readings processing_group 2>/dev/null || true

# =====================================================================
# PHASE 3: Monitor scaling
# =====================================================================
header "Phase 3: Monitoring KEDA Scaling (~3 minutes)"
info "KEDA polls every 15-30s. Watch for replica count changes..."
info "Press Ctrl+C to stop early."
echo ""

MAX_WAIT=180
ELAPSED=0
PREV_REPLICAS=-1
SCALED_UP=false
MAX_OBSERVED=0
SCALE_UP_TIME=""

while [ "$ELAPSED" -lt "$MAX_WAIT" ]; do
    REPLICAS=$(kubectl get deployment "$DEPLOYMENT_NAME" -n "$NAMESPACE" \
        -o jsonpath="{.status.replicas}" 2>/dev/null || echo "?")
    [ -z "$REPLICAS" ] && REPLICAS="0"

    READY=$(kubectl get deployment "$DEPLOYMENT_NAME" -n "$NAMESPACE" \
        -o jsonpath="{.status.readyReplicas}" 2>/dev/null || echo "0")
    [ -z "$READY" ] && READY="0"

    HPA_DESIRED=$(kubectl get hpa -n "$NAMESPACE" \
        -o jsonpath="{.items[0].status.desiredReplicas}" 2>/dev/null || echo "n/a")
    [ -z "$HPA_DESIRED" ] && HPA_DESIRED="n/a"

    # Check pending entries
    PENDING=$(kubectl exec -n "$NAMESPACE" sts/energy-pipeline-redis-master \
        -- redis-cli XPENDING energy_readings processing_group 2>/dev/null | head -1 || echo "?")
    [ -z "$PENDING" ] && PENDING="?"

    NOW=$(date +"%H:%M:%S")

    # Track max replicas
    if [ "$REPLICAS" != "?" ] && [ "$REPLICAS" -gt "$MAX_OBSERVED" ] 2>/dev/null; then
        MAX_OBSERVED="$REPLICAS"
    fi

    if [ "$REPLICAS" != "?" ] && [ "$REPLICAS" != "$PREV_REPLICAS" ] && [ "$PREV_REPLICAS" != "-1" ]; then
        echo ""
        if [ "$REPLICAS" -gt "$PREV_REPLICAS" ] 2>/dev/null; then
            echo -e "  ${GREEN}** SCALED UP: $PREV_REPLICAS -> $REPLICAS replicas **${NC}"
            SCALED_UP=true
            [ -z "$SCALE_UP_TIME" ] && SCALE_UP_TIME="$ELAPSED"
        elif [ "$REPLICAS" -lt "$PREV_REPLICAS" ] 2>/dev/null; then
            echo -e "  ${MAGENTA}** SCALED DOWN: $PREV_REPLICAS -> $REPLICAS replicas **${NC}"
        fi
    fi
    PREV_REPLICAS="$REPLICAS"

    printf "\r  [%s] Replicas: %s/%s | Pending: %s | HPA desired: %s | %ds  " \
        "$NOW" "$READY" "$REPLICAS" "$PENDING" "$HPA_DESIRED" "$ELAPSED"

    # Early exit after confirming scale-up
    if [ "$MAX_OBSERVED" -gt 1 ] && [ -n "$SCALE_UP_TIME" ] && [ "$ELAPSED" -gt $((SCALE_UP_TIME + 30)) ]; then
        echo ""
        info "Scale-up confirmed. Stopping early."
        break
    fi

    sleep 5
    ELAPSED=$((ELAPSED + 5))
done

echo ""

# --- Results ---
header "Final State"
info "Processing Service pods:"
kubectl get pods -n "$NAMESPACE" -l "app.kubernetes.io/component=processing-service"
echo ""
info "ScaledObject:"
kubectl get scaledobject -n "$NAMESPACE"
echo ""
info "HPA (created by KEDA):"
kubectl get hpa -n "$NAMESPACE" 2>/dev/null || echo "  No HPA found"

if [ "$SCALED_UP" = true ] && [ "$MAX_OBSERVED" -gt 1 ]; then
    echo ""
    echo -e "${GREEN}============================================================${NC}"
    ok "SUCCESS: KEDA autoscaling verified!"
    echo -e "${GREEN}  Max replicas observed: $MAX_OBSERVED (max configured: 3)${NC}"
    [ -n "$SCALE_UP_TIME" ] && echo -e "${GREEN}  Scale-up triggered at: ${SCALE_UP_TIME}s into monitoring${NC}"
    echo -e "${GREEN}  Trigger: pendingEntriesCount in consumer group${NC}"
    echo -e "${GREEN}============================================================${NC}"
elif [ "$SCALED_UP" = true ]; then
    echo ""
    info "KEDA scaled from 0 to 1 (minimum), but did not scale beyond 1."
    info "Pending entries were consumed before exceeding the threshold."
    info "Try increasing TOTAL_MESSAGES (e.g. 200) or DELAY_MS (e.g. 1000)."
else
    echo ""
    info "Pods did not scale during the monitoring window."
    info "Debug:"
    echo "  kubectl describe scaledobject -n $NAMESPACE"
    echo "  kubectl logs -n keda -l app=keda-operator --tail=50"
fi

echo ""
info "To clean up test data:"
echo "  kubectl exec -n $NAMESPACE sts/energy-pipeline-redis-master -- redis-cli DEL site:load-test-site-1:readings site:load-test-site-2:readings site:load-test-site-3:readings site:load-test-site-4:readings site:load-test-site-5:readings"
