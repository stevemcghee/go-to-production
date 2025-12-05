// Written by Gemini CLI
// This file is licensed under the MIT License.
// See the LICENSE file for details.

package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/stevemcghee/go-to-production/internal/app"
	"github.com/sony/gobreaker"
)

// TestHealthzHandler tests the health check endpoint
func TestHealthzHandler(t *testing.T) {
	tests := []struct {
		name string
		dbInitialized bool
		expectedStatus int
		expectedBody   string
	}{
		{
			name: "database not initialized",
			dbInitialized: false,
			expectedStatus: http.StatusInternalServerError,
			expectedBody:   "Database connection not initialized",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			// Save original db states
			originalDB := app.DB
			originalDBRead := app.DBRead

			if !tt.dbInitialized {
				app.DB = nil
				app.DBRead = nil
			} else {
				// For unit test, mock a healthy DB connection for other tests
				// but this specific test only covers the nil case for now.
				// app.DB = &sql.DB{} // We don't need this mock if we only test nil case
				// app.DBRead = &sql.DB{}
			}

			req := httptest.NewRequest(http.MethodGet, "/healthz", nil)
			w := httptest.NewRecorder()

			app.HealthzHandler(w, req)

			if w.Code != tt.expectedStatus {
				t.Errorf("expected status %d, got %d", tt.expectedStatus, w.Code)
			}

			if !bytes.Contains(w.Body.Bytes(), []byte(tt.expectedBody)) {
				t.Errorf("expected body to contain %q, got %q", tt.expectedBody, w.Body.String())
			}

			// Restore original state
			app.DB = originalDB
			app.DBRead = originalDBRead
		})
	}
}

// TestResponseWriter tests the custom response writer wrapper
func TestResponseWriter(t *testing.T) {
	tests := []struct {
		name               string
		writeHeader        bool
		statusCode         int
		expectedStatusCode int
	}{
		{
			name:               "default status code",
			writeHeader:        false,
			expectedStatusCode: http.StatusOK,
		},
		{
			name:               "custom status code",
			writeHeader:        true,
			statusCode:         http.StatusCreated,
			expectedStatusCode: http.StatusCreated,
		},
		{
			name:               "error status code",
			writeHeader:        true,
			statusCode:         http.StatusInternalServerError,
			expectedStatusCode: http.StatusInternalServerError,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			w := httptest.NewRecorder()
			rw := app.NewResponseWriter(w)

			if tt.writeHeader {
				rw.WriteHeader(tt.statusCode)
			}

			if rw.StatusCode != tt.expectedStatusCode {
				t.Errorf("expected status code %d, got %d", tt.expectedStatusCode, rw.StatusCode)
			}
		})
	}
}

// TestSecurityHeadersMiddleware tests that security headers are properly set
func TestSecurityHeadersMiddleware(t *testing.T) {
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("OK"))
	})

	wrappedHandler := app.SecurityHeadersMiddleware(handler)

	req := httptest.NewRequest(http.MethodGet, "/", nil)
	w := httptest.NewRecorder()

	wrappedHandler.ServeHTTP(w, req)

	// Check security headers
	headers := map[string]string{
		"Content-Security-Policy": "default-src 'self'; font-src 'self' data: https:; style-src 'self' 'unsafe-inline' https:; script-src 'self'; img-src 'self' data: https:",
		"X-Content-Type-Options":  "nosniff",
		"X-Frame-Options":         "DENY",
		"X-XSS-Protection":        "1; mode=block",
	}

	for header, expectedValue := range headers {
		actualValue := w.Header().Get(header)
		if actualValue != expectedValue {
			t.Errorf("expected header %s to be %q, got %q", header, expectedValue, actualValue)
		}
	}
}

// TestHandleTodosMethodNotAllowed tests that unsupported methods return 405
func TestHandleTodosMethodNotAllowed(t *testing.T) {
	methods := []string{http.MethodPut, http.MethodDelete, http.MethodPatch}

	for _, method := range methods {
		t.Run(method, func(t *testing.T) {
			req := httptest.NewRequest(method, "/todos", nil)
			w := httptest.NewRecorder()

			app.HandleTodos(w, req)

			if w.Code != http.StatusMethodNotAllowed {
				t.Errorf("expected status %d for method %s, got %d", http.StatusMethodNotAllowed, method, w.Code)
			}
		})
	}
}

// TestHandleTodoMethodNotAllowed tests that unsupported methods return 405
func TestHandleTodoMethodNotAllowed(t *testing.T) {
	methods := []string{http.MethodGet, http.MethodPost, http.MethodPatch}

	for _, method := range methods {
		t.Run(method, func(t *testing.T) {
			req := httptest.NewRequest(http.MethodGet, "/todos/1", nil)
			w := httptest.NewRecorder()

			app.HandleTodo(w, req)

			if w.Code != http.StatusMethodNotAllowed {
				t.Errorf("expected status %d for method %s, got %d", http.StatusMethodNotAllowed, method, w.Code)
			}
		})
	}
}

// TestHandleTodoInvalidID tests that invalid todo IDs return 400
func TestHandleTodoInvalidID(t *testing.T) {
	invalidIDs := []string{"abc", "1.5", "-1", "999999999999999999999"}

	for _, id := range invalidIDs {
		t.Run(id, func(t *testing.T) {
			req := httptest.NewRequest(http.MethodPut, "/todos/"+id, nil)
			w := httptest.NewRecorder()

			app.HandleTodo(w, req)

			if w.Code != http.StatusBadRequest {
				t.Errorf("expected status %d for invalid ID %s, got %d", http.StatusBadRequest, id, w.Code)
			}
		})
	}
}

// TestAddTodoInvalidJSON tests that invalid JSON returns 400
func TestAddTodoInvalidJSON(t *testing.T) {
	tests := []struct {
		name string
		body string
	}{
		{
			name: "malformed JSON",
			body: `{"task": "test"`,
		},
		{
			name: "invalid JSON type",
			body: `"just a string"`,
		},
		{
			name: "empty body",
			body: `""`,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			req := httptest.NewRequest(http.MethodPost, "/todos", bytes.NewBufferString(tt.body))
			req.Header.Set("Content-Type", "application/json")
			w := httptest.NewRecorder()

			app.AddTodo(w, req)

			if w.Code != http.StatusBadRequest {
				t.Errorf("expected status %d for invalid JSON, got %d", http.StatusBadRequest, w.Code)
			}
		})
	}
}

// TestUpdateTodoInvalidJSON tests that invalid JSON returns 400
func TestUpdateTodoInvalidJSON(t *testing.T) {
	req := httptest.NewRequest(http.MethodPut, "/todos/1", bytes.NewBufferString(`{"completed": "not a bool"}`))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()

	app.UpdateTodo(w, req, 1)

	if w.Code != http.StatusBadRequest {
		t.Errorf("expected status %d for invalid JSON, got %d", http.StatusBadRequest, w.Code)
	}
}

// TestTodoJSONMarshaling tests that Todo struct marshals/unmarshals correctly
func TestTodoJSONMarshaling(t *testing.T) {
	original := app.Todo{
		ID:        1,
		Task:      "Test task",
		Completed: true,
	}

	// Marshal to JSON
	data, err := json.Marshal(original)
	if err != nil {
		t.Fatalf("failed to marshal todo: %v", err)
	}

	// Unmarshal back
	var decoded app.Todo
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatalf("failed to unmarshal todo: %v", err)
	}

	// Compare
	if decoded.ID != original.ID {
		t.Errorf("expected ID %d, got %d", original.ID, decoded.ID)
	}
	if decoded.Task != original.Task {
		t.Errorf("expected task %q, got %q", original.Task, decoded.Task)
	}
	if decoded.Completed != original.Completed {
		t.Errorf("expected completed %v, got %v", original.Completed, decoded.Completed)
	}
}

// TestDBConfigJSONMarshaling tests that DBConfig unmarshals correctly
func TestDBConfigJSONMarshaling(t *testing.T) {
	jsonStr := `{
		"db_user": "test-user",
		"db_name": "test-db",
		"db_host": "127.0.0.1",
		"db_port": "5432",
		"db_read_host": "127.0.0.1",
		"db_read_port": "5433"
	}`

	var config app.DBConfig
	if err := json.Unmarshal([]byte(jsonStr), &config); err != nil {
		t.Fatalf("failed to unmarshal DBConfig: %v", err)
	}

	if config.DBUser != "test-user" {
		t.Errorf("expected DBUser %q, got %q", "test-user", config.DBUser)
	}
	if config.DBName != "test-db" {
		t.Errorf("expected DBName %q, got %q", "test-db", config.DBName)
	}
	if config.DBHost != "127.0.0.1" {
		t.Errorf("expected DBHost %q, got %q", "127.0.0.1", config.DBHost)
	}
	if config.DBPort != "5432" {
		t.Errorf("expected DBPort %q, got %q", "5432", config.DBPort)
	}
	if config.DBReadHost != "127.0.0.1" {
		t.Errorf("expected DBReadHost %q, got %q", "127.0.0.1", config.DBReadHost)
	}
	if config.DBReadPort != "5433" {
		t.Errorf("expected DBReadPort %q, got %q", "5433", config.DBReadPort)
	}
}

// TestCircuitBreakerInitialization tests that the circuit breaker is properly initialized
func TestCircuitBreakerInitialization(t *testing.T) {
	if app.CB == nil {
		t.Fatal("circuit breaker should be initialized")
	}

	// Test that circuit breaker starts in closed state
	// We can't directly access the state, but we can test that it allows requests
	_, err := app.CB.Execute(func() (interface{}, error) {
		return nil, nil
	})

	if err != nil {
		t.Errorf("circuit breaker should allow requests in closed state, got error: %v", err)
	}
}

// TestCircuitBreakerOpensOnFailures tests that circuit breaker opens after failures
func TestCircuitBreakerOpensOnFailures(t *testing.T) {
	// Create a new circuit breaker for this test to avoid affecting other tests
	var st gobreaker.Settings
	st.Name = "TestCB"
	st.MaxRequests = 1
	st.Interval = 0
	st.Timeout = 100 * time.Millisecond
	st.ReadyToTrip = func(counts gobreaker.Counts) bool {
		return counts.Requests >= 3 && float64(counts.TotalFailures)/float64(counts.Requests) >= 0.6
	}

	testCB := gobreaker.NewCircuitBreaker(st)
	originalCB := app.CB
	app.CB = testCB

	// Simulate failures
	for i := 0; i < 3; i++ {
		testCB.Execute(func() (interface{}, error) {
			return nil, http.ErrServerClosed
		})
	}

	// Circuit should now be open
	_, err := testCB.Execute(func() (interface{}, error) {
		return nil, nil
	})

	if err != gobreaker.ErrOpenState {
		t.Errorf("expected circuit breaker to be open, got error: %v", err)
	}

	// Wait for timeout and verify it transitions to half-open
	time.Sleep(150 * time.Millisecond)

	// Should allow one request in half-open state
	_, err = testCB.Execute(func() (interface{}, error) {
		return nil, nil
	})

	if err != nil {
		t.Errorf("circuit breaker should allow request in half-open state, got error: %v", err)
	}
	app.CB = originalCB
}