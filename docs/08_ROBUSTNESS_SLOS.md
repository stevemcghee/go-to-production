# Milestone 8: Robustness & SLOs

This document outlines the implementation of application robustness patterns and Service Level Objectives.

## 1. Checkout this Milestone

To deploy this version of the infrastructure:

```bash
git checkout tags/milestone-resilience-slos
```

## 2. What was Implemented?

We made the application "tougher" and defined what "healthy" means.

**Key Features:**
*   **Circuit Breakers**: Implemented in Go code to stop hammering the database if it fails.
    *   *Benefit*: Prevents cascading failures and allows the system to recover faster.
*   **Exponential Backoff**: Retries failed database operations with increasing delays.
    *   *Benefit*: Handles transient network blips gracefully.
*   **SLOs (Service Level Objectives)**: Defined targets for Availability (99.9%) and Latency.
    *   *Benefit*: Data-driven alerting based on user impact (Burn Rate alerts) rather than raw thresholds.
*   **Load Generator**: A tool to generate synthetic traffic for testing.

## 3. Pitfalls & Considerations

*   **Retry Storms**: Retrying without jitter or limits can take down a recovering service. We implemented capped exponential backoff.
*   **SLO Complexity**: Defining the right SLO is hard. We started with a basic "Availability" SLO and refined it.
*   **Alert Fatigue**: Burn rate alerting is complex to set up but reduces false positives compared to static thresholds.

## 4. Alternatives Considered

*   **Service Mesh (Istio)**: Can handle retries/circuit breaking at the network layer.
    *   *Why Library?* For a simple app, adding a service mesh is significant operational overhead. Library-based robustness is simpler to start with.
