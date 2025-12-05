# Cloud Deploy Canary Deployment - Implementation Summary

## Overview
Implemented progressive canary deployments using Google Cloud Deploy with automated traffic shifting (1% → 10% → 100%).

## Changes Made

### 1. Cloud Deploy Configuration
**File**: `clouddeploy.yaml`
- Created delivery pipeline `todo-app-pipeline`
- Configured canary strategy with percentages: [1, 10]
- Defined production target pointing to GKE cluster

### 2. Skaffold Configuration
**File**: `skaffold.yaml`
- API version: `skaffold/v4beta11`
- Build: Uses Google Cloud Build
- Manifests: References all K8s YAML files using `rawYaml`

### 3. Kubernetes Manifests
**File**: `k8s/deployment.yaml`
- Changed image reference from hardcoded tag to artifact name: `image: todo-app-go`
- Removed duplicate `resources` block (critical fix)

### 4. CI/CD Pipeline
**File**: `.github/workflows/build-test.yml`
- Replaced direct `kubectl apply` with Cloud Deploy release creation
- Uses `gcloud deploy releases create` with `--images` parameter

### 5. Infrastructure
**File**: `terraform/main.tf`
- Enabled `clouddeploy.googleapis.com` API

## Critical Pitfalls & Solutions

### ⚠️ Pitfall 1: Skaffold API Version Incompatibility
**Problem**: Using `skaffold/v4beta6` with `deploy.kubectl.manifests` field causes render failures.

**Error**: `field manifests not found in type v4beta6.KubectlDeploy`

**Solution**: 
- Use `skaffold/v4beta11` or later
- Use `manifests.rawYaml` instead of `deploy.kubectl.manifests`

```yaml
# ❌ Wrong
apiVersion: skaffold/v4beta6
deploy:
  kubectl:
    manifests: [...]

# ✅ Correct
apiVersion: skaffold/v4beta11
manifests:
  rawYaml: [...]
```

### ⚠️ Pitfall 2: Hardcoded Image Tags
**Problem**: Hardcoded image tags in deployment manifests prevent Cloud Deploy from injecting the correct image.

**Error**: `RELEASE_FAILED: Release render operation ended in failure`

**Solution**: Use artifact name from `skaffold.yaml` instead of full image path.

```yaml
# ❌ Wrong
image: "us-central1-docker.pkg.dev/project/repo/app:tag"

# ✅ Correct
image: todo-app-go  # Must match artifact name in skaffold.yaml
```

### ⚠️ Pitfall 3: Duplicate YAML Keys
**Problem**: Duplicate keys in Kubernetes manifests cause YAML parsing errors during render.

**Error**: `yaml: unmarshal errors: line 43: mapping key "resources" already defined at line 21`

**Solution**: 
- Carefully review manifests for duplicate keys
- Use YAML linters before committing
- Common duplicates: `resources`, `ports`, `env`

### ⚠️ Pitfall 4: First Canary Deployment Behavior
**Behavior**: First Cloud Deploy rollout skips canary phases with message:
> "Skipped because there are no pre-existing deployed resources to canary-deploy against"

**This is expected!** Canary deployments require a baseline (stable) version to compare against. The first deployment goes directly to stable.

**Solution**: Accept this behavior. Subsequent deployments will use proper canary phases.

### ⚠️ Pitfall 5: Metrics Not Available for Alerts
**Problem**: Creating alert policies before metrics exist causes Terraform errors.

**Error**: `Cannot find metric(s) that match type = "prometheus.googleapis.com/..."`

**Solution**: 
1. Deploy application with metrics instrumentation first
2. Wait 5-10 minutes for metrics to appear in Cloud Monitoring
3. Then apply Terraform alert policies

**Workaround**: Comment out `terraform/alerts.tf` initially, apply after metrics are flowing.

## Deployment Workflow

### Normal Deployment (via GitHub Actions)
1. Push code to branch
2. GitHub Actions builds Docker image
3. GitHub Actions creates Cloud Deploy release
4. Cloud Deploy renders manifests with correct image
5. Rollout progresses: 1% → 10% → 100%

### Manual Deployment
```bash
# Create release
gcloud deploy releases create release-$(date +%s) \
  --delivery-pipeline=todo-app-pipeline \
  --region=us-central1 \
  --images=todo-app-go=us-central1-docker.pkg.dev/PROJECT/REPO/IMAGE:TAG

# Monitor rollout
gcloud deploy rollouts list \
  --delivery-pipeline=todo-app-pipeline \
  --region=us-central1

# Promote to next phase (if manual approval required)
gcloud deploy rollouts advance ROLLOUT_NAME \
  --delivery-pipeline=todo-app-pipeline \
  --region=us-central1 \
  --release=RELEASE_NAME
```

## Verification Checklist

- [ ] Skaffold version is `v4beta11` or later
- [ ] Image in `deployment.yaml` matches artifact name in `skaffold.yaml`
- [ ] No duplicate keys in Kubernetes manifests
- [ ] Cloud Deploy API enabled: `clouddeploy.googleapis.com`
- [ ] Delivery pipeline registered: `gcloud deploy delivery-pipelines list`
- [ ] First deployment completed (establishes baseline)
- [ ] Metrics flowing to Cloud Monitoring (for alerts)

## Rollback Procedure

If a bad release is detected during canary:

```bash
# Abandon current rollout
gcloud deploy rollouts cancel ROLLOUT_NAME \
  --delivery-pipeline=todo-app-pipeline \
  --region=us-central1 \
  --release=RELEASE_NAME

# Promote previous stable release
gcloud deploy releases promote PREVIOUS_RELEASE \
  --delivery-pipeline=todo-app-pipeline \
  --region=us-central1 \
  --to-target=production
```

## Additional Resources

- [Cloud Deploy Documentation](https://cloud.google.com/deploy/docs)
- [Skaffold Configuration](https://skaffold.dev/docs/references/yaml/)
- [Canary Deployment Strategy](https://cloud.google.com/deploy/docs/deployment-strategies/canary)
