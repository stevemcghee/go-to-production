# Milestones 18–22: Extreme Reliability — The Apollo Program for Cloud

> *"The Apollo guidance computer had triple-redundant hardware, N-version
> software, and voting logic. If we ran web services like we ran moon missions,
> here's what that would look like."*

These milestones go beyond industry-standard practices into the territory of
**ultra-high-reliability systems**: aviation, space flight, nuclear safety, and
financial clearing. They are aspirational — each one is a research project as
much as an engineering effort.

The guiding principle: **no single anything.** No single cloud, no single
codebase, no single team's assumptions, no single point of failure at any layer
of the stack — including the software itself.

---

## Milestone 18: N-Version Redundancy (`milestone-18-n-version`)

### The Apollo Inspiration

Apollo's guidance computer ran three independent implementations of critical
navigation routines. If two agreed and one disagreed, the odd one out was
overridden. The key insight: **independent implementations fail independently.**
A bug in one version is unlikely to exist in another written by a different team
with different tools.

### What This Means for a Cloud Service

1. **Reimplement the critical path in a second language:**
   - The Go todo API handles CRUD and database operations.
   - Write a second, independent implementation in **Rust** (or Python, or Java)
     that implements the same API contract.
   - Both versions are deployed side-by-side.

2. **Request routing with comparison:**
   - A lightweight proxy (Envoy, or a custom Go sidecar) sends every write
     request to **both** implementations.
   - Reads can be served by either (load-balanced).
   - For writes, the proxy compares responses:
     - If both return success → commit.
     - If one fails → log divergence, serve the successful response, alert.
     - If both fail → return error.

3. **Reimplement critical dependencies from scratch:**
   - Identify the top 3 most critical imported libraries (e.g., SQL driver,
     HTTP router, circuit breaker).
   - Write minimal, purpose-built replacements that implement only the subset
     of functionality actually used.
   - Benefits: smaller attack surface, no transitive dependency risk, full
     understanding of every line in the critical path.

4. **Vendored and audited dependency tree:**
   - Vendor all Go modules (`go mod vendor`).
   - Cryptographically hash every vendored dependency and store hashes in a
     `DEPS.lock` file checked into the repo.
   - CI verifies hashes on every build — any upstream tampering is detected.

### Deliverables

| Deliverable | Details |
|-------------|---------|
| `cmd/todo-rust/` | Second implementation of the API in Rust |
| `internal/proxy/` | Comparison proxy that fans out to both backends |
| `internal/sql/` | Minimal SQL driver wrapper (replace `lib/pq` for critical path) |
| `internal/breaker/` | Purpose-built circuit breaker (replace `gobreaker`) |
| `DEPS.lock` | Cryptographic hashes of all vendored dependencies |
| CI check | Hash verification step in `build-test.yml` |

### Verification

- [ ] Both implementations pass the same integration test suite.
- [ ] Comparison proxy detects an intentionally injected divergence.
- [ ] Dependency hash check catches a simulated tampering event.

### Why This Matters

Most outages are caused by software bugs, not hardware failures. The only way to
survive a bug in your own code is to have a second, independent codebase that
doesn't share the same bug. This is how aviation achieves "six nines" — it's not
about retrying; it's about not having a single implementation.

---

## Milestone 19: Autonomous Self-Healing (`milestone-19-self-healing`)

### The Problem With Alerts

Current state: something breaks → alert fires → human reads runbook → human
runs commands → system recovers. This is **MTTR limited by human response time**
(minutes to hours, depending on time of day).

### What Self-Healing Looks Like

1. **Gray failure detection:**
   - Not everything is a clean crash. Some failures are *gray*: the process is
     running, the health check passes, but responses are wrong, slow, or
     corrupted.
   - Implement **semantic health checks** that validate response *correctness*,
     not just liveness:
     ```go
     // Instead of just checking DB ping:
     // 1. Write a canary row
     // 2. Read it back
     // 3. Verify the content matches
     // 4. Delete it
     // If any step fails or returns wrong data → mark unhealthy
     ```

2. **Automated remediation controllers:**
   - Kubernetes Operator (custom controller) that watches for known failure
     patterns and executes remediation:
     - Circuit breaker open for > 5 minutes → restart pods.
     - Memory usage > 90% for > 2 minutes → trigger GC or restart.
     - Replication lag > 30 seconds → alert and optionally redirect reads to
       primary.
     - Disk usage > 80% → trigger log rotation or scale PVC.

3. **Closed-loop SLO automation:**
   - SLO burn rate triggers automated responses, not just alerts:
     - Slow burn → automatically scale up replicas.
     - Fast burn → automatically roll back the last deployment.
     - Budget exhausted → automatically freeze deployments (CI gate).

4. **Chaos-driven self-healing validation:**
   - Run chaos experiments (from Milestone 15) continuously.
   - The self-healing controller must fix the injected failure without
     human intervention.
   - If it doesn't → that's a test failure, not a production incident.

### Deliverables

| Deliverable | Details |
|-------------|---------|
| `internal/healthcheck/` | Semantic health checks (canary write/read/verify) |
| `k8s/base/operator/` | Self-healing Kubernetes operator (CRD + controller) |
| `terraform/alerts.tf` | SLO → automated action bindings |
| `test/chaos/self-healing/` | Chaos experiments that validate autonomous recovery |

---

## Milestone 20: Cell-Based Architecture (`milestone-20-cell-architecture`)

### The Principle

A cell is a fully independent, isolated copy of the entire stack. Cells share
nothing — not load balancers, not databases, not control planes. If one cell
fails catastrophically (data corruption, security breach, runaway process), the
blast radius is limited to that cell's users.

### Architecture

```
                    ┌───────────────────┐
                    │  Global Router    │
                    │  (by user hash)   │
                    └─┬──────┬──────┬──┘
                      │      │      │
               ┌──────▼┐ ┌──▼────┐ ┌▼──────┐
               │Cell A │ │Cell B │ │Cell C │
               │GKE+SQL│ │GKE+SQL│ │GKE+SQL│
               │Users  │ │Users  │ │Users  │
               │0-33%  │ │34-66% │ │67-100%│
               └───────┘ └───────┘ └───────┘
```

### What to Implement

1. **Shuffle sharding:** Assign users to cells based on a consistent hash of
   their user ID. Each cell handles ~1/N of all users.

2. **Cell provisioning via Terraform modules:**
   - Parameterize the entire stack (GKE + Cloud SQL + networking) as a
     reusable Terraform module.
   - Spin up a new cell by adding a module block with a cell ID.

3. **Cell-level isolation:**
   - Separate GCP projects per cell (strongest blast radius boundary).
   - Or: separate namespaces with NetworkPolicy + ResourceQuota (lighter).

4. **Cell-aware deployment:**
   - Deploy to one cell first (canary cell).
   - Monitor for 30 minutes.
   - Roll out to remaining cells progressively.

5. **Cell draining and migration:**
   - Ability to drain a cell and redistribute its users to other cells.
   - Used for maintenance, incident response, or decommissioning.

### Why This Matters

Without cells, a single bad database migration can corrupt data for 100% of
users. With 10 cells, the worst case is 10%. This is how AWS, Azure, and
Google themselves architect their internal services.

---

## Milestone 21: Formal Verification & Provable Correctness (`milestone-21-formal-verification`)

### The Problem

Testing proves the presence of bugs, never their absence. For the most critical
paths (data writes, financial transactions, access control), we want *proofs*
that the code is correct.

### What to Implement

1. **Specify critical invariants** in a formal specification language:
   - *"A todo item that has been created is always retrievable until explicitly
     deleted."*
   - *"No request can modify a todo belonging to a different user."*
   - *"The count of todos returned by GET /todos equals the number of INSERT
     operations minus the number of DELETE operations."*

2. **Property-based testing (lightweight formal methods):**
   - Use Go's `testing/quick` or a library like `gopter` to generate random
     inputs and verify invariants hold across thousands of cases.
   - Example: for any sequence of Create/Delete operations, the final count
     matches the expected count.

3. **Model checking for state machines:**
   - The circuit breaker has three states (Closed, Open, Half-Open) with
     defined transitions.
   - Model this in TLA+ or Alloy and verify:
     - No deadlocks (always a valid transition).
     - Liveness (eventually returns to Closed if failures stop).
     - Safety (never serves traffic when Open).

4. **Deterministic, reproducible builds:**
   - Pin every tool version (Go, Docker, Terraform, kubectl).
   - Use `go build -trimpath` and verify bit-for-bit reproducibility.
   - Two independent CI runs from the same commit must produce identical
     binaries (same SHA-256).

### Deliverables

| Deliverable | Details |
|-------------|---------|
| `specs/` | TLA+ or Alloy specifications for circuit breaker, replication |
| `test/property/` | Property-based test suite |
| `Makefile` | Deterministic build targets with hash verification |
| CI step | Reproducibility check (build twice, compare hashes) |

---

## Milestone 22: Digital Twin & Continuous Validation (`milestone-22-digital-twin`)

### The Concept

A digital twin is a **production-identical environment** that receives a copy of
real production traffic (replayed or shadowed) and is continuously validated
against the same SLOs. It serves three purposes:

1. **Pre-production validation:** Deploy every change to the twin first. If the
   twin's SLOs degrade, block the production rollout.
2. **Disaster recovery confidence:** The twin *is* the DR environment. It's
   always warm, always tested, always ready.
3. **What-if simulation:** Test infrastructure changes (node count, DB tier,
   kernel parameters) against real traffic patterns without risking production.

### What to Implement

1. **Traffic mirroring:**
   - Configure Envoy or the GLB to mirror (not split) a copy of all production
     traffic to the twin environment.
   - The twin processes requests but its responses are discarded (shadow mode).

2. **Twin infrastructure:**
   - Deploy a complete parallel stack using the same Terraform modules.
   - Same region, same config, same image — but a separate GCP project.

3. **Continuous SLO comparison:**
   - A dashboard showing production SLOs and twin SLOs side by side.
   - Alert if twin SLOs diverge from production by > 5% (indicates the twin
     is drifting from reality).

4. **Pre-deployment gate:**
   - Before any production deployment, the change is deployed to the twin.
   - The twin must maintain SLOs for a configurable bake time (e.g., 30 min).
   - Only then is production deployment allowed (automated gate in CI/CD).

5. **Failover promotion:**
   - In a real emergency, the twin can be promoted to production by updating
     DNS. It's already warm and handling traffic shadows.

### Deliverables

| Deliverable | Details |
|-------------|---------|
| `terraform/twin/` | Twin environment Terraform config |
| Traffic mirroring | Envoy or GLB mirror config |
| CI gate | Pre-deployment twin validation step |
| Dashboard | Side-by-side SLO comparison widget |

---

## The Reliability Ladder

| Level | Milestone | Availability | What Fails You |
|-------|-----------|-------------|----------------|
| **1** | Regional HA (M3) | ~99.9% | Zone failure |
| **2** | Multi-Region (M13) | ~99.99% | Region failure |
| **3** | Multi-Cloud (M17) | ~99.999% | Cloud provider failure |
| **4** | N-Version (M18) | ~99.9999% | Software bugs in your code |
| **5** | Self-Healing (M19) | +MTTR→0 | Human response time |
| **6** | Cell Architecture (M20) | +blast radius→1/N | Correlated failures |
| **7** | Formal Verification (M21) | +provable | Incorrect assumptions |
| **8** | Digital Twin (M22) | +pre-validated | Untested deployments |

> At Level 8, you've eliminated: hardware failure, software bugs, human error,
> blast radius, provider lock-in, untested changes, and slow recovery. The
> remaining risks are acts of God, fundamental physics, and budget approval.

---

## Cost & Complexity Reality Check

| Milestone | Est. Cost Multiplier | Team Size | Calendar Time |
|-----------|---------------------|-----------|---------------|
| M17 Multi-Cloud | 3x base (~$51/day) | 2–3 engineers | 3–6 months |
| M18 N-Version | 1.5x (extra compute) | 3–4 engineers | 6–12 months |
| M19 Self-Healing | 1.1x (operator overhead) | 2 engineers | 3–6 months |
| M20 Cell Architecture | Nx cells | 3–5 engineers | 6–12 months |
| M21 Formal Verification | ~0 (tooling only) | 1–2 specialists | 3–6 months |
| M22 Digital Twin | 2x (full mirror) | 2–3 engineers | 3–6 months |

These milestones are not for every system. They're for systems where downtime
has catastrophic consequences — financial, safety, or reputational. For a todo
app, they're educational. For a payment processor, medical device backend, or
autonomous vehicle control plane, they're table stakes.
