# The Journey to Production
This guide documents the evolution of the `todo-app-go` project from a simple local app to a production-ready system. Each step represents a major milestone in infrastructure, security, or observability.

You can checkout the specific **Git Tag** for each milestone to see the exact state of the code at that point.

## Baseline: The "Toy App"
**Commit:** `2543c44`
**Description:** The starting point. A basic Go web server with a Dockerfile. No cloud infrastructure, no security hardening.


## Base State (Main Branch)
**Commit:** `2543c44`
**Description:** Initial repository state containing:
- Basic Go application code (`main.go`, templates, static assets).
- Docker configuration (`Dockerfile`, `docker-compose.yml`).
- Initial repository analysis scripts.
- Basic CI/CD configuration (work in progress).

## Milestones

### 1. Risk Analysis & Planning
**Tag:** `milestone-risk-analysis`
**Source:** Branch `1-risk-analysis`
**Description:**
- Comprehensive Risk Mitigation Plan.
- Implementation Plan outlining the roadmap.
- **Docs:** [Milestone 1: Risk Analysis](docs/01_RISK_ANALYSIS.md)

### 2. Base Infrastructure (Walking Skeleton)
**Tag:** `milestone-base-infra`
**Source:** Branch `2-gke-cicd-base`
**Description:**
- **Infrastructure:** Basic GKE cluster and single-zone Cloud SQL.
- **CI/CD:** GitHub Actions pipeline.
- **Docs:** [Milestone 2: Base Infrastructure](docs/02_BASE_INFRASTRUCTURE.md)

### 3. High Availability & Scalability
**Tag:** `milestone-ha-scale`
**Source:** Branch `3-ha-scalability`
**Description:**
- **Infrastructure:** Regional GKE cluster and HA Cloud SQL.
- **Scaling:** Horizontal Pod Autoscaler (HPA).
- **Docs:** [Milestone 3: HA & Scalability](docs/03_HA_SCALABILITY.md)

### 4. IAM Authentication (Security)
**Tag:** `milestone-iam-auth`
**Source:** Commit `c712622`
**Description:**
- **Security:** Cloud SQL IAM Authentication.
- **Identity:** Workload Identity for GKE.
- **Docs:** [Milestone 4: IAM Auth & Secrets](docs/04_IAM_AUTH_AND_SECRETS.md)

### 5. Security Hardening
**Tag:** `milestone-security-hardening`
**Source:** Commit `49171cc`
**Description:**
- **Network:** Cloud Armor WAF and HTTPS.
- **App:** Content Security Policy (CSP).
- **Docs:** [Milestone 5: Security Hardening](docs/05_SECURITY_HARDENING.md)

### 6. Advanced Deployment (Canary)
**Tag:** `milestone-advanced-deployment`
**Source:** Commit `36dd27d`
**Description:**
- **Deployment:** Google Cloud Deploy with Canary strategy.
- **Docs:** [Milestone 6: Advanced Deployment](docs/06_ADVANCED_DEPLOYMENT.md)

### 7. Observability & Metrics
**Tag:** `milestone-observability-metrics`
**Source:** Branch `4-secure-configuration`
**Description:**
- **Metrics:** Prometheus instrumentation and PITR.
- **Docs:** [Milestone 7: Observability & Metrics](docs/07_OBSERVABILITY_METRICS.md)

### 8. Resilience & SLOs
**Tag:** `milestone-resilience-slos`
**Source:** Commit `b7c9bdf`
**Description:**
- **Resilience:** Circuit breakers and retries.
- **SLOs:** Availability and Latency targets.
- **Docs:** [Milestone 8: Resilience & SLOs](docs/08_RESILIENCE_SLOS.md)

### 9. Tracing & Polish
**Tag:** `milestone-tracing-polish`
**Source:** Branch `mega-robustness`
**Description:**
- **Observability:** Cloud Trace integration.
- **Docs:** [Milestone 9: Tracing & Polish](docs/09_TRACING_AND_POLISH.md)
