package tokenbridge

import (
	"context"
	"database/sql"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// DefaultMigrationsDir is the on-disk path used by Migrate when no
// explicit path is supplied. It is relative to the binary's working
// directory; in container deployments the Dockerfile places the SQL
// files at /app/migrations and sets the working dir to /app.
const DefaultMigrationsDir = "migrations"

// Migrate applies every .sql file in dir in lexicographic order. All
// migrations are written with `IF NOT EXISTS` and are therefore idempotent
// — re-running Migrate against an up-to-date database is a no-op.
//
// We deliberately do not use a tracking table: the migrations themselves
// are the contract. This keeps bootstrap simple for fresh dev DBs and
// avoids partial-migration weirdness across deploys.
func Migrate(ctx context.Context, db *sql.DB, dir string) error {
	if dir == "" {
		dir = DefaultMigrationsDir
	}

	entries, err := os.ReadDir(dir)
	if err != nil {
		return fmt.Errorf("read migrations dir %q: %w", dir, err)
	}

	names := make([]string, 0, len(entries))
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".sql") {
			continue
		}
		names = append(names, e.Name())
	}
	sort.Strings(names)

	if len(names) == 0 {
		return fmt.Errorf("no .sql files found in %q", dir)
	}

	for _, name := range names {
		path := filepath.Join(dir, name)
		body, err := os.ReadFile(path)
		if err != nil {
			return fmt.Errorf("read migration %s: %w", path, err)
		}
		if _, err := db.ExecContext(ctx, string(body)); err != nil {
			return fmt.Errorf("apply migration %s: %w", path, err)
		}
	}
	return nil
}
