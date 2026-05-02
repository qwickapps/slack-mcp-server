package multiplexer

import (
	"context"
	"database/sql"
	"os"
	"testing"
	"time"

	_ "github.com/lib/pq"
)

// TestDBReader_integration exercises DBReader against a real Postgres database.
// It is skipped unless TEST_DATABASE_URL is set in the environment.
func TestDBReader_integration(t *testing.T) {
	dsn := os.Getenv("TEST_DATABASE_URL")
	if dsn == "" {
		t.Skip("TEST_DATABASE_URL not set; skipping integration tests")
	}

	db, err := sql.Open("postgres", dsn)
	if err != nil {
		t.Fatalf("sql.Open: %v", err)
	}
	defer db.Close()

	ctx := context.Background()
	if err := db.PingContext(ctx); err != nil {
		t.Fatalf("db.Ping: %v", err)
	}

	// Ensure the table exists; if not, skip gracefully.
	var exists bool
	err = db.QueryRowContext(ctx,
		`SELECT EXISTS (
			SELECT FROM information_schema.tables
			WHERE table_name = 'workspaces'
		)`,
	).Scan(&exists)
	if err != nil {
		t.Fatalf("check table: %v", err)
	}
	if !exists {
		t.Skip("workspaces table does not exist; run migrations first")
	}

	reader := NewDBReader(db)

	// Ping.
	if err := reader.Ping(ctx); err != nil {
		t.Errorf("Ping: %v", err)
	}

	// Insert test fixtures. Use a team_id prefix unlikely to collide.
	const teamA = "TTEST_DBR_A"
	const teamB = "TTEST_DBR_B"
	cleanup := func() {
		_, _ = db.ExecContext(ctx, `DELETE FROM workspaces WHERE team_id LIKE 'TTEST_DBR_%'`)
	}
	cleanup()
	t.Cleanup(cleanup)

	now := time.Now().UTC().Truncate(time.Millisecond)
	for _, row := range []struct {
		id, name   string
		xoxc, xoxd []byte
	}{
		{teamA, "Team A", []byte("enc-xoxc-a"), []byte("enc-xoxd-a")},
		{teamB, "Team B", []byte("enc-xoxc-b"), []byte("enc-xoxd-b")},
	} {
		_, err := db.ExecContext(ctx, `
			INSERT INTO workspaces (team_id, team_name, xoxc_enc, xoxd_enc, last_refreshed_at, created_at, updated_at)
			VALUES ($1, $2, $3, $4, $5, now(), now())
			ON CONFLICT (team_id) DO UPDATE SET
				team_name = EXCLUDED.team_name,
				xoxc_enc = EXCLUDED.xoxc_enc,
				xoxd_enc = EXCLUDED.xoxd_enc,
				last_refreshed_at = EXCLUDED.last_refreshed_at,
				updated_at = now()
		`, row.id, row.name, row.xoxc, row.xoxd, now)
		if err != nil {
			t.Fatalf("insert fixture %s: %v", row.id, err)
		}
	}

	// ListWorkspaces: both teams should appear.
	t.Run("ListWorkspaces", func(t *testing.T) {
		workspaces, err := reader.ListWorkspaces(ctx)
		if err != nil {
			t.Fatalf("ListWorkspaces: %v", err)
		}
		found := map[string]bool{}
		for _, w := range workspaces {
			found[w.TeamID] = true
		}
		for _, id := range []string{teamA, teamB} {
			if !found[id] {
				t.Errorf("expected team %s in ListWorkspaces result", id)
			}
		}
	})

	// GetWorkspace: known team returns correct row.
	t.Run("GetWorkspace_found", func(t *testing.T) {
		w, err := reader.GetWorkspace(ctx, teamA)
		if err != nil {
			t.Fatalf("GetWorkspace(%s): %v", teamA, err)
		}
		if w.TeamID != teamA {
			t.Errorf("team_id: got %q want %q", w.TeamID, teamA)
		}
		if w.TeamName != "Team A" {
			t.Errorf("team_name: got %q want %q", w.TeamName, "Team A")
		}
		if string(w.XoxcEnc) != "enc-xoxc-a" {
			t.Errorf("xoxc_enc: got %q want %q", w.XoxcEnc, "enc-xoxc-a")
		}
	})

	// GetWorkspace: unknown team returns sql.ErrNoRows.
	t.Run("GetWorkspace_missing", func(t *testing.T) {
		_, err := reader.GetWorkspace(ctx, "TTEST_DBR_NOTEXIST")
		if !isErrNoRows(err) {
			t.Errorf("expected sql.ErrNoRows, got %v", err)
		}
	})
}

// isErrNoRows reports whether err is or wraps sql.ErrNoRows.
func isErrNoRows(err error) bool {
	return err == sql.ErrNoRows
}
