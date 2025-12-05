| Risk | Probability | Blast-Radius | Cost | Status | Mitigation Plan |
| :--- | :---: | :---: | :---: | :---: | :--- |
| **Mitigated Risks** | | | | | |
| No Automated Health Checks or Recovery | **High** | 🔥🔥 | 💸💸 | ✅ Complete | [Mitigations in Place](#mitigations-in-place) |
| Containerization for Production | **High** | 🔥🔥 | 💸 | ✅ Complete | [Mitigations in Place](#mitigations-in-place) |
| Manual and Error-Prone Deployments (CI/CD) | **High** | 🔥🔥 | 💸 | ✅ Complete | [Mitigations in Place](#mitigations-in-place) |
| Observability Failures | **High** | 🔥🔥🔥 | 💸💸 | ✅ Complete | [Mitigations in Place](#mitigations-in-place) |
| **Remaining Risks (Ordered by Probability)** | | | | | |
| Single Point of Failure (SPOF) - Application | **High** | 🔥🔥 | 💸💸 | 🟡 Pending | [Mitigating Application SPOF and Lack of Scalability](#1-mitigating-application-spof-and-lack-of-scalability) |
| Single Point of Failure (SPOF) - Database | **High** | 🔥🔥🔥 | 💸💸💸 | 🟡 Pending | [Mitigating Database SPOF and Data Loss/Durability Issues](#2-mitigating-database-spof-and-data-lossdurability-issues) |
| Lack of Scalability | **High** | 🔥🔥 | 💸💸 | 🟡 Pending | [Mitigating Application SPOF and Lack of Scalability](#1-mitigating-application-spof-and-lack-of-scalability) |
| Insecure and Inflexible Configuration | **High** | 🔥🔥🔥 | 💸💸💸 | 🟡 Pending | [Mitigating Insecure and Inflexible Configuration](#4-mitigating-insecure-and-inflexible-configuration) |
| DDoS attacks or other security concerns | **Medium** | 🔥🔥🔥 | 💸💸💸 | 🟡 Pending | [Mitigating DDoS and Other Security Concerns](#8-mitigating-ddos-and-other-security-concerns) |
| Zonal and Regional Failure | **Medium** | 🔥🔥🔥 | 💸💸💸 | 🟡 Pending | [Mitigating Zonal and Regional Failure](#3-mitigating-zonal-and-regional-failure) |
| Data Loss and Durability | **Medium** | 🔥🔥🔥 | 💸💸💸 | 🟡 Pending | [Mitigating Database SPOF and Data Loss/Durability Issues](#2-mitigating-database-spof-and-data-lossdurability-issues) |
| GKE Control Plane or Infrastructure Failure | **Low** | 🔥🔥🔥 | 💸💸💸 | 🟡 Pending | [Mitigating GKE Control Plane or Infrastructure Failure](#9-mitigating-gke-control-plane-or-infrastructure-failure) |
| CI/CD Infrastructure or Service Failure | **Low** | 🔥 | 💸 | 🟡 Pending | [Mitigating CI/CD Infrastructure Failure](#7-mitigating-ci/cd-infrastructure-failure) |
| Total GCP Failure or Multi-Region Outage | **Very Low** | 🔥🔥🔥🔥 | 💸💸💸💸 | 🟡 Pending | [Mitigating Total GCP Failure](#6-mitigating-total-gcp-failure) |

---


# Risk Mitigation Plan for todo-app-go

This document outlines identified infrastructure and dependency risks for the `todo-app-go` project and proposes a mitigation plan to enhance its reliability, scalability, and observability.

## Mitigations in Place

1.  **Implement Health Checks**
    *   **Status:** Complete
    *   **Description:** An HTTP `/healthz` endpoint was added to the Go application to check database connectivity. `docker-compose.yml` was updated to configure Docker health checks, and `curl` was added to the `Dockerfile` for execution of the health check command within the container.

2.  **Containerize for Production**
    *   **Status:** Complete
    *   **Description:** The `Dockerfile` was updated to use a multi-stage build, run the application as a non-root user (`appuser`), and optimize the image size.

3.  **Manual and Error-Prone Deployments (CI/CD):**
    *   **Mitigation:** A basic CI/CD pipeline has been created using GitHub Actions (`.github/workflows/build-test.yml`). This pipeline automatically builds and tests the application on every push or pull request to the `main` branch. This reduces the risk of manual deployment errors and ensures a consistent build process.

4.  **Observability Failures:**
    *   **Mitigation:** Observability has been enhanced by:
        *   **Structured Logging:** The application now uses the `log/slog` library for structured JSON logging, making logs easier to parse and analyze.
        *   **Metrics Endpoint:** A `/metrics` endpoint has been added to expose Prometheus-compatible metrics, providing visibility into the application's performance and health.

## Remaining Risks

1.  **Single Point of Failure (SPOF) for Application:** The application still runs as a single container in the local Docker environment. If this container crashes, the service will be unavailable.

2.  **Single Point of Failure (SPOF) for Database:** The database still runs as a single container. If the database fails, the application will be unable to read or write data.

3.  **Data Loss and Durability:** The database relies on a local Docker volume. This data is not backed up, is not replicated, and could be lost if the host machine fails.

4.  **Lack of Scalability:** The current single-instance architecture cannot handle any significant load.

5.  **Zonal and Regional Failure:** The entire application stack runs on a single machine, making it completely vulnerable to failures of that machine or its location.

6.  **Insecure and Inflexible Configuration:** Database credentials are still managed via environment variables and `.env` files, which is not secure for production.

7.  **Compute Service or Regional Failure within GCP:** The proposed single-region deployment is vulnerable to failures affecting all zones within that region, such as network partitions, power outages, or natural disasters.

8.  **Total GCP Failure or Multi-Region Outage:** While rare, a catastrophic event could disrupt GCP services across multiple regions, or a misconfiguration could propagate globally, making the application inaccessible.

9.  **CI/CD Infrastructure or Service Failure:** The current reliance on a single CI/CD provider (GitHub Actions) creates a single point of failure for the deployment pipeline. If GitHub Actions is unavailable, it may not be possible to deploy new versions of the application, even if the production infrastructure is healthy.

10. **DDoS attacks or other security concerns:** The current setup has minimal protection against malicious traffic like Distributed Denial of Service (DDoS) attacks, SQL injection, or cross-site scripting (XSS). An attack could make the service unavailable or compromise user data.

11. **GKE Control Plane or Infrastructure Failure:** While GKE provides a highly available control plane, a rare failure could still impact the availability of the Kubernetes API server, scheduler, or other core components, or the underlying compute infrastructure, preventing new deployments, scaling operations, or even impacting running workloads.

---

### Proposed Mitigations for Remaining Risks

This section details the proposed solutions to address the outstanding risks identified in the "Remaining Risks" section. These proposals focus on moving the application to a production-ready cloud environment.

#### 1. Mitigating Application SPOF and Lack of Scalability

**Proposal:** Deploy the application to a managed Kubernetes cluster (e.g., Google Kubernetes Engine - GKE) on GCP.

**Details:**
*   **Container Orchestration:** Kubernetes will manage the application containers, ensuring that a specified number of replicas are always running. If a container or node fails, Kubernetes will automatically restart it or reschedule it on a healthy node, eliminating the single point of failure.
*   **Horizontal Pod Autoscaling (HPA):** Configure HPA to automatically scale the number of application pods up or down based on CPU or memory usage. This will allow the application to handle varying loads efficiently.
*   **Load Balancing:** Use a Kubernetes Service of type `LoadBalancer`. This will provision a cloud load balancer (e.g., a Google Cloud Load Balancer) to distribute traffic across the application pods, providing a single entry point to the application and improving availability.

#### 2. Mitigating Database SPOF and Data Loss/Durability Issues

**Proposal:** Replace the local Docker volume with a managed, high-availability database service like Google Cloud SQL for PostgreSQL.

**Details:**
*   **High Availability (HA):** Provision a Cloud SQL instance in a regional configuration. This will create a primary instance and a standby instance in a different zone within the same region. In case of a zonal failure, Cloud SQL will automatically fail over to the standby instance with minimal downtime.
*   **Automated Backups:** Configure automated backups for the Cloud SQL instance. This will allow for point-in-time recovery, protecting against data loss due to accidental deletion or corruption.
*   **Replication:** For disaster recovery, configure cross-region replicas. This will create a read replica of the database in a different region, which can be promoted to a standalone instance in the event of a regional outage.

#### 3. Mitigating Zonal and Regional Failure

**Proposal:** Deploy the application and database across multiple availability zones and regions.

**Details:**
*   **Multi-Zone Deployment:** The GKE cluster will be configured as a regional cluster, with node pools spanning multiple availability zones within the chosen region (e.g., `us-central1-a`, `us-central1-b`, `us-central1-c`). This ensures that the application can tolerate the failure of a single availability zone.
*   **Multi-Region Deployment (for DR):** For the highest level of availability, the application can be deployed to multiple regions. This would involve:
    *   Deploying a GKE cluster in each region.
    *   Using a global load balancer to direct traffic to the closest healthy region.
    *   Setting up cross-region replication for the Cloud SQL instance.

#### 4. Mitigating Insecure and Inflexible Configuration

**Proposal:** Use Google Secret Manager to store and manage sensitive information like database credentials.

**Details:**
*   **Secrets Management:** Instead of storing the database password in `.env` files or Kubernetes Secrets directly, it will be stored in Google Secret Manager.
*   **Workload Identity:** The GKE cluster will be configured with Workload Identity, which allows Kubernetes service accounts to impersonate Google service accounts. The application pod will be assigned a Kubernetes service account that has permission to access the secret in Secret Manager.
*   **Dynamic Configuration:** The application will be modified to fetch the database password from Secret Manager at runtime. This eliminates the need to store secrets in source code or configuration files, improving security and making configuration changes easier to manage.

#### 5. Mitigating GCP Service or Regional Failure

**Proposal:** Implement a multi-region deployment strategy for the application and database.

**Details:**
*   **Multi-Region GKE Deployment:** Deploy a GKE cluster in a secondary region (e.g., `us-west1`). This provides an independent environment to fail over to.
*   **Global Load Balancing:** Use a Google Cloud Global External Load Balancer with multiple backend services, one for each regional GKE cluster. The load balancer can be configured with health checks to automatically direct traffic away from an unhealthy region to the healthy one, providing seamless failover for users.
*   **Cross-Region Database Replication:** Configure the Cloud SQL for PostgreSQL instance with a cross-region read replica in the secondary region. In the event of a primary region failure, this replica can be manually or automatically promoted to a standalone, writable instance.

#### 6. Mitigating Total GCP Failure

**Proposal:** Implement a multi-cloud deployment strategy, with a secondary deployment on a different cloud provider (e.g., Amazon Web Services - AWS).

**Details:**
*   **Multi-Cloud Architecture:** Replicate the production infrastructure on AWS using services like Amazon EKS (Elastic Kubernetes Service) for container orchestration and Amazon RDS for PostgreSQL as the database. Infrastructure as Code (IaC) tools like Terraform can be used to manage deployments across both clouds.
*   **DNS-Based Failover:** Use a DNS provider with health checking and failover capabilities (e.g., Amazon Route 53, Cloudflare DNS). Configure DNS records to point to both the GCP and AWS deployments. If the primary cloud provider (GCP) becomes unavailable, DNS can automatically redirect traffic to the secondary deployment on AWS.
*   **Data Synchronization:** Implement a data synchronization mechanism between the GCP and AWS databases. This could involve regular backups and restores, or more advanced asynchronous replication strategies, depending on the Recovery Time Objective (RTO) and Recovery Point Objective (RPO) requirements.

#### 7. Mitigating CI/CD Infrastructure Failure

**Proposal:** Implement a secondary, on-demand deployment path that can be used if the primary CI/CD system is unavailable.

**Details:**
*   **Local Deployment Scripts:** Create and maintain a set of well-documented local deployment scripts that can be run from a developer's machine. These scripts would perform the same actions as the CI/CD pipeline (e.g., build, push Docker image, update Kubernetes deployment).
*   **Break-Glass Procedure:** Define a "break-glass" procedure that outlines the steps to take in the event of a CI/CD outage. This would include who is authorized to perform a manual deployment, what approvals are needed, and how to execute the local deployment scripts.
*   **Multi-Provider CI/CD (Advanced):** For a more advanced solution, consider mirroring the CI/CD pipeline on a different provider (e.g., GitLab CI/CD, CircleCI). This would provide a fully redundant deployment path, but would also increase complexity and maintenance overhead.

#### 8. Mitigating DDoS and Other Security Concerns

**Proposal:** Implement a layered security approach using cloud-native services and application-level hardening.

**Details:**
*   **Web Application Firewall (WAF):** Use a WAF service like Google Cloud Armor to protect against common web exploits and DDoS attacks. Cloud Armor can be integrated with the Global External Load Balancer to provide rate limiting, IP-based blocking, and protection against OWASP Top 10 vulnerabilities.
*   **Input Validation and Sanitization:** Strengthen the application code to perform strict input validation on all user-supplied data to prevent injection attacks. Use prepared statements for all database queries (which is already being done) to prevent SQL injection.
*   **Content Security Policy (CSP):** Implement a strict Content Security Policy to mitigate the risk of cross-site scripting (XSS) and other code injection attacks.
*   **Regular Security Scanning:** Integrate automated security scanning tools into the CI/CD pipeline. This includes static application security testing (SAST) to find vulnerabilities in the source code and dynamic application security testing (DAST) to scan the running application for vulnerabilities.

#### 9. Mitigating GKE Control Plane or Infrastructure Failure

**Proposal:** Implement an alternative, simpler deployment target for critical fallback scenarios, leveraging a different compute service.

**Details:**
*   **Alternative Runtime (Cloud Run):** For critical services, deploy a redundant copy of the application to Google Cloud Run. Cloud Run offers a fully managed, serverless platform for containerized applications, abstracting away Kubernetes complexities and providing a separate failure domain from GKE's control plane.
*   **Traffic Management and Failover:** Configure a global load balancer (e.g., Google Cloud Load Balancer) to direct traffic between the primary GKE deployment and the fallback Cloud Run service. Health checks would enable automatic routing to Cloud Run if the GKE service becomes unhealthy.
*   **Simplicity and Cost-Effectiveness:** Cloud Run provides a simpler operational model and scales down to zero, making it a cost-effective standby solution for disaster recovery. The application would need to be designed to be stateless or capable of connecting to the shared Cloud SQL instance.