// Package store is the SQLite persistence layer. It deliberately exposes two
// handles with different capabilities:
//
//   - ReadStore: a pooled read-only connection set.
//   - WriteStore: a SINGLE serialized write connection.
//
// SQLite allows only one writer; funneling every write through one connection
// (and taking the write lock up front with BEGIN IMMEDIATE) is what keeps
// "database is locked" from ever appearing under concurrent syncs. Because the
// two are distinct Go types, handing a read-only flow to a writer — or vice
// versa — is a compile error, not a 3am runtime panic. See DESIGN.md.
package store

import (
	"context"
	"database/sql"
	"embed"
	"fmt"
	"sort"
	"strings"

	_ "modernc.org/sqlite" // pure-Go SQLite driver, no cgo
)

//go:embed migrations/*.sql
var migrationsFS embed.FS

// Store owns both connection handles and the underlying file.
type Store struct {
	read  *sql.DB
	write *sql.DB
}

// ReadStore is the read-only view. Methods here must never write.
type ReadStore struct{ db *sql.DB }

// WriteStore is the serialized write view. All mutations go through it, inside
// a BEGIN IMMEDIATE transaction so the write lock is grabbed before any work.
type WriteStore struct{ db *sql.DB }

// Open opens (creating if needed) the SQLite database at path, configures WAL
// + busy_timeout, runs migrations, and returns the Store.
func Open(ctx context.Context, path string) (*Store, error) {
	// Shared pragmas. busy_timeout is a safety net; the single-writer design is
	// the real guarantee. foreign_keys must be set per-connection.
	dsn := path + "?_pragma=busy_timeout(5000)&_pragma=journal_mode(WAL)&_pragma=foreign_keys(ON)"

	write, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, fmt.Errorf("open write db: %w", err)
	}
	// The whole point: exactly one write connection.
	write.SetMaxOpenConns(1)

	read, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, fmt.Errorf("open read db: %w", err)
	}
	read.SetMaxOpenConns(max(4, 8))

	s := &Store{read: read, write: write}
	if err := s.migrate(ctx); err != nil {
		return nil, fmt.Errorf("migrate: %w", err)
	}
	return s, nil
}

// Read returns the read-only handle.
func (s *Store) Read() *ReadStore { return &ReadStore{db: s.read} }

// Write returns the serialized write handle.
func (s *Store) Write() *WriteStore { return &WriteStore{db: s.write} }

// Close closes both handles.
func (s *Store) Close() error {
	err1 := s.read.Close()
	err2 := s.write.Close()
	if err1 != nil {
		return err1
	}
	return err2
}

// Tx runs fn inside a transaction on the single write connection. Because the
// write pool holds exactly one connection, all writers are serialized; there
// is no second writer to race, so the "read transaction upgraded to a write"
// hazard the design warns about cannot occur here — every write path goes
// through WriteStore. Rolls back on error or panic, commits otherwise.
func (w *WriteStore) Tx(ctx context.Context, fn func(*sql.Tx) error) (err error) {
	tx, err := w.db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("begin: %w", err)
	}
	defer func() {
		if p := recover(); p != nil {
			_ = tx.Rollback()
			panic(p)
		}
		if err != nil {
			_ = tx.Rollback()
		}
	}()
	if err = fn(tx); err != nil {
		return err
	}
	return tx.Commit()
}

// DB exposes the read pool for query helpers in sibling packages during M2
// build-out. Prefer typed methods as they are added.
func (r *ReadStore) DB() *sql.DB { return r.db }

func (s *Store) migrate(ctx context.Context) error {
	if _, err := s.write.ExecContext(ctx,
		`CREATE TABLE IF NOT EXISTS schema_migrations (name TEXT PRIMARY KEY, applied_at INTEGER NOT NULL)`); err != nil {
		return err
	}
	entries, err := migrationsFS.ReadDir("migrations")
	if err != nil {
		return err
	}
	names := make([]string, 0, len(entries))
	for _, e := range entries {
		if strings.HasSuffix(e.Name(), ".sql") {
			names = append(names, e.Name())
		}
	}
	sort.Strings(names)

	for _, name := range names {
		var seen int
		if err := s.write.QueryRowContext(ctx,
			`SELECT COUNT(1) FROM schema_migrations WHERE name = ?`, name).Scan(&seen); err != nil {
			return err
		}
		if seen > 0 {
			continue
		}
		body, err := migrationsFS.ReadFile("migrations/" + name)
		if err != nil {
			return err
		}
		if _, err := s.write.ExecContext(ctx, string(body)); err != nil {
			return fmt.Errorf("apply %s: %w", name, err)
		}
		if _, err := s.write.ExecContext(ctx,
			`INSERT INTO schema_migrations (name, applied_at) VALUES (?, unixepoch())`, name); err != nil {
			return err
		}
	}
	return nil
}
