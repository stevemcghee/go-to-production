// Written by Gemini CLI
// This file is licensed under the MIT License.
// See the LICENSE file for details.

package main

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"log/slog" // Import slog
	"net/http"
	"os"
	"strconv"
	"time"

	_ "github.com/lib/pq"
	"github.com/prometheus/client_golang/prometheus/promhttp"

	"context"

	secretmanager "cloud.google.com/go/secretmanager/apiv1"
	"cloud.google.com/go/secretmanager/apiv1/secretmanagerpb"
)

type Todo struct {
	ID        int    `json:"id"`
	Task      string `json:"task"`
	Completed bool   `json:"completed"`
}

type DBConfig struct {
	DBUser string `json:"db_user"`
	DBName string `json:"db_name"`
	DBHost string `json:"db_host"`
	DBPort string `json:"db_port"`
}

var db *sql.DB

func main() {
	// Immediate raw output to verify stdout is working
	fmt.Println("Raw stdout: Application starting...")

	// Initialize a structured logger
	jsonHandler := slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelDebug})
	slog.SetDefault(slog.New(jsonHandler))

	// Verify template existence
	if _, err := os.Stat("templates/index.html"); os.IsNotExist(err) {
		slog.Error("templates/index.html not found!")
	} else {
		slog.Info("templates/index.html found")
	}

	// Panic recovery
	defer func() {
		if r := recover(); r != nil {
			slog.Error("Application panicked", "panic", r)
			os.Exit(1)
		}
	}()

	slog.Info("Logger initialized")

	// Fetch secret from Secret Manager
	projectID := os.Getenv("GOOGLE_CLOUD_PROJECT")
	if projectID == "" {
		projectID = "smcghee-todo-p15n-38a6" // Fallback for local dev/demo
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

	initDB(dbConfig) // Call the new initDB function
	defer db.Close()

	http.HandleFunc("/", serveIndex)
	http.HandleFunc("/todos", handleTodos)
	http.HandleFunc("/todos/", handleTodo)
	http.HandleFunc("/healthz", healthzHandler)
	http.Handle("/metrics", promhttp.Handler())

	fs := http.FileServer(http.Dir("./static"))
	http.Handle("/static/", http.StripPrefix("/static/", fs))

	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
		slog.Info("PORT environment variable not set, defaulting to 8080")
	} else {
		slog.Info("PORT environment variable set", "port", port)
	}

	slog.Info("Server starting", "port", port)
	if err := http.ListenAndServe(":"+port, nil); err != nil {
		slog.Error("Server stopped unexpectedly", "error", err)
		os.Exit(1)
	}
}

func initDB(config DBConfig) {
	var err error

	// Use Cloud SQL IAM authentication
	// The username is the service account email without the .gserviceaccount.com suffix
	// This must match the user created in Cloud SQL
	dbUser := config.DBUser
	// Optional: Allow override for local dev if needed, or just stick to secret
	// For now, we rely on the secret.

	dbName := config.DBName
	dbHost := config.DBHost
	dbPort := config.DBPort

	// For IAM authentication, a password is required by the driver but ignored by the proxy
	// The Cloud SQL Proxy handles authentication via Workload Identity
	connStr := fmt.Sprintf("postgres://%s:dummy-password@%s:%s/%s?sslmode=disable", dbUser, dbHost, dbPort, dbName)

	// Log the connection string (safe since no password)
	slog.Info("Connecting to database with IAM auth", "url", connStr)

	slog.Info("Attempting to connect to database", "attempts", 5)
	for i := 0; i < 5; i++ {
		slog.Info("Opening database connection", "attempt", i+1)
		db, err = sql.Open("postgres", connStr)
		if err == nil {
			slog.Info("Pinging database", "attempt", i+1)
			if err = db.Ping(); err == nil {
				slog.Info("Successfully connected to database")
				break
			}
		}
		slog.Warn("Could not connect to database, retrying in 2 seconds...", "error", err, "attempt", i+1)
		time.Sleep(2 * time.Second)
	}

	if err != nil {
		slog.Error("Could not connect to the database after several retries", "error", err)
		os.Exit(1)
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
	w.WriteHeader(http.StatusOK)
	w.Write([]byte("OK"))
}

func serveIndex(w http.ResponseWriter, r *http.Request) {
	slog.Info("Serving index.html", "path", r.URL.Path)
	w.Header().Set("Content-Security-Policy", "default-src 'self'; style-src 'self' 'unsafe-inline'; script-src 'self'")
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

func getTodos(w http.ResponseWriter, r *http.Request) {
	rows, err := db.Query("SELECT id, task, completed FROM todos ORDER BY id")
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	defer rows.Close()

	todos := []Todo{}
	for rows.Next() {
		var t Todo
		if err := rows.Scan(&t.ID, &t.Task, &t.Completed); err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		todos = append(todos, t)
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(todos)
}

func addTodo(w http.ResponseWriter, r *http.Request) {
	var t Todo
	if err := json.NewDecoder(r.Body).Decode(&t); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	err := db.QueryRow("INSERT INTO todos (task) VALUES ($1) RETURNING id, completed", t.Task).Scan(&t.ID, &t.Completed)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusCreated)
	json.NewEncoder(w).Encode(t)
}

func updateTodo(w http.ResponseWriter, r *http.Request, id int) {
	var t Todo
	if err := json.NewDecoder(r.Body).Decode(&t); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	_, err := db.Exec("UPDATE todos SET completed = $1 WHERE id = $2", t.Completed, id)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	w.WriteHeader(http.StatusOK)
}

func deleteTodo(w http.ResponseWriter, r *http.Request, id int) {
	_, err := db.Exec("DELETE FROM todos WHERE id = $1", id)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	w.WriteHeader(http.StatusNoContent)
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
