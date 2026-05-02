package tokenbridge

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"
)

// Store wraps the *sql.DB used by the token-bridge service to persist
// encrypted xoxc/xoxd tokens and audit log entries.
//
// All methods take a context.Context so callers can enforce request
// deadlines. The underlying *sql.DB is safe for concurrent use.
type Store struct {
	db *sql.DB
}

// NewStore constructs a Store wrapping db. It does not validate the
// connection — callers should Ping after construction if a fast-fail is
// desired.
func NewStore(db *sql.DB) *Store {
	return &Store{db: db}
}

// DB returns the underlying *sql.DB. Exposed so tests can run setup or
// teardown SQL without re-opening the connection.
func (s *Store) DB() *sql.DB {
	return s.db
}

// ReasonStale is returned by UpsertWorkspace when an incoming refresh
// is older than (or equal to) the workspace's last_refreshed_at and
// is therefore ignored.
const ReasonStale = "stale"

// UpsertWorkspace stores the latest encrypted xoxc/xoxd pair for teamID.
//
// If a row already exists for teamID and its last_refreshed_at is greater
// than or equal to capturedAt, the upsert is skipped and (false, ReasonStale,
// nil) is returned. Equality is treated as stale because the userscript
// generates monotonically-increasing capturedAt timestamps; a duplicate
// timestamp implies a replay.
//
// Otherwise the row is inserted or updated and (true, "", nil) is returned.
func (s *Store) UpsertWorkspace(
	ctx context.Context,
	teamID, teamName string,
	xoxcEnc, xoxdEnc []byte,
	capturedAt time.Time,
) (bool, string, error) {
	if teamID == "" {
		return false, "", errors.New("team_id is required")
	}

	// Check existing last_refreshed_at. We do this in the same transaction
	// as the upsert so concurrent requests for the same team_id can't both
	// observe "no row" and double-write.
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return false, "", fmt.Errorf("begin tx: %w", err)
	}
	defer func() { _ = tx.Rollback() }()

	var existing time.Time
	err = tx.QueryRowContext(ctx,
		`SELECT last_refreshed_at FROM workspaces WHERE team_id = $1 FOR UPDATE`,
		teamID,
	).Scan(&existing)
	switch {
	case errors.Is(err, sql.ErrNoRows):
		// no existing row — fall through to insert
	case err != nil:
		return false, "", fmt.Errorf("select existing: %w", err)
	default:
		if !capturedAt.After(existing) {
			if err := tx.Commit(); err != nil {
				return false, "", fmt.Errorf("commit (stale): %w", err)
			}
			return false, ReasonStale, nil
		}
	}

	_, err = tx.ExecContext(ctx, `
		INSERT INTO workspaces (team_id, team_name, xoxc_enc, xoxd_enc, last_refreshed_at, created_at, updated_at)
		VALUES ($1, $2, $3, $4, $5, now(), now())
		ON CONFLICT (team_id) DO UPDATE SET
			team_name = EXCLUDED.team_name,
			xoxc_enc = EXCLUDED.xoxc_enc,
			xoxd_enc = EXCLUDED.xoxd_enc,
			last_refreshed_at = EXCLUDED.last_refreshed_at,
			updated_at = now()
	`, teamID, teamName, xoxcEnc, xoxdEnc, capturedAt)
	if err != nil {
		return false, "", fmt.Errorf("upsert workspace: %w", err)
	}

	if err := tx.Commit(); err != nil {
		return false, "", fmt.Errorf("commit upsert: %w", err)
	}
	return true, "", nil
}

// WriteAudit appends a row to audit_log. The event field is opaque to
// the store; callers pass strings like "refreshed", "skipped_stale", or
// "rejected_signature".
//
// sourceIP and userAgent are optional; pass "" to record NULL.
func (s *Store) WriteAudit(
	ctx context.Context,
	teamID, event string,
	capturedAt time.Time,
	sourceIP, userAgent string,
) error {
	var (
		ipArg *string
		uaArg *string
		capAt *time.Time
	)
	if sourceIP != "" {
		ipArg = &sourceIP
	}
	if userAgent != "" {
		uaArg = &userAgent
	}
	if !capturedAt.IsZero() {
		capAt = &capturedAt
	}

	_, err := s.db.ExecContext(ctx, `
		INSERT INTO audit_log (team_id, event, captured_at, source_ip, user_agent)
		VALUES ($1, $2, $3, $4, $5)
	`, teamID, event, capAt, ipArg, uaArg)
	if err != nil {
		return fmt.Errorf("insert audit_log: %w", err)
	}
	return nil
}

// Ping verifies the database connection is alive.
func (s *Store) Ping(ctx context.Context) error {
	return s.db.PingContext(ctx)
}
