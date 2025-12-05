# Milestone 7: Observability & Metrics

This document outlines the implementation of Prometheus metrics and database recovery.

## 1. Checkout this Milestone

To deploy this version of the infrastructure:

```bash
git checkout tags/milestone-observability-metrics
```

## 2. What was Implemented?

We added "eyes" to the application to understand its internal state.

**Key Features:**
*   **Prometheus Metrics**: Application instrumented to export HTTP request counts, latency, and business metrics (todos created/deleted).
    *   *Benefit*: Real-time visibility into application performance and usage.
*   **Point-in-Time Recovery (PITR)**: Enabled for Cloud SQL.
    *   *Benefit*: Ability to restore the database to any specific second in the last 7 days (e.g., right before a bad deployment).
*   **Google Managed Prometheus**: Scrapes metrics without managing a Prometheus server.
    *   *Benefit*: Scalable, managed monitoring backend.

## 3. Pitfalls & Considerations

*   **Cardinality**: We had to be careful not to include high-cardinality data (like User IDs or Todo IDs) in metric labels, which can explode costs.
*   **Storage Costs**: PITR increases storage usage significantly (logs + backups).
*   **Metric Noise**: It's easy to collect too many metrics. We focused on the "Golden Signals" (Latency, Traffic, Errors, Saturation).

## 4. Alternatives Considered

*   **Cloud Logging-based Metrics**: Creating metrics from logs.
    *   *Why Prometheus?* Lower latency and industry standard for timeseries data.
*   **Datadog/NewRelic**: SaaS monitoring.
    *   *Why Managed Prometheus?* Native integration with GKE and lower cost for this scale.
