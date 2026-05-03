package setup_test

import (
	"context"
	"database/sql"
	"os"
	"testing"
	"time"

	_ "github.com/lib/pq"

	"github.com/korotovsky/slack-mcp-server/pkg/setup"
)

// TestDBReaderListWorkspaces is an integration test that requires a live
// Postgres connection. It is skipped when TEST_DATABASE_URL is not set.
func TestDBReaderListWorkspaces(t *testing.T) {
	dbURL := os.Getenv("TEST_DATABASE_URL")
	if dbURL == "" {
		t.Skip("TEST_DATABASE_URL not set; skipping DB integration test")
	}

	db, err := sql.Open("postgres", dbURL)
	if err != nil {
		t.Fatalf("sql.Open: %v", err)
	}
	defer db.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	if err := db.PingContext(ctx); err != nil {
		t.Fatalf("ping: %v", err)
	}

	reader := setup.NewDBReader(db)

	// ListWorkspaces must not return an error when the table exists (even if empty).
	workspaces, err := reader.ListWorkspaces(ctx)
	if err != nil {
		t.Fatalf("ListWorkspaces: %v", err)
	}

	// Log count for visibility; exact rows depend on test DB state.
	t.Logf("ListWorkspaces returned %d rows", len(workspaces))
}

// TestDBReaderPing is an integration test that verifies Ping forwards to
// the underlying *sql.DB correctly.
func TestDBReaderPing(t *testing.T) {
	dbURL := os.Getenv("TEST_DATABASE_URL")
	if dbURL == "" {
		t.Skip("TEST_DATABASE_URL not set; skipping DB integration test")
	}

	db, err := sql.Open("postgres", dbURL)
	if err != nil {
		t.Fatalf("sql.Open: %v", err)
	}
	defer db.Close()

	reader := setup.NewDBReader(db)

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	if err := reader.Ping(ctx); err != nil {
		t.Fatalf("Ping: %v", err)
	}
}
