# Energy Readings Pipeline

A cloud-native pipeline for ingesting and processing energy readings using FastAPI, Redis Streams, and Kubernetes.

**Assignment ID:** `8d4e7f2a-5b3c-4a91-9e6d-1c8f0a2b3d4e`


**Data flow:** Ingestion API receives readings via HTTP, publishes to a Redis Stream (`XADD`). Processing Service consumes from the stream via a consumer group (`XREADGROUP`), stores each reading in a Redis sorted set keyed by `site_id` (`ZADD`), and acknowledges the message (`XACK`). Readings are retrievable per site via `GET /sites/{site_id}/readings`.


## Quick Start (Docker Compose)

Run the full pipeline locally:

```bash
docker compose up --build
```

This starts Redis, Ingestion API (port 8000), and Processing Service (port 8001).

**Test the pipeline:**

```bash
# Send a reading
curl -X POST http://localhost:8000/readings \
  -H "Content-Type: application/json" \
  -d '{
    "site_id": "site-001",
    "device_id": "meter-42",
    "power_reading": 1500.5,
    "timestamp": "2024-01-15T10:30:00Z"
  }'

# Wait a moment for the consumer to process, then fetch readings
curl http://localhost:8001/sites/site-001/readings
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

# 4. Install Helm dependencies
helm repo add bitnami https://charts.bitnami.com/bitnami
helm dependency update charts/energy-pipeline

# 5. Deploy
helm install energy-pipeline ./charts/energy-pipeline \
  --namespace energy-pipeline \
  --create-namespace

# 6. Port-forward to access services
kubectl port-forward svc/energy-pipeline-ingestion-api 8000:80 -n energy-pipeline &
kubectl port-forward svc/energy-pipeline-processing-service 8001:80 -n energy-pipeline &

# 7. Test (same curl commands as above)
curl -X POST http://localhost:8000/readings \
  -H "Content-Type: application/json" \
  -d '{"site_id":"site-001","device_id":"meter-42","power_reading":1500.5,"timestamp":"2024-01-15T10:30:00Z"}'

curl http://localhost:8001/sites/site-001/readings
```

### Cleanup

```bash
helm uninstall energy-pipeline -n energy-pipeline
kubectl delete namespace energy-pipeline
minikube stop
```

## GKE Deployment

### 1. Create a GKE Cluster

```bash
gcloud container clusters create energy-pipeline-cluster \
  --zone us-central1-a \
  --num-nodes 3 \
  --machine-type e2-medium

gcloud container clusters get-credentials energy-pipeline-cluster \
  --zone us-central1-a
```

### 2. Push Images to Artifact Registry

```bash
# Create repo (once)
gcloud artifacts repositories create energy-repo \
  --repository-format=docker \
  --location=us-central1

# Configure Docker auth
gcloud auth configure-docker us-central1-docker.pkg.dev

# Build and push
REGISTRY=us-central1-docker.pkg.dev/$PROJECT_ID/energy-repo

docker build -t $REGISTRY/ingestion-api:latest ./ingestion-api
docker build -t $REGISTRY/processing-service:latest ./processing-service
docker push $REGISTRY/ingestion-api:latest
docker push $REGISTRY/processing-service:latest
```

### 3. Deploy with Helm

```bash
helm repo add bitnami https://charts.bitnami.com/bitnami
helm dependency update charts/energy-pipeline

helm upgrade --install energy-pipeline ./charts/energy-pipeline \
  --namespace energy-pipeline \
  --create-namespace \
  --set ingestionApi.image.repository=$REGISTRY/ingestion-api \
  --set processingService.image.repository=$REGISTRY/processing-service
```

### 4. Install KEDA (optional, for autoscaling)

```bash
helm repo add kedacore https://kedacore.github.io/charts
helm install keda kedacore/keda --namespace keda --create-namespace
```

If KEDA is not installed, set `keda.enabled=false` in values to skip the ScaledObject.

### 5. GitHub Actions CI/CD

Add these secrets to your GitHub repository:

| Secret | Description |
|--------|-------------|
| `GKE_PROJECT` | Your GCP project ID |
| `GKE_CLUSTER` | GKE cluster name |
| `GKE_ZONE` | GKE cluster zone |

Then uncomment the placeholder sections in `.github/workflows/cd.yml` to enable automated builds and deployments.

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
| `keda.enabled` | `true` | Enable KEDA autoscaler |
| `keda.minReplicaCount` | `1` | Min processing replicas |
| `keda.maxReplicaCount` | `3` | Max processing replicas |
| `keda.threshold` | `5` | Pending messages to trigger scale-up |
| `redis.enabled` | `true` | Deploy Redis via Bitnami subchart |

See `charts/energy-pipeline/values.yaml` for all configurable parameters.
