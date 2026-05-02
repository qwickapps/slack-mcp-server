// Package multiplexer implements the per-team MCP child-process router.
//
// The multiplexer reads workspace credentials from the token-bridge DB,
// lazily spawns one upstream mcp-server child per team, and relays
// opaque MCP JSON-RPC frames between the HTTP caller and the child's
// stdio transport.
package multiplexer

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"
)

// WorkspaceReader is the subset of DB access the multiplexer needs.
// Implemented by DBReader. Declared as an interface so tests can
// substitute a fake without a real database.
type WorkspaceReader interface {
	// ListWorkspaces returns all workspace rows ordered by team_id.
	// Called at startup and by the refresh poller.
	ListWorkspaces(ctx context.Context) ([]Workspace, error)

	// GetWorkspace returns the workspace row for teamID.
	// Returns sql.ErrNoRows when the team is unknown.
	GetWorkspace(ctx context.Context, teamID string) (Workspace, error)

	// Ping verifies that the DB connection is alive.
	Ping(ctx context.Context) error
}

// Workspace holds the per-team credentials read from the workspaces table.
// XoxcEnc and XoxdEnc are the raw encrypted bytea values; the caller
// (Registry) is responsible for decryption via tokenbridge.Cipher.
type Workspace struct {
	TeamID          string
	TeamName        string
	XoxcEnc         []byte
	XoxdEnc         []byte
	LastRefreshedAt time.Time
}

// DBReader implements WorkspaceReader against a *sql.DB.
// It provides read-only access; write paths belong to pkg/tokenbridge.
type DBReader struct {
	db *sql.DB
}

// NewDBReader constructs a DBReader wrapping db. It does not validate the
// connection — callers should Ping after construction if a fast-fail is
// desired.
func NewDBReader(db *sql.DB) *DBReader {
	return &DBReader{db: db}
}

// ListWorkspaces returns all rows from the workspaces table ordered by team_id.
func (r *DBReader) ListWorkspaces(ctx context.Context) ([]Workspace, error) {
	rows, err := r.db.QueryContext(ctx,
		`SELECT team_id, team_name, xoxc_enc, xoxd_enc, last_refreshed_at
		   FROM workspaces
		  ORDER BY team_id`,
	)
	if err != nil {
		return nil, fmt.Errorf("list workspaces: %w", err)
	}
	defer rows.Close()

	var out []Workspace
	for rows.Next() {
		var w Workspace
		if err := rows.Scan(
			&w.TeamID,
			&w.TeamName,
			&w.XoxcEnc,
			&w.XoxdEnc,
			&w.LastRefreshedAt,
		); err != nil {
			return nil, fmt.Errorf("scan workspace row: %w", err)
		}
		out = append(out, w)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("iterate workspace rows: %w", err)
	}
	return out, nil
}

// GetWorkspace returns the workspace row for teamID.
// Returns the underlying sql.ErrNoRows when the team is unknown.
func (r *DBReader) GetWorkspace(ctx context.Context, teamID string) (Workspace, error) {
	var w Workspace
	err := r.db.QueryRowContext(ctx,
		`SELECT team_id, team_name, xoxc_enc, xoxd_enc, last_refreshed_at
		   FROM workspaces
		  WHERE team_id = $1`,
		teamID,
	).Scan(
		&w.TeamID,
		&w.TeamName,
		&w.XoxcEnc,
		&w.XoxdEnc,
		&w.LastRefreshedAt,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return Workspace{}, sql.ErrNoRows
	}
	if err != nil {
		return Workspace{}, fmt.Errorf("get workspace %s: %w", teamID, err)
	}
	return w, nil
}

// Ping verifies the database connection is alive.
func (r *DBReader) Ping(ctx context.Context) error {
	return r.db.PingContext(ctx)
}

// Compile-time guard: *DBReader must satisfy WorkspaceReader.
var _ WorkspaceReader = (*DBReader)(nil)
