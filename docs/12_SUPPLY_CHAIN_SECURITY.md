# Milestone 12: Supply Chain Security

This document outlines the implementation of comprehensive supply chain security measures to ensure only verified, signed container images can run in production.

## 1. Checkout this Milestone

To deploy this version of the infrastructure:

```bash
git checkout tags/milestone-12-supply-chain
```

## 2. What was Implemented?

We implemented a complete supply chain security pipeline using industry-standard tools and practices.

**Key Features:**

### Automated Vulnerability Scanning
*   **Container Analysis API**: Enabled automatic scanning of all images pushed to Artifact Registry.
*   **CVE Detection**: Images are scanned for known vulnerabilities (OS packages and application dependencies).
*   **Continuous Monitoring**: New vulnerabilities are detected as they are disclosed.
*   *Benefit*: Catch security issues before they reach production.

### Image Signing with Cosign
*   **Keyless Signing**: Integrated Cosign into GitHub Actions using Sigstore's keyless infrastructure.
*   **OIDC Authentication**: GitHub Actions uses OIDC tokens to sign images without managing private keys.
*   **Transparency Log**: All signatures are recorded in Rekor (public transparency log).
*   *Benefit*: Cryptographic proof that images were built by your trusted CI/CD pipeline.

### Binary Authorization
*   **Admission Control**: GKE cluster configured to enforce Binary Authorization policies.
*   **Signed-Only Images**: Only images with valid Cosign signatures can be deployed.
*   **System Whitelist**: GKE system images (kube-system, gke-system) are whitelisted.
*   **Evaluation Mode**: `PROJECT_SINGLETON_POLICY_ENFORCE` - blocks unsigned images.
*   *Benefit*: Prevents deployment of tampered, untrusted, or compromised images.

### GitOps Alignment
*   **Removed Cloud Deploy**: Eliminated push-based deployment from CI/CD.
*   **ArgoCD-Only Deployments**: All deployments now handled by ArgoCD watching the Git repository.
*   **Separation of Concerns**: CI builds and signs; GitOps deploys.
*   *Benefit*: True declarative infrastructure with Git as the single source of truth.

## 3. Pitfalls & Considerations

*   **Existing Workloads**: When Binary Authorization is first enabled, existing unsigned workloads may fail to restart. Ensure all images are signed before enabling enforcement.
*   **Emergency Bypass**: In case of emergency, you can temporarily disable Binary Authorization by setting `evaluation_mode = "DISABLED"` in Terraform.
*   **System Images**: The policy whitelists common GKE system image registries (`gcr.io/google_containers/*`, `gke.gcr.io/*`). If you use other system images, add them to the whitelist.
*   **Signature Verification Time**: Image admission adds ~100-200ms latency to pod creation while signatures are verified.

## 4. Alternatives Considered

*   **Notary/TUF**: An alternative signing framework. We chose Cosign for its simplicity and keyless signing support.
*   **Kyverno**: A Kubernetes-native policy engine that can also verify signatures. We chose Binary Authorization for its tight GKE integration and Google-managed infrastructure.
*   **Manual Signing**: Signing images locally. We chose automated signing in CI to ensure consistency and auditability.

## 5. Verification

### Check Vulnerability Scan Results
```bash
# List recent images
gcloud artifacts docker images list \
  us-central1-docker.pkg.dev/GCP_PROJECT_ID/todo-app-go/todo-app-go \
  --limit=5

# View vulnerabilities for a specific image
gcloud artifacts docker images describe \
  us-central1-docker.pkg.dev/GCP_PROJECT_ID/todo-app-go/todo-app-go@sha256:DIGEST \
  --show-package-vulnerability
```

### Verify Image Signature
```bash
# Install cosign locally (if not already installed)
brew install cosign

# Verify the signature on an image
cosign verify \
  us-central1-docker.pkg.dev/GCP_PROJECT_ID/todo-app-go/todo-app-go:TAG \
  --certificate-identity-regexp="https://github.com/stevemcghee/go-to-production/.*" \
  --certificate-oidc-issuer="https://token.actions.githubusercontent.com"
```

### Check Binary Authorization Status
```bash
# Verify Binary Authorization is enabled on the cluster
gcloud container clusters describe todo-app-cluster \
  --region=us-central1 \
  --format="value(binaryAuthorization.evaluationMode)"

# Should return: PROJECT_SINGLETON_POLICY_ENFORCE

# View the Binary Authorization policy
gcloud beta container binauthz policy export
```

### Test Enforcement
Try to deploy an unsigned image to verify the policy blocks it:

```bash
# This should be BLOCKED by Binary Authorization
kubectl run test-unsigned --image=nginx:latest -n todo-app
# Expected error: "image policy webhook backend denied one or more images"
```

## 6. CI/CD Flow

The new supply chain security flow:

```
1. Developer pushes code to GitHub
2. GitHub Actions triggers:
   a. Build Go application
   b. Run tests (unit, chaos)
   c. Security scan (Gosec, Trivy)
   d. Build Docker image
   e. Push to Artifact Registry
   f. Sign image with Cosign (keyless)
3. Artifact Registry automatically scans image for vulnerabilities
4. Developer updates k8s/kustomization.yaml with new image tag
5. ArgoCD detects change and syncs to cluster
6. Binary Authorization verifies signature before allowing deployment
7. If signature is valid, pods are created
```

## 7. Troubleshooting

### Image Deployment Blocked

**Symptom**: Pods stuck in `Pending` or `ImagePullBackOff` with error about "image policy webhook backend denied".

**Cause**: Image is not signed or signature is invalid.

**Solution**:
1. Verify the image was built by GitHub Actions (check workflow logs)
2. Check if the image has a signature:
   ```bash
   cosign verify us-central1-docker.pkg.dev/GCP_PROJECT_ID/todo-app-go/todo-app-go:TAG \
     --certificate-identity-regexp="https://github.com/stevemcghee/go-to-production/.*" \
     --certificate-oidc-issuer="https://token.actions.githubusercontent.com"
   ```
3. If unsigned, trigger a new build or manually sign the image

### Vulnerability Scan Not Showing

**Symptom**: No vulnerability data available for images.

**Cause**: Container Scanning API may not be enabled or scan is still in progress.

**Solution**:
1. Verify API is enabled:
   ```bash
   gcloud services list --enabled --filter="name:containerscanning.googleapis.com"
   ```
2. Wait a few minutes - initial scans can take 5-10 minutes
3. Check the Artifact Registry UI for scan status

## 8. Cost Impact

Supply chain security features add minimal cost:

*   **Container Scanning**: Free for the first 1,000 scans per month, then $0.26 per image scan
*   **Binary Authorization**: Free (no additional charge)
*   **Cosign/Sigstore**: Free (open source, public infrastructure)
*   **Estimated Impact**: ~$0.10-0.50/day depending on build frequency

## 9. Next Steps

Potential enhancements:

*   **SBOM Generation**: Generate Software Bill of Materials (SBOM) for each image
*   **Vulnerability Blocking**: Configure Binary Authorization to also block images with CRITICAL vulnerabilities
*   **Private Sigstore**: Deploy a private Sigstore instance for air-gapped environments
*   **Attestation Policies**: Add custom attestations (e.g., "passed security review", "approved for production")
