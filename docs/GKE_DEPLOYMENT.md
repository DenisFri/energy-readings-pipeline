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
  --zone us-central1-a \
  --num-nodes 3 \
  --machine-type e2-medium

gcloud container clusters get-credentials energy-pipeline-cluster \
  --zone us-central1-a
```

## 2. Push Images to Artifact Registry

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
docker build -t $REGISTRY/frontend:latest ./frontend
docker push $REGISTRY/ingestion-api:latest
docker push $REGISTRY/processing-service:latest
docker push $REGISTRY/frontend:latest
```

## 3. Deploy with Helm

```bash
helm repo add bitnami https://charts.bitnami.com/bitnami
helm dependency update charts/energy-pipeline

helm upgrade --install energy-pipeline ./charts/energy-pipeline \
  --namespace energy-pipeline \
  --create-namespace \
  --set ingestionApi.image.repository=$REGISTRY/ingestion-api \
  --set processingService.image.repository=$REGISTRY/processing-service \
  --set frontend.image.repository=$REGISTRY/frontend
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
  --namespace energy-pipeline \
  --from-literal=token=<YOUR_TUNNEL_TOKEN>

# Deploy with Cloudflare enabled
helm upgrade energy-pipeline ./charts/energy-pipeline \
  --namespace energy-pipeline \
  --set cloudflare.enabled=true
```

Then configure the public hostname in the Cloudflare Zero Trust dashboard to point to `http://energy-pipeline-frontend:80`.

## 6. GitHub Actions CI/CD

Add these secrets to your GitHub repository:

| Secret | Description |
|--------|-------------|
| `GKE_PROJECT` | Your GCP project ID |
| `GKE_CLUSTER` | GKE cluster name |
| `GKE_ZONE` | GKE cluster zone |

Then uncomment the placeholder sections in `.github/workflows/cd.yml` to enable automated deployments.

## Cleanup

```bash
helm uninstall energy-pipeline -n energy-pipeline
kubectl delete namespace energy-pipeline
gcloud container clusters delete energy-pipeline-cluster --zone us-central1-a
```
