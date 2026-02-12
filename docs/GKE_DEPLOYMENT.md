# GKE Deployment Guide

This guide covers deploying the Energy Readings Pipeline to Google Kubernetes Engine with Artifact Registry and optional Cloudflare Tunnel access.

## Prerequisites

- [Google Cloud SDK](https://cloud.google.com/sdk/docs/install) (`gcloud`)
- Docker
- Helm 3.x
- A GCP project with billing enabled

## 1. Create a GKE Cluster

```bash
gcloud container clusters create energy-pipeline-cluster \
  --region us-central1 \
  --num-nodes 1 \
  --machine-type e2-medium

gcloud container clusters get-credentials energy-pipeline-cluster \
  --region us-central1
```

> **Note:** Use `--region` for regional clusters (higher availability) or `--zone us-central1-a` for a single-zone cluster. Adjust `--num-nodes` and `--machine-type` to your needs.

## 2. Push Images to Artifact Registry

```bash
# Set your project ID
export PROJECT_ID=$(gcloud config get-value project)

# Create repo (once)
gcloud artifacts repositories create energy-repo \
  --repository-format=docker \
  --location=us-central1

# Configure Docker auth
gcloud auth configure-docker us-central1-docker.pkg.dev

# Build and push (use --platform linux/amd64 if building on ARM/Apple Silicon)
export REGISTRY=us-central1-docker.pkg.dev/$PROJECT_ID/energy-repo

docker build --platform linux/amd64 -t $REGISTRY/ingestion-api:latest ./ingestion-api
docker build --platform linux/amd64 -t $REGISTRY/processing-service:latest ./processing-service
docker build --platform linux/amd64 -t $REGISTRY/frontend:latest ./frontend

docker push $REGISTRY/ingestion-api:latest
docker push $REGISTRY/processing-service:latest
docker push $REGISTRY/frontend:latest
```

## 3. Deploy with Helm

```bash
helm repo add bitnami https://charts.bitnami.com/bitnami
helm dependency update charts/energy-pipeline

helm upgrade --install energy-pipeline ./charts/energy-pipeline \
  --namespace default \
  --set ingestionApi.image.repository=$REGISTRY/ingestion-api \
  --set ingestionApi.image.pullPolicy=Always \
  --set processingService.image.repository=$REGISTRY/processing-service \
  --set processingService.image.pullPolicy=Always \
  --set frontend.image.repository=$REGISTRY/frontend \
  --set frontend.image.pullPolicy=Always \
  --set redis.image.tag=latest
```

> **Important:** The Bitnami Redis subchart pins a specific image tag that may become unavailable on Docker Hub over time. Override with `--set redis.image.tag=latest` to pull the current stable release.

### Verify

```bash
# Wait for all pods to be ready
kubectl get pods -w

# Quick end-to-end test
kubectl port-forward svc/energy-pipeline-frontend 3000:80 &

curl -X POST http://localhost:3000/api/readings \
  -H "Content-Type: application/json" \
  -d '{"site_id":"site-001","device_id":"meter-42","power_reading":1500.5,"timestamp":"2024-01-15T10:30:00Z"}'

sleep 3
curl http://localhost:3000/api/sites/site-001/readings
```

## 4. Install KEDA (optional, for autoscaling)

```bash
helm repo add kedacore https://kedacore.github.io/charts
helm install keda kedacore/keda --namespace keda --create-namespace
```

If KEDA is not installed, set `keda.enabled=false` in values to skip the ScaledObject.

## 5. Expose via Cloudflare Tunnel (optional)

```bash
# Create the tunnel token secret
kubectl create secret generic cloudflare-tunnel-token \
  --from-literal=token=<YOUR_TUNNEL_TOKEN>

# Re-deploy with Cloudflare enabled (include all previous --set flags)
helm upgrade energy-pipeline ./charts/energy-pipeline \
  --namespace default \
  --set cloudflare.enabled=true \
  --set ingestionApi.image.repository=$REGISTRY/ingestion-api \
  --set ingestionApi.image.pullPolicy=Always \
  --set processingService.image.repository=$REGISTRY/processing-service \
  --set processingService.image.pullPolicy=Always \
  --set frontend.image.repository=$REGISTRY/frontend \
  --set frontend.image.pullPolicy=Always \
  --set redis.image.tag=latest
```

Then configure the public hostname in the Cloudflare Zero Trust dashboard to point to `http://energy-pipeline-frontend:80`.

## 6. GitHub Actions CI/CD

Add these secrets to your GitHub repository:

| Secret | Description |
|--------|-------------|
| `GKE_PROJECT` | Your GCP project ID |
| `GKE_CLUSTER` | GKE cluster name |
| `GKE_ZONE` | GKE cluster zone or region |

Then uncomment the placeholder sections in `.github/workflows/cd.yml` to enable automated deployments.

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| Redis `ImagePullBackOff` | Bitnami removed the pinned image tag from Docker Hub | `--set redis.image.tag=latest` |
| Service `ImagePullBackOff` | Image not pushed to AR, or using local image name | Ensure `image.repository` points to full AR path |
| Service `CrashLoopBackOff` | Redis not ready yet; services fail health checks | Wait for Redis pod to be `Running 1/1`, services auto-recover |

## Cleanup

```bash
helm uninstall energy-pipeline
gcloud container clusters delete energy-pipeline-cluster --region us-central1 --quiet
```
