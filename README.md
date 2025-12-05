# go-to-production: A Cloud-Native Journey

> **Note:** This is a "toy" application. The code itself (a simple To-Do list) is intentionally basic. The real value of this repository is the **infrastructure, security, and observability** wrapper around it. It demonstrates how to take a simple app and make it production-ready on Google Cloud.

## Purpose

This repository serves as a reference implementation for modern cloud-native practices on Google Cloud Platform (GCP). It evolves from a simple local Docker setup to a highly available, secure, and observable system running on GKE.

**Key Concepts Demonstrated:**
*   **Infrastructure as Code**: Terraform for GKE, Cloud SQL, and IAM.
*   **CI/CD**: GitHub Actions + Google Cloud Deploy for automated canary releases.
*   **Security**: Workload Identity, Secret Manager, Cloud Armor WAF, and IAM Auth.
*   **Observability**: Prometheus metrics, Cloud Trace, and SLO monitoring.
*   **Resilience**: Circuit breakers, retries, and regional high availability.

## Navigating the Journey

This repository uses **Git Tags** to mark specific points in the productionization journey. You can check out any tag to see the code exactly as it was at that stage.

**How to use tags:**

1.  **List all tags:**
    ```bash
    git tag -l
    ```
2.  **Checkout a specific milestone:**
    ```bash
    git checkout tags/milestone-base-infra
    ```
3.  **Return to the latest version:**
    ```bash
    git checkout main
    ```



---

## Baseline Application

If you want to run the simple, local version of the app (without any cloud dependencies), please refer to **[Milestone 0: Baseline Application](docs/00_BASELINE.md)**.

The `main` branch contains cloud-specific code that will not run locally without GCP credentials.

## Technologies Used

*   **Backend**: Go
*   **Database**: PostgreSQL (Cloud SQL with HA + Read Replica)
*   **Containerization**: Docker, Docker Compose
*   **Frontend**: HTML, CSS, JavaScript (served statically)
*   **Cloud**: Google Cloud Platform (GKE, Cloud SQL, Artifact Registry, Cloud Deploy)
*   **Authentication**: Workload Identity, Cloud SQL IAM Authentication
*   **Resilience**: cenkalti/backoff, sony/gobreaker
*   **Observability**: Prometheus, Cloud Monitoring

## Milestones

Each milestone represents a specific tag in the git history. You can checkout these tags to see the code at that stage.

| Milestone | Tag | Description |
| :--- | :--- | :--- |
| **0. Baseline** | `baseline` | Simple Go app + Docker Compose. [Docs](docs/00_BASELINE.md) |
| **1. Risk Analysis** | `milestone-risk-analysis` | Risk mitigation & implementation plans. [Docs](docs/01_RISK_ANALYSIS.md) |
| **2. Base Infra** | `milestone-base-infra` | GKE, Cloud SQL, CI/CD pipeline. [Docs](docs/02_BASE_INFRASTRUCTURE.md) |
| **3. HA & Scale** | `milestone-ha-scale` | Regional GKE, HA Cloud SQL, HPA. [Docs](docs/03_HA_SCALABILITY.md) |
| **4. IAM Auth** | `milestone-iam-auth` | Workload Identity, Cloud SQL IAM Auth. [Docs](docs/04_IAM_AUTH_AND_SECRETS.md) |
| **5. Security** | `milestone-security-hardening` | Cloud Armor WAF, HTTPS, CSP. [Docs](docs/05_SECURITY_HARDENING.md) |
| **6. Advanced Deploy** | `milestone-advanced-deployment` | Cloud Deploy, Canary releases. [Docs](docs/06_ADVANCED_DEPLOYMENT.md) |
| **7. Observability** | `milestone-observability-metrics` | Prometheus metrics, PITR. [Docs](docs/07_OBSERVABILITY_METRICS.md) |
| **8. Resilience** | `milestone-resilience-slos` | Circuit breakers, retries, SLOs. [Docs](docs/08_RESILIENCE_SLOS.md) |
| **9. Tracing** | `milestone-tracing-polish` | Cloud Trace integration. [Docs](docs/09_TRACING_AND_POLISH.md) |

See **[Milestone 0: Baseline Application](docs/00_BASELINE.md)** for instructions on running the local development version.

See **[Runbook](docs/RUNBOOK.md)** for operational procedures.
