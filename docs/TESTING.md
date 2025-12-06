## Testing Strategy

### Overview
A comprehensive testing strategy is critical for maintaining reliability and catching issues before they reach production. Our testing approach includes three layers:

#### 1. Unit Tests (Implemented)
**Purpose**: Fast feedback on individual components and business logic. These tests are located in `main_test.go` and cover the `internal/app` package functions.

**Coverage**:
*   HTTP handlers' internal logic (e.g., parsing requests, constructing responses *before* database interaction).
*   Circuit breaker logic and state transitions (mocked interactions).
*   Retry mechanisms with exponential backoff (mocked operations).
*   Response writer wrapper and metrics recording logic.
*   Security headers middleware application logic.
*   JSON encoding/decoding edge cases for `Todo` objects.
*   Utility functions within the `internal/app` package.

**Benefits**:
*   Fast execution (milliseconds).
*   No external dependencies (mocks are used).
*   Runs in CI on every commit.
*   Documents expected behavior.
*   Catches regressions immediately.

#### 2. Integration/Smoke Tests (Implemented)
**Purpose**: Validate end-to-end functionality with real dependencies. These tests are located in `integration_test.go`.

**Coverage**:
*   Full CRUD (Create, Read, Update, Delete) workflow for todo items against a *real test database*.
*   Database connectivity with Cloud SQL IAM authentication (simulated via local setup).
*   Secret Manager access and JSON parsing (simulated with test secrets).
*   Complete HTTP request/response cycles for todo endpoints.
*   Health check endpoints (`/healthz`) functionality.
*   Metrics exposure endpoint (`/metrics`) availability.
*   Read replica fallback logic (simulated in a test environment).
*   Cloud Trace integration (basic verification).

**Benefits**:
*   Validates actual GCP integrations (simulated/local).
*   Can run in CI with a test database (docker-compose).
*   Catches configuration issues before production.
*   Verifies infrastructure-as-code changes.

#### 3. Chaos/Resilience Tests (Implemented)
**Purpose**: Validate robustness features under failure conditions. These tests are located in `test/chaos/chaos_test.go`.

**Coverage**:
*   Database connection failures and recovery scenarios.
*   Circuit breaker opening/closing behavior under sustained errors.
*   Retry exhaustion scenarios for transient database issues.
*   Network timeouts and transient errors simulation for database interactions.
*   Concurrent request handling under database stress.

**Benefits**:
*   Validates circuit breakers and retry logic actually work as intended.
*   Builds confidence in production resilience.
*   Aligns with SRE best practices.
*   Prevents "works in theory" scenarios.

### Test Execution

**Local Development**:
```bash
# Run all tests (unit, integration, chaos)
go test -v ./...

# Run unit tests only
go test -v ./main_test.go

# Run integration tests only
go test -v ./integration_test.go

# Run chaos tests
go test -v ./test/chaos/...
```

**CI/CD Integration**:
*   Unit and Integration tests run on every push (configured in `.github/workflows/build-test.yml`).
*   Chaos tests run on-demand or weekly schedule.
*   Coverage reports uploaded to code review.

### Success Metrics
*   **Target Code Coverage**: 80%+ for critical paths
*   **Test Execution Time**: <30s for unit tests, <2m for integration tests
*   **Flakiness**: <1% test failure rate unrelated to actual bugs
