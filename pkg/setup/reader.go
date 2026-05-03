package setup

import (
	"context"
	"database/sql"
	"fmt"
	"time"
)

// WorkspaceStatus is a point-in-time view of one workspace row used by the
// setup status page. Fields are read-only — the setup service never writes
// to the database.
type WorkspaceStatus struct {
	TeamID          string
	TeamName        string
	LastRefreshedAt time.Time
}

// WorkspaceStatusReader abstracts the database query used by the status page.
// Tests substitute a fake implementation without a real database.
type WorkspaceStatusReader interface {
	// ListWorkspaces returns all workspace rows ordered by last_refreshed_at
	// descending. The returned slice is nil when no rows exist.
	ListWorkspaces(ctx context.Context) ([]WorkspaceStatus, error)

	// Ping verifies the database connection is alive.
	Ping(ctx context.Context) error
}

// DBReader is the production implementation of WorkspaceStatusReader backed
// by a *sql.DB (shared with the token-bridge).
type DBReader struct {
	db *sql.DB
}

// NewDBReader constructs a DBReader. It does not validate the connection;
// callers should Ping after construction if a fast-fail is desired.
func NewDBReader(db *sql.DB) *DBReader {
	return &DBReader{db: db}
}

// ListWorkspaces queries the workspaces table for all rows ordered by
// last_refreshed_at descending.
func (r *DBReader) ListWorkspaces(ctx context.Context) ([]WorkspaceStatus, error) {
	rows, err := r.db.QueryContext(ctx, `
		SELECT team_id, team_name, last_refreshed_at
		FROM workspaces
		ORDER BY last_refreshed_at DESC
	`)
	if err != nil {
		return nil, fmt.Errorf("list workspaces: %w", err)
	}
	defer rows.Close()

	var result []WorkspaceStatus
	for rows.Next() {
		var ws WorkspaceStatus
		if err := rows.Scan(&ws.TeamID, &ws.TeamName, &ws.LastRefreshedAt); err != nil {
			return nil, fmt.Errorf("scan workspace: %w", err)
		}
		result = append(result, ws)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("iterate workspaces: %w", err)
	}
	return result, nil
}

// Ping verifies the database connection is alive.
func (r *DBReader) Ping(ctx context.Context) error {
	return r.db.PingContext(ctx)
}

// Compile-time guard: *DBReader must satisfy WorkspaceStatusReader.
var _ WorkspaceStatusReader = (*DBReader)(nil)
