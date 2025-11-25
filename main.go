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
)

type Todo struct {
	ID        int    `json:"id"`
	Task      string `json:"task"`
	Completed bool   `json:"completed"`
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

	initDB() // Call the new initDB function
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

func initDB() {
	var err error

	// Use Cloud SQL IAM authentication
	// The username is the service account email
	dbUser := "todo-app-sa@smcghee-todo-p15n-38a6.iam"
	dbName := os.Getenv("DB_NAME")
	dbHost := os.Getenv("DB_HOST")
	dbPort := os.Getenv("DB_PORT")

	// For IAM authentication, no password is needed
	// The Cloud SQL Proxy handles authentication via Workload Identity
	connStr := fmt.Sprintf("postgres://%s@%s:%s/%s?sslmode=disable", dbUser, dbHost, dbPort, dbName)

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
