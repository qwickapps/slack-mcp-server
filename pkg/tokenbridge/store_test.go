package tokenbridge

import (
	"context"
	"database/sql"
	"os"
	"testing"
	"time"

	_ "github.com/lib/pq"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// openTestDB returns a *sql.DB backed by TEST_DATABASE_URL, or skips the
// test if the env var is unset. The schema is migrated and tables are
// truncated at the start of each test so cases are independent.
func openTestDB(t *testing.T) *sql.DB {
	t.Helper()

	dsn := os.Getenv("TEST_DATABASE_URL")
	if dsn == "" {
		t.Skip("set TEST_DATABASE_URL to run integration tests")
	}

	db, err := sql.Open("postgres", dsn)
	require.NoError(t, err)
	t.Cleanup(func() { _ = db.Close() })

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	require.NoError(t, db.PingContext(ctx))

	require.NoError(t, Migrate(ctx, db, findMigrationsDir(t)))

	_, err = db.ExecContext(ctx, `TRUNCATE TABLE workspaces, audit_log RESTART IDENTITY`)
	require.NoError(t, err)

	return db
}

// findMigrationsDir locates the repo's migrations dir relative to the
// test's working directory (which is the package dir). The package lives
// at pkg/tokenbridge so we walk up two levels.
func findMigrationsDir(t *testing.T) string {
	t.Helper()
	candidates := []string{"../../migrations", "migrations"}
	for _, c := range candidates {
		if _, err := os.Stat(c); err == nil {
			return c
		}
	}
	t.Fatalf("could not locate migrations dir; tried %v", candidates)
	return ""
}

func TestStore_Ping(t *testing.T) {
	db := openTestDB(t)
	s := NewStore(db)

	require.NoError(t, s.Ping(context.Background()))
}

func TestStore_UpsertWorkspace_Insert(t *testing.T) {
	db := openTestDB(t)
	s := NewStore(db)
	ctx := context.Background()

	captured := time.Now().UTC().Truncate(time.Microsecond)
	stored, reason, err := s.UpsertWorkspace(ctx, "T123", "Acme", []byte("xoxc-enc"), []byte("xoxd-enc"), captured)
	require.NoError(t, err)
	assert.True(t, stored)
	assert.Empty(t, reason)

	var (
		gotName    string
		gotXoxc    []byte
		gotXoxd    []byte
		gotRefresh time.Time
	)
	err = db.QueryRowContext(ctx, `SELECT team_name, xoxc_enc, xoxd_enc, last_refreshed_at FROM workspaces WHERE team_id = $1`, "T123").
		Scan(&gotName, &gotXoxc, &gotXoxd, &gotRefresh)
	require.NoError(t, err)
	assert.Equal(t, "Acme", gotName)
	assert.Equal(t, []byte("xoxc-enc"), gotXoxc)
	assert.Equal(t, []byte("xoxd-enc"), gotXoxd)
	assert.WithinDuration(t, captured, gotRefresh, time.Second)
}

func TestStore_UpsertWorkspace_NewerWins(t *testing.T) {
	db := openTestDB(t)
	s := NewStore(db)
	ctx := context.Background()

	t1 := time.Now().UTC().Add(-time.Minute).Truncate(time.Microsecond)
	t2 := t1.Add(30 * time.Second)

	stored, _, err := s.UpsertWorkspace(ctx, "T123", "Acme", []byte("v1"), []byte("d1"), t1)
	require.NoError(t, err)
	require.True(t, stored)

	stored, reason, err := s.UpsertWorkspace(ctx, "T123", "Acme Renamed", []byte("v2"), []byte("d2"), t2)
	require.NoError(t, err)
	assert.True(t, stored)
	assert.Empty(t, reason)

	var (
		gotName string
		gotXoxc []byte
	)
	err = db.QueryRowContext(ctx, `SELECT team_name, xoxc_enc FROM workspaces WHERE team_id = $1`, "T123").
		Scan(&gotName, &gotXoxc)
	require.NoError(t, err)
	assert.Equal(t, "Acme Renamed", gotName)
	assert.Equal(t, []byte("v2"), gotXoxc)
}

func TestStore_UpsertWorkspace_StaleSkipped(t *testing.T) {
	db := openTestDB(t)
	s := NewStore(db)
	ctx := context.Background()

	t1 := time.Now().UTC().Add(-time.Minute).Truncate(time.Microsecond)
	t0 := t1.Add(-30 * time.Second)

	stored, _, err := s.UpsertWorkspace(ctx, "T123", "Acme", []byte("v1"), []byte("d1"), t1)
	require.NoError(t, err)
	require.True(t, stored)

	stored, reason, err := s.UpsertWorkspace(ctx, "T123", "Acme", []byte("v0"), []byte("d0"), t0)
	require.NoError(t, err)
	assert.False(t, stored)
	assert.Equal(t, ReasonStale, reason)

	// existing row must be unchanged
	var gotXoxc []byte
	err = db.QueryRowContext(ctx, `SELECT xoxc_enc FROM workspaces WHERE team_id = $1`, "T123").Scan(&gotXoxc)
	require.NoError(t, err)
	assert.Equal(t, []byte("v1"), gotXoxc)
}

func TestStore_UpsertWorkspace_EqualTimestampSkipped(t *testing.T) {
	db := openTestDB(t)
	s := NewStore(db)
	ctx := context.Background()

	captured := time.Now().UTC().Truncate(time.Microsecond)

	stored, _, err := s.UpsertWorkspace(ctx, "T123", "Acme", []byte("v1"), []byte("d1"), captured)
	require.NoError(t, err)
	require.True(t, stored)

	stored, reason, err := s.UpsertWorkspace(ctx, "T123", "Acme", []byte("v2"), []byte("d2"), captured)
	require.NoError(t, err)
	assert.False(t, stored)
	assert.Equal(t, ReasonStale, reason)
}

func TestStore_UpsertWorkspace_RejectsEmptyTeamID(t *testing.T) {
	db := openTestDB(t)
	s := NewStore(db)

	_, _, err := s.UpsertWorkspace(context.Background(), "", "Acme", []byte("v"), []byte("d"), time.Now())
	assert.Error(t, err)
}

func TestStore_WriteAudit(t *testing.T) {
	db := openTestDB(t)
	s := NewStore(db)
	ctx := context.Background()

	captured := time.Now().UTC().Truncate(time.Microsecond)
	require.NoError(t, s.WriteAudit(ctx, "T1", "refreshed", captured, "10.0.0.1", "TamperUserscript/1.0"))
	require.NoError(t, s.WriteAudit(ctx, "T1", "skipped_stale", time.Time{}, "", ""))

	rows, err := db.QueryContext(ctx, `SELECT team_id, event, captured_at, source_ip::text, user_agent FROM audit_log ORDER BY id`)
	require.NoError(t, err)
	defer rows.Close()

	type row struct {
		teamID, event string
		capAt         sql.NullTime
		ip, ua        sql.NullString
	}
	var got []row
	for rows.Next() {
		var r row
		require.NoError(t, rows.Scan(&r.teamID, &r.event, &r.capAt, &r.ip, &r.ua))
		got = append(got, r)
	}
	require.Len(t, got, 2)

	assert.Equal(t, "T1", got[0].teamID)
	assert.Equal(t, "refreshed", got[0].event)
	assert.True(t, got[0].capAt.Valid)
	assert.WithinDuration(t, captured, got[0].capAt.Time, time.Second)
	assert.True(t, got[0].ip.Valid)
	assert.Equal(t, "10.0.0.1", got[0].ip.String)
	assert.True(t, got[0].ua.Valid)
	assert.Equal(t, "TamperUserscript/1.0", got[0].ua.String)

	assert.Equal(t, "skipped_stale", got[1].event)
	assert.False(t, got[1].capAt.Valid)
	assert.False(t, got[1].ip.Valid)
	assert.False(t, got[1].ua.Valid)
}
