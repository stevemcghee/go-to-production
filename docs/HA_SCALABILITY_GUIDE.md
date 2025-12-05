# Phase 3: High Availability and Scalability Implementation Guide

This guide documents the steps to upgrade the todo-app-go infrastructure from a zonal deployment to a regional, highly available, and scalable deployment.

## Overview

Phase 3 implements the following improvements:
- **Regional GKE Cluster**: Multi-zone Kubernetes cluster for high availability
- **Regional Cloud SQL**: High availability database with automatic failover
- **Horizontal Pod Autoscaling (HPA)**: Automatic scaling based on CPU utilization
- **Resource Limits**: Proper resource requests and limits for predictable performance

## Prerequisites

- Terraform installed and configured
- kubectl installed
- gcloud CLI authenticated with appropriate permissions
- Existing GKE cluster and Cloud SQL instance (from Phase 2)

## Step 1: Update Terraform Configuration

### 1.1 Disable Deletion Protection

Before making location changes, you must disable deletion protection on the existing cluster:

```hcl
# terraform/main.tf
resource "google_container_cluster" "primary" {
  name                     = var.cluster_name
  location                 = var.zone  # Still zonal for now
  deletion_protection      = false     # Add this line
  # ... rest of configuration
}
```

Apply this change first:

```bash
cd terraform
terraform apply -auto-approve
```

### 1.2 Update to Regional Configuration

Now update the cluster and Cloud SQL to be regional:

```hcl
# terraform/main.tf

# GKE Cluster - Change location to region
resource "google_container_cluster" "primary" {
  name                     = var.cluster_name
  location                 = var.region  # Changed from var.zone
  deletion_protection      = false
  # ... rest of configuration
  
  # Remove legacy logging/monitoring service lines
  # logging_service = "logging.googleapis.com/kubernetes"  # REMOVE
  # monitoring_service = "monitoring.googleapis.com/kubernetes"  # REMOVE
  
  # Keep only the config blocks
  logging_config {
    enable_components = ["SYSTEM_COMPONENTS", "WORKLOADS"]
  }
  
  monitoring_config {
    enable_components = ["SYSTEM_COMPONENTS"]
    managed_prometheus {
      enabled = true
    }
  }
}

# GKE Node Pool - Change location to region
resource "google_container_node_pool" "primary_nodes" {
  name       = "${google_container_cluster.primary.name}-node-pool"
  location   = var.region  # Changed from var.zone
  cluster    = google_container_cluster.primary.name
  node_count = 2
  # ... rest of configuration
}

# Cloud SQL - Upgrade to Regional HA
resource "google_sql_database_instance" "main_instance" {
  name             = var.db_instance_name
  database_version = "POSTGRES_14"
  region           = var.region

  settings {
    tier = "db-custom-1-3840"  # Changed from db-f1-micro (minimum for HA)
    availability_type = "REGIONAL"  # Changed from ZONAL
    # ... rest of configuration
  }
}
```

### 1.3 Apply Infrastructure Changes

```bash
cd terraform
terraform apply -auto-approve
```

**Note**: This will destroy and recreate the GKE cluster. The process takes approximately 10-15 minutes.

## Step 2: Update Kubernetes Manifests

### 2.1 Add Resource Requests and Limits

Update `k8s/deployment.yaml` to add resource specifications:

```yaml
spec:
  template:
    spec:
      containers:
      - name: todo-app-go
        image: "us-central1-docker.pkg.dev/PROJECT_ID/todo-app-go/todo-app-go:TAG"
        resources:
          requests:
            cpu: "100m"
            memory: "128Mi"
          limits:
            cpu: "500m"
            memory: "512Mi"
```

**Important**: Replace placeholders:
- `PROJECT_ID`: Your GCP project ID (get with `gcloud config get-value project`)
- `TAG`: Specific image tag from Artifact Registry (not `latest`)

To find available tags:
```bash
gcloud artifacts docker images list \
  us-central1-docker.pkg.dev/PROJECT_ID/todo-app-go/todo-app-go \
  --include-tags
```

### 2.2 Update Cloud SQL Connection

Replace the `${INSTANCE_CONNECTION_NAME}` placeholder with the actual connection name:

```yaml
- name: cloudsql-proxy
  image: gcr.io/cloudsql-docker/gce-proxy:1.17
  command:
    - "/cloud_sql_proxy"
    - "-instances=PROJECT_ID:REGION:INSTANCE_NAME=tcp:5432"
```

Get the connection name from Terraform output:
```bash
cd terraform
terraform output cloudsql_instance_connection_name
```

### 2.3 Create Horizontal Pod Autoscaler

Create `k8s/hpa.yaml`:

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: todo-app-hpa
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: todo-app-go
  minReplicas: 2
  maxReplicas: 10
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 70
```

## Step 3: Configure Database Credentials

### 3.1 Retrieve Database Credentials

Get the database password from Terraform:

```bash
cd terraform
echo "nonsensitive(var.db_password)" | terraform console
```

### 3.2 Create Kubernetes Secret

```bash
kubectl create secret generic db-credentials \
  --from-literal=username=todoappuser \
  --from-literal=password=YOUR_PASSWORD \
  --from-literal=dbname=todoapp_db
```

### 3.3 Update Deployment to Use Secret

Update both `k8s/deployment.yaml` and `k8s/db-init-job.yaml`:

```yaml
env:
- name: DB_USER
  valueFrom:
    secretKeyRef:
      name: db-credentials
      key: username
- name: DB_PASSWORD
  valueFrom:
    secretKeyRef:
      name: db-credentials
      key: password
- name: DB_NAME
  valueFrom:
    secretKeyRef:
      name: db-credentials
      key: dbname
- name: PGPASSWORD  # For db-init-job.yaml only
  valueFrom:
    secretKeyRef:
      name: db-credentials
      key: password
```

## Step 4: Deploy to Kubernetes

### 4.1 Configure kubectl

```bash
gcloud container clusters get-credentials todo-app-cluster --region us-central1
```

### 4.2 Apply Manifests

```bash
kubectl apply -f k8s/
```

### 4.3 Verify Deployment

Check pod status:
```bash
kubectl get pods
```

Check HPA status:
```bash
kubectl get hpa
```

Check job completion:
```bash
kubectl get jobs
```

Expected output:
```
NAME                           READY   STATUS      RESTARTS   AGE
db-init-xxxxx                  0/2     Completed   0          1m
todo-app-go-xxxxxxxxxx-xxxxx   2/2     Running     0          1m
```

### 4.4 Verify Database Initialization

Check db-init logs:
```bash
kubectl logs <db-init-pod-name> -c db-init
```

Should show:
```
Database ready, running init.sql...
CREATE TABLE
Database initialization complete!
```

## Step 5: Verify High Availability Features

### 5.1 Check Regional Cluster

```bash
gcloud container clusters describe todo-app-cluster --region us-central1
```

Verify:
- Location type is `REGIONAL`
- Nodes are distributed across multiple zones

### 5.2 Check Cloud SQL HA

```bash
gcloud sql instances describe todo-app-db-instance
```

Verify:
- `availabilityType: REGIONAL`
- `tier: db-custom-1-3840`

### 5.3 Test HPA Scaling

Generate load to trigger autoscaling:
```bash
kubectl run -i --tty load-generator --rm --image=busybox --restart=Never -- /bin/sh

# Inside the pod:
while true; do wget -q -O- http://todo-app-go-service; done
```

Watch HPA scale up:
```bash
kubectl get hpa -w
```

## Troubleshooting

### Image Pull Errors

If you see `ImagePullBackOff`:
1. Verify the image path is correct (Artifact Registry, not GCR)
2. Ensure you're using a specific tag, not `latest`
3. Check that the GKE node service account has `roles/artifactregistry.reader`

### Database Connection Errors

If pods show database connection errors:
1. Verify the Cloud SQL connection name is correct
2. Check that the `db-credentials` secret exists: `kubectl get secrets`
3. Verify the Cloud SQL proxy is running: `kubectl logs <pod> -c cloudsql-proxy`

### Deletion Protection Errors

If Terraform fails to destroy the cluster:
1. First apply `deletion_protection = false` with the old location
2. Then change the location and apply again

## Cost Considerations

**Warning**: Regional resources increase costs:
- Regional GKE cluster: ~2-3x cost (nodes in multiple zones)
- Regional Cloud SQL: ~2x cost (standby instance + storage replication)
- `db-custom-1-3840`: Higher tier than `db-f1-micro`

Estimated monthly cost increase: $100-200 depending on usage.

## Summary

After completing these steps, you will have:
- ✅ Regional GKE cluster with multi-zone node distribution
- ✅ Regional Cloud SQL with automatic failover
- ✅ Horizontal Pod Autoscaler configured (2-10 replicas)
- ✅ Resource requests and limits for predictable performance
- ✅ Secure credential management via Kubernetes Secrets
- ✅ Initialized database schema

Your application is now highly available and can automatically scale to handle increased load.
