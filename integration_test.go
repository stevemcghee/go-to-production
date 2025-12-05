// Written by Gemini CLI
// This file is licensed under the MIT License.
// See the LICENSE file for details.

//go:build integration
// +build integration

package main

import (
	"bytes"
	"database/sql"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"
	"time"

	"github.com/stevemcghee/go-to-production/internal/app"
	_ "github.com/lib/pq"
)

var testDB *sql.DB

// TestMain sets up and tears down the test database
func TestMain(m *testing.M) {
	// Setup test database connection
	dbHost := os.Getenv("TEST_DB_HOST")
	if dbHost == "" {
		dbHost = "localhost"
	}

	dbPort := os.Getenv("TEST_DB_PORT")
	if dbPort == "" {
		dbPort = "5432"
	}

	dbUser := os.Getenv("TEST_DB_USER")
	if dbUser == "" {
		dbUser = "postgres"
	}

	dbPassword := os.Getenv("TEST_DB_PASSWORD")
	if dbPassword == "" {
		dbPassword = "postgres"
	}

	dbName := os.Getenv("TEST_DB_NAME")
	if dbName == "" {
		dbName = "postgres"
	}

	connStr := fmt.Sprintf("postgres://%s:%s@%s:%s/%s?sslmode=disable",
		dbUser, dbPassword, dbHost, dbPort, dbName)

	var err error
	testDB, err = sql.Open("postgres", connStr)
	if err != nil {
		fmt.Printf("Failed to connect to test database: %v\n", err)
		os.Exit(1)
	}

	// Wait for database to be ready
	for i := 0; i < 30; i++ {
		if err := testDB.Ping(); err == nil {
			break
		}
		time.Sleep(1 * time.Second)
	}

	if err := testDB.Ping(); err != nil {
		fmt.Printf("Test database not ready: %v\n", err)
		os.Exit(1)
	}

	// Create test table
	_, err = testDB.Exec(`
		CREATE TABLE IF NOT EXISTS todos (
			id SERIAL PRIMARY KEY,
			task TEXT NOT NULL,
			completed BOOLEAN DEFAULT FALSE
		)
	`)
	if err != nil {
		fmt.Printf("Failed to create test table: %v\n", err)
		os.Exit(1)
	}

	// Set global db variables for handlers
	app.DB = testDB
	app.DBRead = testDB

	// Run tests
	code := m.Run()

	// Cleanup
	testDB.Exec("DROP TABLE IF EXISTS todos")
	testDB.Close()

	os.Exit(code)
}

// cleanupTodos removes all todos from the test database
func cleanupTodos(t *testing.T) {
	_, err := testDB.Exec("DELETE FROM todos")
	if err != nil {
		t.Fatalf("failed to cleanup todos: %v", err)
	}
}

// TestIntegrationGetTodosEmpty tests getting todos when database is empty
func TestIntegrationGetTodosEmpty(t *testing.T) {
	cleanupTodos(t)

	req := httptest.NewRequest(http.MethodGet, "/todos", nil)
	w := httptest.NewRecorder()

	app.GetTodos(w, req)

	if w.Code != http.StatusOK {
		t.Errorf("expected status %d, got %d", http.StatusOK, w.Code)
	}

	var todos []app.Todo
	if err := json.NewDecoder(w.Body).Decode(&todos); err != nil {
		t.Fatalf("failed to decode response: %v", err)
	}

	if len(todos) != 0 {
		t.Errorf("expected 0 todos, got %d", len(todos))
	}
}

// TestIntegrationAddTodo tests adding a new todo
func TestIntegrationAddTodo(t *testing.T) {
	cleanupTodos(t)

	newTodo := app.Todo{
		Task: "Integration test todo",
	}

	body, _ := json.Marshal(newTodo)
	req := httptest.NewRequest(http.MethodPost, "/todos", bytes.NewBuffer(body))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()

	app.AddTodo(w, req)

	if w.Code != http.StatusCreated {
		t.Errorf("expected status %d, got %d", http.StatusCreated, w.Code)
	}

	var created app.Todo
	if err := json.NewDecoder(w.Body).Decode(&created); err != nil {
		t.Fatalf("failed to decode response: %v", err)
	}

	if created.ID == 0 {
		t.Error("expected non-zero ID")
	}

	if created.Task != newTodo.Task {
		t.Errorf("expected task %q, got %q", newTodo.Task, created.Task)
	}

	if created.Completed != false {
		t.Errorf("expected completed to be false, got %v", created.Completed)
	}
}

// TestIntegrationGetTodosWithData tests getting todos when database has data
func TestIntegrationGetTodosWithData(t *testing.T) {
	cleanupTodos(t)

	// Insert test data
	_, err := testDB.Exec("INSERT INTO todos (task, completed) VALUES ($1, $2)", "Test task 1", false)
	if err != nil {
		t.Fatalf("failed to insert test data: %v", err)
	}
	_, err = testDB.Exec("INSERT INTO todos (task, completed) VALUES ($1, $2)", "Test task 2", true)
	if err != nil {
		t.Fatalf("failed to insert test data: %v", err)
	}

	req := httptest.NewRequest(http.MethodGet, "/todos", nil)
	w := httptest.NewRecorder()

	app.GetTodos(w, req)

	if w.Code != http.StatusOK {
		t.Errorf("expected status %d, got %d", http.StatusOK, w.Code)
	}

	var todos []app.Todo
	if err := json.NewDecoder(w.Body).Decode(&todos); err != nil {
		t.Fatalf("failed to decode response: %v", err)
	}

	if len(todos) != 2 {
		t.Errorf("expected 2 todos, got %d", len(todos))
	}

	if todos[0].Task != "Test task 1" {
		t.Errorf("expected first task to be 'Test task 1', got %q", todos[0].Task)
	}

	if todos[1].Completed != true {
		t.Errorf("expected second todo to be completed")
	}
}

// TestIntegrationUpdateTodo tests updating a todo
func TestIntegrationUpdateTodo(t *testing.T) {
	cleanupTodos(t)

	// Insert test data
	var id int
	err := testDB.QueryRow("INSERT INTO todos (task, completed) VALUES ($1, $2) RETURNING id",
		"Test task", false).Scan(&id)
	if err != nil {
		t.Fatalf("failed to insert test data: %v", err)
	}

	// Update the todo
	update := app.Todo{Completed: true}
	body, _ := json.Marshal(update)
	req := httptest.NewRequest(http.MethodPut, fmt.Sprintf("/todos/%d", id), bytes.NewBuffer(body))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()

	app.UpdateTodo(w, req, id)

	if w.Code != http.StatusOK {
		t.Errorf("expected status %d, got %d", http.StatusOK, w.Code)
	}

	// Verify the update
	var completed bool
	err = testDB.QueryRow("SELECT completed FROM todos WHERE id = $1", id).Scan(&completed)
	if err != nil {
		t.Fatalf("failed to query updated todo: %v", err)
	}

	if !completed {
		t.Error("expected todo to be completed")
	}
}

// TestIntegrationDeleteTodo tests deleting a todo
func TestIntegrationDeleteTodo(t *testing.T) {
	cleanupTodos(t)

	// Insert test data
	var id int
	err := testDB.QueryRow("INSERT INTO todos (task, completed) VALUES ($1, $2) RETURNING id",
		"Test task", false).Scan(&id)
	if err != nil {
		t.Fatalf("failed to insert test data: %v", err)
	}

	// Delete the todo
	req := httptest.NewRequest(http.MethodDelete, fmt.Sprintf("/todos/%d", id), nil)
	w := httptest.NewRecorder()

	app.DeleteTodo(w, req, id)

	if w.Code != http.StatusNoContent {
		t.Errorf("expected status %d, got %d", http.StatusNoContent, w.Code)
	}

	// Verify the deletion
	var count int
	err = testDB.QueryRow("SELECT COUNT(*) FROM todos WHERE id = $1", id).Scan(&count)
	if err != nil {
		t.Fatalf("failed to query deleted todo: %v", err)
	}

	if count != 0 {
		t.Error("expected todo to be deleted")
	}
}

// TestIntegrationFullWorkflow tests a complete workflow
func TestIntegrationFullWorkflow(t *testing.T) {
	cleanupTodos(t)

	// 1. Start with empty list
	req := httptest.NewRequest(http.MethodGet, "/todos", nil)
	w := httptest.NewRecorder()
	app.GetTodos(w, req)

	var todos []app.Todo
	json.NewDecoder(w.Body).Decode(&todos)
	if len(todos) != 0 {
		t.Errorf("expected 0 todos initially, got %d", len(todos))
	}

	// 2. Add a todo
	newTodo := app.Todo{Task: "Buy groceries"}
	body, _ := json.Marshal(newTodo)
	req = httptest.NewRequest(http.MethodPost, "/todos", bytes.NewBuffer(body))
	req.Header.Set("Content-Type", "application/json")
	w = httptest.NewRecorder()
	app.AddTodo(w, req)

	var created app.Todo
	json.NewDecoder(w.Body).Decode(&created)
	todoID := created.ID

	// 3. Verify it appears in the list
	req = httptest.NewRequest(http.MethodGet, "/todos", nil)
	w = httptest.NewRecorder()
	app.GetTodos(w, req)

	json.NewDecoder(w.Body).Decode(&todos)
	if len(todos) != 1 {
		t.Errorf("expected 1 todo after adding, got %d", len(todos))
	}

	// 4. Mark it as completed
	update := app.Todo{Completed: true}
	body, _ = json.Marshal(update)
	req = httptest.NewRequest(http.MethodPut, fmt.Sprintf("/todos/%d", todoID), bytes.NewBuffer(body))
	req.Header.Set("Content-Type", "application/json")
	w = httptest.NewRecorder()
	app.UpdateTodo(w, req, todoID)

	// 5. Verify it's completed
	req = httptest.NewRequest(http.MethodGet, "/todos", nil)
	w = httptest.NewRecorder()
	app.GetTodos(w, req)

	json.NewDecoder(w.Body).Decode(&todos)
	if !todos[0].Completed {
		t.Error("expected todo to be completed")
	}

	// 6. Delete it
	req = httptest.NewRequest(http.MethodDelete, fmt.Sprintf("/todos/%d", todoID), nil)
	w = httptest.NewRecorder()
	app.DeleteTodo(w, req, todoID)

	// 7. Verify it's gone
	req = httptest.NewRequest(http.MethodGet, "/todos", nil)
	w = httptest.NewRecorder()
	app.GetTodos(w, req)

	json.NewDecoder(w.Body).Decode(&todos)
	if len(todos) != 0 {
		t.Errorf("expected 0 todos after deleting, got %d", len(todos))
	}
}

// TestIntegrationHealthCheck tests the health check with real database
func TestIntegrationHealthCheck(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	w := httptest.NewRecorder()

	app.HealthzHandler(w, req)

	if w.Code != http.StatusOK {
		t.Errorf("expected status %d, got %d", http.StatusOK, w.Code)
	}

	if w.Body.String() != "OK" {
		t.Errorf("expected body 'OK', got %q", w.Body.String())
	}
}
