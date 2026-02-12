#!/usr/bin/env bash
#
# KEDA Autoscaling Test
# Floods the ingestion API with readings and monitors processing pod scaling.
#
# Usage:
#   ./scripts/test-keda-autoscaling.sh [NAMESPACE] [TOTAL_MESSAGES] [INGRESS_URL]
#
# Examples:
#   ./scripts/test-keda-autoscaling.sh energy-pipeline 100
#   ./scripts/test-keda-autoscaling.sh energy-pipeline 200 https://energy.frishchin.com

set -euo pipefail

NAMESPACE="${1:-energy-pipeline}"
TOTAL_MESSAGES="${2:-100}"
INGRESS_URL="${3:-}"

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
header "KEDA Autoscaling Test"
echo "Namespace:       $NAMESPACE"
echo "Total messages:  $TOTAL_MESSAGES"
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

# --- Port Forward ---
PORT_FORWARD_PID=""
if [ -z "$INGRESS_URL" ]; then
    header "Setting Up Port Forward"
    INGEST_POD=$(kubectl get pods -n "$NAMESPACE" -l "app.kubernetes.io/component=ingestion-api" -o jsonpath="{.items[0].metadata.name}")
    kubectl port-forward -n "$NAMESPACE" "$INGEST_POD" 8080:8000 &>/dev/null &
    PORT_FORWARD_PID=$!
    sleep 3
    BASE_URL="http://localhost:8080"
    ok "Port forward active: $BASE_URL -> $INGEST_POD"
else
    BASE_URL="${INGRESS_URL%/}"
    ok "Using external URL: $BASE_URL"
fi

cleanup() {
    if [ -n "$PORT_FORWARD_PID" ]; then
        kill "$PORT_FORWARD_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# --- Verify API ---
header "Verifying API"
if curl -sf "$BASE_URL/health" > /dev/null; then
    ok "Ingestion API is reachable"
else
    err "Cannot reach ingestion API at $BASE_URL/health"
    exit 1
fi

# --- Flood ---
header "Flooding Stream with $TOTAL_MESSAGES Messages"
info "Sending readings as fast as possible to build backlog..."
echo ""

SENT=0
ERRORS=0
START_TIME=$(date +%s)

for i in $(seq 1 "$TOTAL_MESSAGES"); do
    SITE_NUM=$(( (i % 5) + 1 ))
    POWER=$(awk "BEGIN{printf \"%.1f\", 100 + rand() * 4900}")
    TS=$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")

    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
        -X POST "$BASE_URL/readings" \
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

# --- Monitor ---
header "Monitoring KEDA Scaling (~2 minutes)"
info "KEDA polls every 15-30s. Watch for replica count changes..."
info "Press Ctrl+C to stop early."
echo ""

MAX_WAIT=120
ELAPSED=0
PREV_REPLICAS=-1
SCALED_UP=false

while [ "$ELAPSED" -lt "$MAX_WAIT" ]; do
    REPLICAS=$(kubectl get deployment -n "$NAMESPACE" \
        -l "app.kubernetes.io/component=processing-service" \
        -o jsonpath="{.items[0].status.replicas}" 2>/dev/null || echo "?")

    READY=$(kubectl get deployment -n "$NAMESPACE" \
        -l "app.kubernetes.io/component=processing-service" \
        -o jsonpath="{.items[0].status.readyReplicas}" 2>/dev/null || echo "0")
    [ -z "$READY" ] && READY="0"

    HPA_DESIRED=$(kubectl get hpa -n "$NAMESPACE" \
        -o jsonpath="{.items[0].status.desiredReplicas}" 2>/dev/null || echo "?")

    NOW=$(date +"%H:%M:%S")

    if [ "$REPLICAS" != "$PREV_REPLICAS" ] && [ "$PREV_REPLICAS" != "-1" ]; then
        echo ""
        if [ "$REPLICAS" -gt "$PREV_REPLICAS" ] 2>/dev/null; then
            echo -e "  ${GREEN}>>> SCALED UP: $PREV_REPLICAS -> $REPLICAS replicas <<<${NC}"
            SCALED_UP=true
        else
            echo -e "  ${MAGENTA}>>> SCALED DOWN: $PREV_REPLICAS -> $REPLICAS replicas <<<${NC}"
        fi
    fi
    PREV_REPLICAS="$REPLICAS"

    printf "\r  [%s] Replicas: %s/%s ready | HPA desired: %s | Elapsed: %ds  " \
        "$NOW" "$READY" "$REPLICAS" "$HPA_DESIRED" "$ELAPSED"

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
kubectl get hpa -n "$NAMESPACE"

if [ "$SCALED_UP" = true ]; then
    echo ""
    ok "SUCCESS: KEDA autoscaling worked! Pods scaled up in response to stream backlog."
else
    echo ""
    info "Pods didn't scale during the monitoring window."
    info "Try: increasing messages (500+), or check: kubectl describe scaledobject -n $NAMESPACE"
fi

echo ""
info "To clean up test data:"
echo "  kubectl exec -n $NAMESPACE deploy/energy-pipeline-redis-master -- redis-cli DEL site:load-test-site-1:readings site:load-test-site-2:readings site:load-test-site-3:readings site:load-test-site-4:readings site:load-test-site-5:readings"
