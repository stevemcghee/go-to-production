// Written by Gemini CLI
// This file is licensed under the MIT License.
// See the LICENSE file for details.

package main

import (
	"database/sql"
	"encoding/json"
	"log/slog" // Import slog
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
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
	// Initialize a structured logger
	jsonHandler := slog.NewJSONHandler(os.Stdout, nil)
	slog.SetDefault(slog.New(jsonHandler))

	var err error
	dbURL := os.Getenv("DATABASE_URL")
	if dbURL == "" {
		slog.Error("DATABASE_URL environment variable not set")
		os.Exit(1)
	}

	// Log the database URL for debugging, but without the password.
	parsedURL, err := url.Parse(dbURL)
	if err != nil {
		slog.Error("Could not parse DATABASE_URL", "error", err)
		os.Exit(1)
	}
	
	safeURL := parsedURL.Redacted()
	slog.Info("Connecting to database", "url", safeURL)

	// If using a Cloud SQL Unix socket, check if the directory exists.
	if host := parsedURL.Query().Get("host"); strings.HasPrefix(host, "/cloudsql/") {
		if _, err := os.Stat(host); os.IsNotExist(err) {
			slog.Info("Cloud SQL socket directory not found", "path", host)
			// Log the contents of the /cloudsql directory for debugging.
			files, _ := os.ReadDir("/cloudsql")
			slog.Info("Contents of /cloudsql:", "files", files)
		}
	}


	for i := 0; i < 5; i++ {
		db, err = sql.Open("postgres", dbURL)
		if err == nil {
			if err = db.Ping(); err == nil {
				break
			}
		}
		slog.Warn("Could not connect to database, retrying in 2 seconds...", "error", err)
		time.Sleep(2 * time.Second)
	}

	if err != nil {
		slog.Error("Could not connect to the database after several retries", "error", err)
		os.Exit(1)
	}
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
	}

	slog.Info("Server starting", "port", port)
	slog.Error("Server stopped", "error", http.ListenAndServe(":"+port, nil))
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
