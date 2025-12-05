// Written by Gemini CLI
// This file is licensed under the MIT License.
// See the LICENSE file for details.

package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"

	secretmanager "cloud.google.com/go/secretmanager/apiv1"
	"cloud.google.com/go/secretmanager/apiv1/secretmanagerpb"
	"github.com/cenkalti/backoff/v4"
	_ "github.com/lib/pq"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	"github.com/sony/gobreaker"

	texporter "github.com/GoogleCloudPlatform/opentelemetry-operations-go/exporter/trace"
	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	semconv "go.opentelemetry.io/otel/semconv/v1.17.0"
)

var (
	httpRequestsTotal = promauto.NewCounterVec(
		prometheus.CounterOpts{
			Name: "http_requests_total",
			Help: "Total number of HTTP requests",
		},
		[]string{"path", "method", "code"},
	)
	httpRequestDuration = promauto.NewHistogramVec(
		prometheus.HistogramOpts{
			Name:    "http_request_duration_seconds",
			Help:    "Duration of HTTP requests in seconds",
			Buckets: prometheus.DefBuckets,
		},
		[]string{"path", "method"},
	)

	// Business metrics for tracking todo operations
	todosAdded = promauto.NewCounter(
		prometheus.CounterOpts{
			Name: "todos_added_total",
			Help: "Total number of todos added",
		},
	)
	todosUpdated = promauto.NewCounter(
		prometheus.CounterOpts{
			Name: "todos_updated_total",
			Help: "Total number of todos updated",
		},
	)
	todosDeleted = promauto.NewCounter(
		prometheus.CounterOpts{
			Name: "todos_deleted_total",
			Help: "Total number of todos deleted",
		},
	)
)

// Todo represents a single todo item.
type Todo struct {
	ID        int    `json:"id"`
	Task      string `json:"task"`
	Completed bool   `json:"completed"`
}

// DBConfig holds database connection parameters.
// For robustness, we support separate read and write endpoints:
// - DBHost/DBPort: Primary database (handles writes and reads)
// - DBReadHost/DBReadPort: Read replica (handles reads only)
// If read replica is unavailable, reads fall back to primary.
type DBConfig struct {
	DBUser     string `json:"db_user"`      // Database username (IAM service account)
	DBName     string `json:"db_name"`      // Database name
	DBHost     string `json:"db_host"`      // Primary database host (via Cloud SQL Proxy: 127.0.0.1)
	DBPort     string `json:"db_port"`      // Primary database port (5432)
	DBReadHost string `json:"db_read_host"` // Read replica host (via Cloud SQL Proxy: 127.0.0.1)
	DBReadPort string `json:"db_read_port"` // Read replica port (5433)
}

// Database connection pools:
// - db: Primary connection for writes (INSERT, UPDATE, DELETE) and failover reads
// - dbRead: Read replica connection for SELECT queries (improves performance and availability)
var (
	db     *sql.DB // Primary database connection
	dbRead *sql.DB // Read replica connection (or falls back to primary if replica unavailable)
)

// Circuit Breaker provides fault tolerance by preventing requests to a failing service.
// This protects the application from cascading failures when the database is consistently unavailable.
//
// States:
// - Closed (normal): All requests pass through
// - Open (failing): Requests fail immediately with ErrOpenState (returns HTTP 503)
// - Half-Open (testing): After timeout, allows limited requests to test recovery
var cb *gobreaker.CircuitBreaker

func init() {
	// Configure the circuit breaker for database operations
	var st gobreaker.Settings
	st.Name = "DatabaseCB"
	st.MaxRequests = 1            // Requests allowed in half-open state to test recovery
	st.Interval = 0               // Cyclic period of closed state (0 = never clear counts)
	st.Timeout = 30 * time.Second // Duration circuit stays open before attempting recovery

	// ReadyToTrip determines when to open the circuit (stop accepting requests)
	// Opens when: at least 3 requests AND 60% failure rate
	st.ReadyToTrip = func(counts gobreaker.Counts) bool {
		failureRatio := float64(counts.TotalFailures) / float64(counts.Requests)
		return counts.Requests >= 3 && failureRatio >= 0.6
	}

	// Log circuit breaker state changes for observability
	st.OnStateChange = func(name string, from gobreaker.State, to gobreaker.State) {
		slog.Warn("Circuit Breaker state changed", "name", name, "from", from, "to", to)
	}

	cb = gobreaker.NewCircuitBreaker(st)
}

// executeWithRobustness wraps database operations with both retry logic and circuit breaking.
// This provides multi-layer robustness:
// 1. Circuit Breaker: Fails fast if database is consistently down (prevents cascading failures)
// 2. Exponential Backoff: Retries transient errors with increasing delays
//
// Returns:
// - nil on success
// - gobreaker.ErrOpenState if circuit is open (HTTP handlers should return 503)
// - underlying error if retries exhausted
func executeWithRobustness(op func() error) error {
	_, err := cb.Execute(func() (interface{}, error) {
		return nil, retryOperation(op)
	})
	return err
}

// retryOperation implements exponential backoff retry logic for database operations.
// This handles transient failures like:
// - Network blips
// - Connection pool exhaustion
// - Temporary database load spikes
//
// Configuration:
// - Starts at 100ms delay
// - Doubles delay up to 2s max
// - Gives up after 5s total (fail fast for user experience)
func retryOperation(op func() error) error {
	b := backoff.NewExponentialBackOff()
	b.InitialInterval = 100 * time.Millisecond // First retry after 100ms
	b.MaxInterval = 2 * time.Second            // Cap retry delay at 2s
	b.MaxElapsedTime = 5 * time.Second         // Fail fast for user requests

	// RetryNotify executes the operation with retries and logs each attempt
	return backoff.RetryNotify(op, b, func(err error, d time.Duration) {
		slog.Warn("Database operation failed, retrying...", "error", err, "duration", d)
	})
}

// initTracer initializes Cloud Trace exporter and returns a shutdown function
func initTracer(projectID string) (func(), error) {
	ctx := context.Background()

	exporter, err := texporter.New(texporter.WithProjectID(projectID))
	if err != nil {
		return nil, fmt.Errorf("failed to create trace exporter: %w", err)
	}

	res, err := resource.New(ctx,
		resource.WithAttributes(
			semconv.ServiceNameKey.String("todo-app-go"),
			semconv.ServiceVersionKey.String("1.0.0"),
		),
	)
	if err != nil {
		return nil, fmt.Errorf("failed to create resource: %w", err)
	}

	tp := sdktrace.NewTracerProvider(
		sdktrace.WithBatcher(exporter),
		sdktrace.WithResource(res),
		sdktrace.WithSampler(sdktrace.AlwaysSample()),
	)
	otel.SetTracerProvider(tp)

	return func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if err := tp.Shutdown(ctx); err != nil {
			slog.Error("Failed to shutdown tracer provider", "error", err)
		}
	}, nil
}

func main() {
	fmt.Println("Raw stdout: Application starting...")

	jsonHandler := slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelDebug})
	slog.SetDefault(slog.New(jsonHandler))

	if _, err := os.Stat("templates/index.html"); os.IsNotExist(err) {
		slog.Error("templates/index.html not found!")
	} else {
		slog.Info("templates/index.html found")
	}

	defer func() {
		if r := recover(); r != nil {
			slog.Error("Application panicked", "panic", r)
			os.Exit(1)
		}
	}()

	slog.Info("Logger initialized")

	projectID := os.Getenv("GOOGLE_CLOUD_PROJECT")
	if projectID == "" {
		projectID = "smcghee-todo-p15n-38a6"
	}

	// Initialize Cloud Trace
	shutdown, err := initTracer(projectID)
	if err != nil {
		slog.Warn("Failed to initialize Cloud Trace", "error", err)
	} else {
		slog.Info("Cloud Trace initialized")
		defer shutdown()
	}

	secretName := fmt.Sprintf("projects/%s/secrets/todo-app-secret/versions/latest", projectID)

	secretValue, err := accessSecretVersion(secretName)
	if err != nil {
		slog.Error("Failed to fetch secret from Secret Manager", "error", err)
		os.Exit(1)
	} else {
		slog.Info("Successfully fetched secret from Secret Manager")
	}

	var dbConfig DBConfig
	if err := json.Unmarshal([]byte(secretValue), &dbConfig); err != nil {
		slog.Error("Failed to parse secret JSON", "error", err)
		os.Exit(1)
	}

	initDB(dbConfig)
	defer db.Close()
	if dbRead != db {
		defer dbRead.Close()
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/", serveIndex)
	mux.HandleFunc("/todos", handleTodos)
	mux.HandleFunc("/todos/", handleTodo)
	mux.HandleFunc("/healthz", healthzHandler)
	mux.Handle("/metrics", promhttp.Handler())

	fs := http.FileServer(http.Dir("./static"))
	mux.Handle("/static/", http.StripPrefix("/static/", fs))

	mux.HandleFunc("/favicon.ico", func(w http.ResponseWriter, r *http.Request) {
		http.ServeFile(w, r, "static/favicon.ico")
	})

	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
		slog.Info("PORT environment variable not set, defaulting to 8080")
	} else {
		slog.Info("PORT environment variable set", "port", port)
	}

	slog.Info("Server starting", "port", port)

	// Wrap handler with tracing and security middleware
	handler := otelhttp.NewHandler(
		securityHeadersMiddleware(mux),
		"todo-app-go",
	)

	server := &http.Server{
		Addr:         ":" + port,
		Handler:      handler,
		ReadTimeout:  60 * time.Second,
		WriteTimeout: 60 * time.Second,
		IdleTimeout:  120 * time.Second,
	}

	if err := server.ListenAndServe(); err != nil {
		slog.Error("Server stopped unexpectedly", "error", err)
		os.Exit(1)
	}
}

func securityHeadersMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// More permissive CSP that allows fonts and necessary resources
		w.Header().Set("Content-Security-Policy", "default-src 'self'; font-src 'self' data: https:; style-src 'self' 'unsafe-inline' https:; script-src 'self'; img-src 'self' data: https:")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("X-Frame-Options", "DENY")
		w.Header().Set("X-XSS-Protection", "1; mode=block")

		start := time.Now()
		rw := newResponseWriter(w)
		next.ServeHTTP(rw, r)
		duration := time.Since(start).Seconds()

		path := r.URL.Path
		if strings.HasPrefix(path, "/todos/") && len(path) > 7 {
			path = "/todos/:id"
		}

		httpRequestsTotal.WithLabelValues(path, r.Method, strconv.Itoa(rw.statusCode)).Inc()
		httpRequestDuration.WithLabelValues(path, r.Method).Observe(duration)
	})
}

type responseWriter struct {
	http.ResponseWriter
	statusCode int
}

func newResponseWriter(w http.ResponseWriter) *responseWriter {
	return &responseWriter{w, http.StatusOK}
}

func (rw *responseWriter) WriteHeader(code int) {
	rw.statusCode = code
	rw.ResponseWriter.WriteHeader(code)
}

// initDB establishes connections to both primary and read replica databases.
// This dual-connection architecture provides:
// - Write scaling: All writes go to primary
// - Read scaling: Reads distributed to replica, reducing primary load
// - Availability: Reads fall back to primary if replica fails
//
// Connection uses Cloud SQL Proxy which handles:
// - IAM authentication (no passwords needed)
// - TLS encryption
// - Connection pooling
func initDB(config DBConfig) {
	var err error

	dbUser := config.DBUser
	dbName := config.DBName
	dbHost := config.DBHost
	dbPort := config.DBPort

	// ===== PRIMARY DATABASE CONNECTION =====
	// The primary database handles all writes and serves as fallback for reads
	connStr := fmt.Sprintf("postgres://%s:dummy-password@%s:%s/%s?sslmode=disable", dbUser, dbHost, dbPort, dbName)
	slog.Info("Connecting to PRIMARY database", "url", connStr)

	// Use longer retry timeout for initial connection (allows Cloud SQL Proxy to start)
	b := backoff.NewExponentialBackOff()
	b.MaxElapsedTime = 2 * time.Minute

	op := func() error {
		db, err = sql.Open("postgres", connStr)
		if err != nil {
			return err
		}
		return db.Ping()
	}

	err = backoff.RetryNotify(op, b, func(err error, d time.Duration) {
		slog.Warn("Could not connect to PRIMARY database, retrying...", "error", err, "duration", d)
	})

	if err != nil {
		slog.Error("Could not connect to the PRIMARY database", "error", err)
		os.Exit(1)
	}
	slog.Info("Successfully connected to PRIMARY database")

	// ===== READ REPLICA CONNECTION (OPTIONAL) =====
	// Read replica improves performance by offloading SELECT queries from primary.
	// If connection fails, we gracefully fall back to primary for all operations.
	if config.DBReadHost != "" {
		dbReadHost := config.DBReadHost
		dbReadPort := config.DBReadPort
		if dbReadPort == "" {
			dbReadPort = dbPort
		}

		readConnStr := fmt.Sprintf("postgres://%s:dummy-password@%s:%s/%s?sslmode=disable", dbUser, dbReadHost, dbReadPort, dbName)
		slog.Info("Connecting to READ REPLICA", "url", readConnStr)

		opRead := func() error {
			dbRead, err = sql.Open("postgres", readConnStr)
			if err != nil {
				return err
			}
			return dbRead.Ping()
		}

		// We can be more lenient with Read Replica connection failure
		// since we can fall back to primary
		err = backoff.RetryNotify(opRead, b, func(err error, d time.Duration) {
			slog.Warn("Could not connect to READ REPLICA, retrying...", "error", err, "duration", d)
		})

		if err != nil {
			// Read replica unavailable - not fatal, fall back to primary
			slog.Error("Could not connect to READ REPLICA, falling back to PRIMARY", "error", err)
			dbRead = db // Fallback to primary for reads
		} else {
			slog.Info("Successfully connected to READ REPLICA")
		}
	} else {
		// No read replica configured in secrets
		slog.Info("No Read Replica configured, using PRIMARY for reads")
		dbRead = db
	}
}

func healthzHandler(w http.ResponseWriter, r *http.Request) {
	if db == nil {
		http.Error(w, "Database connection not initialized", http.StatusInternalServerError)
		return
	}
	if err := db.Ping(); err != nil {
		http.Error(w, "Database connection failed: "+err.Error(), http.StatusInternalServerError)
		return
	}
	// Check Read Replica too if distinct
	if dbRead != db && dbRead != nil {
		if err := dbRead.Ping(); err != nil {
			slog.Warn("Read Replica ping failed", "error", err)
			// Don't fail health check if only read replica is down?
			// Or maybe we should? For now, let's just log it.
		}
	}
	w.WriteHeader(http.StatusOK)
	if _, err := w.Write([]byte("OK")); err != nil {
		slog.Error("Failed to write health check response", "error", err)
	}
}

func serveIndex(w http.ResponseWriter, r *http.Request) {
	slog.Info("Serving index.html", "path", r.URL.Path)
	http.ServeFile(w, r, "templates/index.html")
}

func handleTodos(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		getTodos(w, r)
	case http.MethodPost:
		addTodo(w, r)
	default:
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
	}
}

func handleTodo(w http.ResponseWriter, r *http.Request) {
	id, err := strconv.Atoi(r.URL.Path[len("/todos/"):])
	if err != nil {
		http.Error(w, "Invalid todo ID", http.StatusBadRequest)
		return
	}

	switch r.Method {
	case http.MethodPut:
		updateTodo(w, r, id)
	case http.MethodDelete:
		deleteTodo(w, r, id)
	default:
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
	}
}

// getTodos retrieves all todo items from the database.
// Uses dbRead (read replica) to offload SELECT queries from the primary database.
// This improves performance and allows the primary to focus on writes.
//
// Robustness features:
// - Automatic retries on transient errors (network blips, etc.)
// - Circuit breaker prevents cascading failures
// - Falls back to primary if read replica is unavailable
func getTodos(w http.ResponseWriter, r *http.Request) {
	var todos []Todo

	err := executeWithRobustness(func() error {
		// Use dbRead (read replica) for all SELECT queries
		// This distributes read load and improves overall performance
		rows, err := dbRead.Query("SELECT id, task, completed FROM todos ORDER BY id")
		if err != nil {
			return err
		}
		defer rows.Close()

		todos = []Todo{} // Reset slice on retry to avoid duplicates
		for rows.Next() {
			var t Todo
			if err := rows.Scan(&t.ID, &t.Task, &t.Completed); err != nil {
				return err
			}
			todos = append(todos, t)
		}
		return rows.Err()
	})

	if err != nil {
		if err == gobreaker.ErrOpenState {
			// Circuit breaker is open - database is consistently failing
			http.Error(w, "Service Unavailable (Circuit Breaker Open)", http.StatusServiceUnavailable)
		} else {
			http.Error(w, err.Error(), http.StatusInternalServerError)
		}
		return
	}

	w.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(w).Encode(todos); err != nil {
		slog.Error("Failed to encode todos", "error", err)
	}
}

func addTodo(w http.ResponseWriter, r *http.Request) {
	slog.Info("addTodo called", "method", r.Method, "path", r.URL.Path)

	var t Todo
	if err := json.NewDecoder(r.Body).Decode(&t); err != nil {
		slog.Error("Failed to decode request body", "error", err)
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	slog.Info("Decoded todo", "task", t.Task)

	err := executeWithRobustness(func() error {
		return db.QueryRow("INSERT INTO todos (task) VALUES ($1) RETURNING id, completed", t.Task).Scan(&t.ID, &t.Completed)
	})

	if err != nil {
		slog.Error("Failed to insert todo", "error", err, "task", t.Task)
		if err == gobreaker.ErrOpenState {
			http.Error(w, "Service Unavailable (Circuit Breaker Open)", http.StatusServiceUnavailable)
		} else {
			http.Error(w, err.Error(), http.StatusInternalServerError)
		}
		return
	}

	slog.Info("Successfully added todo", "id", t.ID, "task", t.Task)
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusCreated)
	if err := json.NewEncoder(w).Encode(t); err != nil {
		slog.Error("Failed to encode todo", "error", err)
	}
	todosAdded.Inc()
}

func updateTodo(w http.ResponseWriter, r *http.Request, id int) {
	var t Todo
	if err := json.NewDecoder(r.Body).Decode(&t); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	err := executeWithRobustness(func() error {
		_, err := db.Exec("UPDATE todos SET completed = $1 WHERE id = $2", t.Completed, id)
		return err
	})

	if err != nil {
		if err == gobreaker.ErrOpenState {
			http.Error(w, "Service Unavailable (Circuit Breaker Open)", http.StatusServiceUnavailable)
		} else {
			http.Error(w, err.Error(), http.StatusInternalServerError)
		}
		return
	}

	w.WriteHeader(http.StatusOK)
	todosUpdated.Inc()
}

func deleteTodo(w http.ResponseWriter, r *http.Request, id int) {
	err := executeWithRobustness(func() error {
		_, err := db.Exec("DELETE FROM todos WHERE id = $1", id)
		return err
	})

	if err != nil {
		if err == gobreaker.ErrOpenState {
			http.Error(w, "Service Unavailable (Circuit Breaker Open)", http.StatusServiceUnavailable)
		} else {
			http.Error(w, err.Error(), http.StatusInternalServerError)
		}
		return
	}

	w.WriteHeader(http.StatusNoContent)
	todosDeleted.Inc()
}

func accessSecretVersion(name string) (string, error) {
	ctx := context.Background()
	client, err := secretmanager.NewClient(ctx)
	if err != nil {
		return "", fmt.Errorf("failed to create secretmanager client: %w", err)
	}
	defer client.Close()

	req := &secretmanagerpb.AccessSecretVersionRequest{
		Name: name,
	}

	result, err := client.AccessSecretVersion(ctx, req)
	if err != nil {
		return "", fmt.Errorf("failed to access secret version: %w", err)
	}

	return string(result.Payload.Data), nil
}
