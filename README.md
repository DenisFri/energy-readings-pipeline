# Energy Readings Pipeline

A cloud-native pipeline for ingesting and processing energy readings using FastAPI, Redis Streams, and Kubernetes.

**Assignment ID:** `8d4e7f2a-5b3c-4a91-9e6d-1c8f0a2b3d4e`

## Architecture

```
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────────┐
│  Ingestion API  │────▶│  Redis Stream   │────▶│  Processing Service │
│   (FastAPI)     │     │ energy_readings │     │    (Consumer Group) │
└─────────────────┘     └─────────────────┘     └─────────────────────┘
     POST /readings          XADD                   XREADGROUP
```

## Project Structure

```
.
├── ingestion-api/           # FastAPI service for receiving readings
│   ├── main.py
│   ├── Dockerfile
│   └── requirements.txt
├── processing-service/      # Background worker for processing readings
│   ├── main.py
│   ├── Dockerfile
│   └── requirements.txt
├── frontend/                # Frontend application (placeholder)
├── charts/
│   └── energy-pipeline/     # Helm chart for Kubernetes deployment
└── .github/
    └── workflows/
        └── cd.yml           # CI/CD pipeline for GKE
```

## Prerequisites

- Docker
- kubectl
- Helm 3.x
- minikube (for local development) or GKE cluster

## Local Development with Minikube

### 1. Start Minikube

```bash
minikube start --memory=4096 --cpus=2
```

### 2. Enable Docker Environment

```bash
eval $(minikube docker-env)
```

### 3. Build Docker Images

```bash
# Build ingestion API
docker build -t energy-pipeline/ingestion-api:latest ./ingestion-api

# Build processing service
docker build -t energy-pipeline/processing-service:latest ./processing-service
```

### 4. Install Helm Dependencies

```bash
cd charts/energy-pipeline
helm repo add bitnami https://charts.bitnami.com/bitnami
helm dependency update
cd ../..
```

### 5. Deploy with Helm

```bash
helm install energy-pipeline ./charts/energy-pipeline \
  --namespace energy-pipeline \
  --create-namespace
```

### 6. Access the Services

```bash
# Port forward ingestion API
kubectl port-forward svc/energy-pipeline-ingestion-api 8000:80 -n energy-pipeline

# Port forward processing service (metrics)
kubectl port-forward svc/energy-pipeline-processing-service 8001:80 -n energy-pipeline
```

### 7. Test the Pipeline

```bash
# Send a test reading
curl -X POST http://localhost:8000/readings \
  -H "Content-Type: application/json" \
  -d '{
    "site_id": "site-001",
    "device_id": "device-001",
    "power_reading": 1500.5,
    "timestamp": "2024-01-15T10:30:00Z"
  }'

# Check processing metrics
curl http://localhost:8001/metrics
```

## GKE Deployment

### 1. Prerequisites

- GCP project with GKE enabled
- `gcloud` CLI configured
- Workload Identity configured for GitHub Actions OIDC

### 2. Configure GKE Cluster

```bash
# Create cluster (if not exists)
gcloud container clusters create energy-pipeline-cluster \
  --zone us-central1-a \
  --num-nodes 3 \
  --machine-type e2-medium

# Get credentials
gcloud container clusters get-credentials energy-pipeline-cluster \
  --zone us-central1-a
```

### 3. Configure GitHub Secrets

Add the following secrets to your GitHub repository:

| Secret | Description |
|--------|-------------|
| `GKE_PROJECT` | Your GCP project ID |
| `GKE_CLUSTER` | Your GKE cluster name |
| `GKE_ZONE` | Your GKE cluster zone |

### 4. Configure Workload Identity Federation

```bash
# Create workload identity pool
gcloud iam workload-identity-pools create github-pool \
  --location="global" \
  --display-name="GitHub Actions Pool"

# Create provider
gcloud iam workload-identity-pools providers create-oidc github-provider \
  --location="global" \
  --workload-identity-pool="github-pool" \
  --display-name="GitHub Provider" \
  --attribute-mapping="google.subject=assertion.sub,attribute.actor=assertion.actor,attribute.repository=assertion.repository" \
  --issuer-uri="https://token.actions.githubusercontent.com"

# Create service account
gcloud iam service-accounts create github-actions \
  --display-name="GitHub Actions"

# Grant permissions
gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:github-actions@$PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/container.developer"

gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:github-actions@$PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/storage.admin"
```

### 5. Enable CI/CD

Uncomment the placeholder sections in `.github/workflows/cd.yml` to enable:
- GCP OIDC authentication
- Docker push to GCR
- Helm deployment to GKE

### 6. Manual Deployment

```bash
# Build and push images
docker build -t gcr.io/$PROJECT_ID/ingestion-api:latest ./ingestion-api
docker build -t gcr.io/$PROJECT_ID/processing-service:latest ./processing-service
docker push gcr.io/$PROJECT_ID/ingestion-api:latest
docker push gcr.io/$PROJECT_ID/processing-service:latest

# Deploy with Helm
helm upgrade --install energy-pipeline ./charts/energy-pipeline \
  --namespace energy-pipeline \
  --create-namespace \
  --set ingestionApi.image.repository=gcr.io/$PROJECT_ID/ingestion-api \
  --set processingService.image.repository=gcr.io/$PROJECT_ID/processing-service
```

## API Reference

### Ingestion API

#### POST /readings

Ingest an energy reading.

**Request Body:**
```json
{
  "site_id": "string",
  "device_id": "string",
  "power_reading": 0.0,
  "timestamp": "2024-01-15T10:30:00Z"
}
```

**Response:**
```json
{
  "status": "success",
  "stream_id": "1705312200000-0",
  "message": "Reading successfully ingested"
}
```

#### GET /health

Health check endpoint.

### Processing Service

#### GET /health

Health check endpoint with consumer status.

#### GET /metrics

Get stream and consumer group metrics.

## Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `REDIS_HOST` | `localhost` | Redis server hostname |
| `REDIS_PORT` | `6379` | Redis server port |
| `REDIS_STREAM` | `energy_readings` | Redis stream name |
| `CONSUMER_GROUP` | `processing_group` | Consumer group name |
| `CONSUMER_NAME` | `$HOSTNAME` | Consumer instance name |

### Helm Values

See `charts/energy-pipeline/values.yaml` for all configurable values.

## Cleanup

### Minikube

```bash
helm uninstall energy-pipeline -n energy-pipeline
kubectl delete namespace energy-pipeline
minikube stop
```

### GKE

```bash
helm uninstall energy-pipeline -n energy-pipeline
kubectl delete namespace energy-pipeline
gcloud container clusters delete energy-pipeline-cluster --zone us-central1-a
```
