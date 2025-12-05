# Milestone 9: Tracing & Polish

This document outlines the final steps to production readiness, including distributed tracing and system polish.

## 1. Checkout this Milestone

To deploy this version of the infrastructure:

```bash
git checkout tags/milestone-tracing-polish
```

## 2. What was Implemented?

We added the final layer of observability and cleaned up technical debt.

**Key Features:**
*   **Cloud Trace**: Distributed tracing for all HTTP requests and database queries.
    *   *Benefit*: Visualizing the exact path of a request to identify latency bottlenecks (e.g., "Why did this request take 2s?").
*   **GKE Backup**: Enabled Backup for GKE.
    *   *Benefit*: Disaster recovery for the cluster configuration and persistent volumes.
*   **Dashboard Polish**: Finalized Cloud Monitoring dashboards.
    *   *Benefit*: Single pane of glass for system health.

## 3. Pitfalls & Considerations

*   **Sampling Rates**: Tracing every request is expensive. We used a sampler to capture a representative percentage of traffic.
*   **Instrumentation Gaps**: Traces are only useful if they cover the whole path. We had to manually instrument the database driver to see SQL query times.

## 4. Alternatives Considered

*   **Jaeger/Zipkin**: Self-hosted tracing.
    *   *Why Cloud Trace?* Fully managed, no infrastructure to maintain, and integrated with Cloud Logging.
