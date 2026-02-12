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

# Build and push (use --platform linux/amd64 if building on ARM/Apple Silicon)
export PROJECT_ID=$(gcloud config get-value project)
export REGISTRY=us-central1-docker.pkg.dev/$PROJECT_ID/energy-repo

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

# Ensure REGISTRY is set (re-export if new terminal session)
export PROJECT_ID=$(gcloud config get-value project)
export REGISTRY=us-central1-docker.pkg.dev/$PROJECT_ID/energy-repo

helm upgrade --install energy-pipeline ./charts/energy-pipeline \
  --namespace energy-pipeline \
  --create-namespace \
  --set ingestionApi.image.repository=$REGISTRY/ingestion-api \
  --set ingestionApi.image.pullPolicy=Always \
  --set processingService.image.repository=$REGISTRY/processing-service \
  --set processingService.image.pullPolicy=Always \
  --set frontend.image.repository=$REGISTRY/frontend \
  --set frontend.image.pullPolicy=Always \
  --set redis.image.tag=latest
```

## 4. Install KEDA (optional, for autoscaling)

```bash
helm repo add kedacore https://kedacore.github.io/charts
helm install keda kedacore/keda --namespace keda --create-namespace
```

If KEDA is not installed, set `keda.enabled=false` in values to skip the ScaledObject.

## 5. Expose via Cloudflare Tunnel (optional)

```bash
# Ensure REGISTRY is set (if new terminal session)
export PROJECT_ID=$(gcloud config get-value project)
export REGISTRY=us-central1-docker.pkg.dev/$PROJECT_ID/energy-repo

# Create the tunnel token secret in the energy-pipeline namespace
kubectl create secret generic cloudflare-tunnel-token \
  --namespace energy-pipeline \
  --from-literal=token=<YOUR_TUNNEL_TOKEN>

# Re-deploy with Cloudflare enabled (must include all image overrides)
helm upgrade energy-pipeline ./charts/energy-pipeline \
  --namespace energy-pipeline \
  --set cloudflare.enabled=true \
  --set ingestionApi.image.repository=$REGISTRY/ingestion-api \
  --set ingestionApi.image.pullPolicy=Always \
  --set processingService.image.repository=$REGISTRY/processing-service \
  --set processingService.image.pullPolicy=Always \
  --set frontend.image.repository=$REGISTRY/frontend \
  --set frontend.image.pullPolicy=Always \
  --set redis.image.tag=latest
```

> **Important:** Every `helm upgrade` must include all `--set` flags. Helm resets omitted values to defaults, which would revert image repositories to local names and cause `InvalidImageName` errors.

Then configure the public hostname in the Cloudflare Zero Trust dashboard to point to `http://energy-pipeline-frontend.energy-pipeline:80`.

> **Note:** Since the tunnel now runs in the `energy-pipeline` namespace, the service URL must include the namespace suffix (`.energy-pipeline`). If the tunnel runs in the same namespace as the services, you can use just `http://energy-pipeline-frontend:80`.

## 6. GitHub Actions CI/CD

Add these secrets to your GitHub repository:

| Secret | Description |
|--------|-------------|
| `GKE_PROJECT` | Your GCP project ID |
| `GKE_CLUSTER` | GKE cluster name |
| `GKE_ZONE` | GKE cluster zone |

Then uncomment the placeholder sections in `.github/workflows/cd.yml` to enable automated deployments.

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `InvalidImageName` / `couldn't parse image name "/ingestion-api:latest"` | `$REGISTRY` variable was empty during `helm upgrade` | Re-export `REGISTRY` and run `helm upgrade` again with all `--set` flags |
| Redis `ImagePullBackOff` | Bitnami removed the pinned image tag from Docker Hub | Add `--set redis.image.tag=latest` |
| Services `CrashLoopBackOff` | Redis not ready yet; services fail health checks | Wait for Redis pod to be `Running 1/1`, services auto-recover |
| Cloudflared `CrashLoopBackOff` | Health probes fail because metrics server is not enabled | Fixed in chart — `--metrics 0.0.0.0:2000` is now passed as an arg |

## Migrating from `default` to `energy-pipeline` Namespace

If you previously deployed in the `default` namespace:

```bash
# 1. Uninstall the old release from default namespace
helm uninstall energy-pipeline --namespace default

# 2. Delete the orphaned cloudflare secret from default namespace (if it exists)
kubectl delete secret cloudflare-tunnel-token --namespace default --ignore-not-found

# 3. Re-create the cloudflare secret in the new namespace
kubectl create secret generic cloudflare-tunnel-token \
  --namespace energy-pipeline \
  --from-literal=token=<YOUR_TUNNEL_TOKEN>

# 4. Deploy fresh in the energy-pipeline namespace
export PROJECT_ID=$(gcloud config get-value project)
export REGISTRY=us-central1-docker.pkg.dev/$PROJECT_ID/energy-repo

helm upgrade --install energy-pipeline ./charts/energy-pipeline \
  --namespace energy-pipeline \
  --create-namespace \
  --set cloudflare.enabled=true \
  --set ingestionApi.image.repository=$REGISTRY/ingestion-api \
  --set ingestionApi.image.pullPolicy=Always \
  --set processingService.image.repository=$REGISTRY/processing-service \
  --set processingService.image.pullPolicy=Always \
  --set frontend.image.repository=$REGISTRY/frontend \
  --set frontend.image.pullPolicy=Always \
  --set redis.image.tag=latest
```

## Cleanup

```bash
helm uninstall energy-pipeline --namespace energy-pipeline
kubectl delete namespace energy-pipeline
gcloud container clusters delete energy-pipeline-cluster --zone us-central1-a --quiet
```
