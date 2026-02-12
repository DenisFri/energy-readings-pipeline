# Energy Readings Pipeline

A cloud-native pipeline for ingesting and processing energy readings using FastAPI, Redis Streams, and Kubernetes.

**Live demo:** [https://energy.frishchin.com](https://energy.frishchin.com)

**Data flow:** Ingestion API receives readings via HTTP, publishes to a Redis Stream (`XADD`). Processing Service consumes from the stream via a consumer group (`XREADGROUP`), stores each reading in a Redis sorted set keyed by `site_id` (`ZADD`), and acknowledges the message (`XACK`). Readings are retrievable per site via `GET /sites/{site_id}/readings`.

## Quick Start

```bash
docker compose up --build
```

This starts Redis, Ingestion API (port 8000), Processing Service (port 8001), and Frontend (port 3000).

Open **http://localhost:3000** to use the web UI, or test via CLI:

```bash
# Send a reading
curl -X POST http://localhost:3000/api/readings \
  -H "Content-Type: application/json" \
  -d '{
    "site_id": "site-001",
    "device_id": "meter-42",
    "power_reading": 1500.5,
    "timestamp": "2024-01-15T10:30:00Z"
  }'

# Wait a moment for the consumer to process, then fetch readings
curl http://localhost:3000/api/sites/site-001/readings
```

**Stop:**

```bash
docker compose down
```

## Kubernetes Deployment (Minikube)

### Prerequisites

- Docker
- kubectl
- Helm 3.x
- minikube

### Steps

```bash
# 1. Start minikube
minikube start --memory=4096 --cpus=2

# 2. Use minikube's Docker daemon
eval $(minikube docker-env)

# 3. Build images
docker build -t energy-pipeline/ingestion-api:latest ./ingestion-api
docker build -t energy-pipeline/processing-service:latest ./processing-service
docker build -t energy-pipeline/frontend:latest ./frontend

# 4. Install Helm dependencies
helm repo add bitnami https://charts.bitnami.com/bitnami
helm dependency update charts/energy-pipeline

# 5. Deploy
helm install energy-pipeline ./charts/energy-pipeline \
  --namespace energy-pipeline \
  --create-namespace

# 6. Port-forward to access the frontend
kubectl port-forward svc/energy-pipeline-frontend 3000:80 -n energy-pipeline

# 7. Open http://localhost:3000
```

### Cleanup

```bash
helm uninstall energy-pipeline -n energy-pipeline
kubectl delete namespace energy-pipeline
minikube stop
```

> **Cloud deployment:** See [docs/GKE_DEPLOYMENT.md](docs/GKE_DEPLOYMENT.md) for GKE with Artifact Registry and Cloudflare Tunnel setup.

## API Reference

### Ingestion API (port 8000)

#### `POST /readings`

Ingest an energy reading into the Redis stream.

**Request:**
```json
{
  "site_id": "site-001",
  "device_id": "meter-42",
  "power_reading": 1500.5,
  "timestamp": "2024-01-15T10:30:00Z"
}
```

**Response (201):**
```json
{
  "status": "accepted",
  "stream_id": "1705312200000-0"
}
```

**Validation errors (422):** Returned for empty/missing fields or invalid timestamp format.

#### `GET /health`

Returns service health and Redis connectivity status.

### Processing Service (port 8001)

#### `GET /sites/{site_id}/readings`

Returns all stored readings for a given site, ordered by timestamp.

**Response (200):**
```json
{
  "site_id": "site-001",
  "readings": [
    {
      "stream_id": "1705312200000-0",
      "site_id": "site-001",
      "device_id": "meter-42",
      "power_reading": 1500.5,
      "timestamp": "2024-01-15T10:30:00Z",
      "ingested_at": "2024-01-15T10:30:00.123456"
    }
  ]
}
```

#### `GET /health`

Returns service health, Redis connectivity, and consumer group status.

#### `GET /metrics`

Returns stream length, consumer group info, and pending message counts.

## Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `REDIS_HOST` | `localhost` | Redis server hostname |
| `REDIS_PORT` | `6379` | Redis server port |
| `REDIS_STREAM` | `energy_readings` | Redis stream name |
| `CONSUMER_GROUP` | `processing_group` | Consumer group name |
| `CONSUMER_NAME` | `$HOSTNAME` | Consumer instance name (auto-set from pod name in K8s) |

### Key Helm Values

| Value | Default | Description |
|-------|---------|-------------|
| `ingestionApi.replicaCount` | `1` | Ingestion API replicas |
| `processingService.replicaCount` | `1` | Processing Service replicas |
| `frontend.enabled` | `true` | Deploy frontend UI |
| `ingress.enabled` | `false` | Deploy Kubernetes Ingress |
| `cloudflare.enabled` | `false` | Deploy Cloudflare Tunnel connector |
| `keda.enabled` | `true` | Enable KEDA autoscaler |
| `keda.minReplicaCount` | `1` | Min processing replicas |
| `keda.maxReplicaCount` | `3` | Max processing replicas |
| `keda.threshold` | `5` | Pending messages to trigger scale-up |
| `redis.enabled` | `true` | Deploy Redis via Bitnami subchart |

See `charts/energy-pipeline/values.yaml` for all configurable parameters.

## Design Decisions

| Decision | Rationale |
|----------|-----------|
| Redis Sorted Sets for storage | Natural time-ordering via timestamp scores; efficient range queries |
| `asyncio.to_thread()` for XREADGROUP | Prevents synchronous Redis blocking the async event loop |
| Consumer groups | Enable distributed processing and message acknowledgment |
| Nginx reverse proxy in frontend | Eliminates CORS; single entry point for the UI |
| Cloudflare Tunnel over LoadBalancer | Zero-trust access without exposing public IPs |
