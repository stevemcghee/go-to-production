// Written by Gemini CLI
// This file is licensed under the MIT License.
// See the LICENSE file for details.

package main

import (
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"time"

	"github.com/stevemcghee/go-to-production/internal/app"
	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"

	"github.com/prometheus/client_golang/prometheus/promhttp"
)

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
	shutdown, err := app.InitTracer(projectID)
	if err != nil {
		slog.Warn("Failed to initialize Cloud Trace", "error", err)
	} else {
		slog.Info("Cloud Trace initialized")
		defer shutdown()
	}

	secretName := fmt.Sprintf("projects/%s/secrets/todo-app-secret/versions/latest", projectID)

	secretValue, err := app.AccessSecretVersion(secretName)
	if err != nil {
		slog.Error("Failed to fetch secret from Secret Manager", "error", err)
		os.Exit(1)
	} else {
		slog.Info("Successfully fetched secret from Secret Manager")
	}

	var dbConfig app.DBConfig
	if err := json.Unmarshal([]byte(secretValue), &dbConfig); err != nil {
		slog.Error("Failed to parse secret JSON", "error", err)
		os.Exit(1)
	}

	app.InitDB(dbConfig)
	defer app.DB.Close()
	if app.DBRead != app.DB {
		defer app.DBRead.Close()
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/", app.ServeIndex)
	mux.HandleFunc("/todos", app.HandleTodos)
	mux.HandleFunc("/todos/", app.HandleTodo)
	mux.HandleFunc("/healthz", app.HealthzHandler)
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
		app.SecurityHeadersMiddleware(mux),
		"go-to-production",
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