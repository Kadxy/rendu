// Package store persists everything the server knows in a single SQLite file.
package store

import (
	"bytes"
	"context"
	"crypto/rand"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strings"
	"time"

	_ "modernc.org/sqlite"
)

// ErrNotFound is returned when a referenced row does not exist.
var ErrNotFound = errors.New("not found")

// ValidationError marks input the client must fix; the HTTP layer maps it to 400.
type ValidationError struct{ Msg string }

func (e *ValidationError) Error() string { return e.Msg }

func invalid(format string, args ...any) error {
	return &ValidationError{Msg: fmt.Sprintf(format, args...)}
}

type Store struct {
	db  *sql.DB
	now func() time.Time
}

// Open creates or opens the database at path and applies the schema.
func Open(path string) (*Store, error) {
	// Create the file ourselves so it is 0600 from the first byte: it holds
	// health data. SQLite gives the -wal/-shm files the database file's mode.
	f, err := os.OpenFile(path, os.O_RDWR|os.O_CREATE, 0o600)
	if err != nil {
		return nil, err
	}
	f.Close()
	if err := os.Chmod(path, 0o600); err != nil {
		return nil, err
	}

	// Immediate transactions take the write lock up front, where the busy
	// timeout applies, rather than failing when a read upgrades to a write.
	// synchronous=FULL: a 2xx tells the phone it may drop its copy, so a
	// commit must survive power loss (NORMAL in WAL mode may roll it back).
	dsn := "file:" + path + "?_pragma=busy_timeout(10000)&_pragma=synchronous(FULL)&_pragma=cache_size(-65536)&_txlock=immediate"
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, err
	}
	// A single-user server never needs concurrent writers; one connection
	// rules out SQLITE_BUSY between pooled connections entirely.
	db.SetMaxOpenConns(1)

	// Switching to WAL needs an exclusive lock and SQLite doesn't wait for
	// it, so a second process opening a fresh database (a backup tool next
	// to a starting server) retries. The mode is persistent: once the file is
	// in WAL the switch is a no-op.
	if err := retryBusy(func() error {
		_, err := db.Exec(`PRAGMA journal_mode=WAL`)
		return err
	}); err != nil {
		db.Close()
		return nil, fmt.Errorf("enable WAL: %w", err)
	}

	s := &Store{db: db, now: time.Now}
	if err := s.migrate(context.Background()); err != nil {
		db.Close()
		return nil, err
	}
	return s, nil
}

func (s *Store) Close() error { return s.db.Close() }

func retryBusy(op func() error) error {
	deadline := time.Now().Add(10 * time.Second)
	for {
		err := op()
		var coded interface{ Code() int }
		if err == nil || !errors.As(err, &coded) || coded.Code()&0xff != 5 || time.Now().After(deadline) {
			return err
		}
		time.Sleep(20 * time.Millisecond)
	}
}

// SetClock replaces the time source (tests).
func (s *Store) SetClock(now func() time.Time) { s.now = now }

var schema = []string{
	`CREATE TABLE IF NOT EXISTS samples (
		uuid             TEXT PRIMARY KEY,
		type             TEXT NOT NULL,
		kind             TEXT NOT NULL,
		start_ms         INTEGER NOT NULL,
		end_ms           INTEGER NOT NULL,
		source_bundle_id TEXT,
		sync_identifier  TEXT,
		body             TEXT NOT NULL,
		received_at      INTEGER NOT NULL,
		deleted_at       INTEGER,
		-- Position in the change feed (changes.go); NULL for a sample that
		-- arrived after its tombstone, which no reader ever saw.
		change_seq       INTEGER
	)`,
	// Partial indexes: every read path filters deleted rows out.
	`CREATE INDEX IF NOT EXISTS samples_live_type_start ON samples(type, start_ms, uuid) WHERE deleted_at IS NULL`,
	`CREATE INDEX IF NOT EXISTS samples_live_type_end ON samples(type, end_ms) WHERE deleted_at IS NULL`,
	`CREATE INDEX IF NOT EXISTS samples_sync_identifier ON samples(sync_identifier) WHERE sync_identifier IS NOT NULL`,
	// Per-type facts maintained on ingest. max_duration_ms bounds range
	// queries from below so they can use the start index.
	`CREATE TABLE IF NOT EXISTS sample_types (
		type            TEXT PRIMARY KEY,
		kind            TEXT NOT NULL,
		max_duration_ms INTEGER NOT NULL
	)`,
	// Deletions are kept even for uuids never seen, so a sample that arrives
	// after its tombstone is stored as deleted.
	`CREATE TABLE IF NOT EXISTS deletions (
		uuid       TEXT PRIMARY KEY,
		deleted_at INTEGER NOT NULL
	)`,
	`CREATE TABLE IF NOT EXISTS statistics (
		type        TEXT NOT NULL,
		interval    TEXT NOT NULL,
		start_ms    INTEGER NOT NULL,
		end_ms      INTEGER NOT NULL,
		unit        TEXT NOT NULL,
		time_zone   TEXT,
		body        TEXT NOT NULL,
		computed_at INTEGER NOT NULL,
		PRIMARY KEY (type, interval, start_ms)
	)`,
	`CREATE TABLE IF NOT EXISTS activity_summaries (
		date       TEXT PRIMARY KEY,
		body       TEXT NOT NULL,
		updated_at INTEGER NOT NULL
	)`,
	`CREATE TABLE IF NOT EXISTS characteristics (
		id         INTEGER PRIMARY KEY CHECK (id = 1),
		body       TEXT NOT NULL,
		updated_at INTEGER NOT NULL
	)`,
	`CREATE TABLE IF NOT EXISTS writes (
		seq             INTEGER PRIMARY KEY AUTOINCREMENT,
		id              TEXT NOT NULL UNIQUE,
		op              TEXT NOT NULL,
		sync_identifier TEXT NOT NULL,
		sync_version    INTEGER,
		object          TEXT,
		status          TEXT NOT NULL,
		uuids           TEXT,
		error           TEXT,
		created_at      INTEGER NOT NULL,
		updated_at      INTEGER NOT NULL,
		-- The credential that submitted the write, and its name then, so
		-- the name outlives a revoked key.
		submitted_by      TEXT,
		submitted_by_name TEXT
	)`,
	`CREATE INDEX IF NOT EXISTS writes_sync ON writes(sync_identifier, seq)`,
	`CREATE INDEX IF NOT EXISTS writes_status ON writes(status, seq)`,
	`CREATE TABLE IF NOT EXISTS kv (
		key   TEXT PRIMARY KEY,
		value TEXT NOT NULL
	)`,
	`CREATE TABLE IF NOT EXISTS credentials (
		id           TEXT PRIMARY KEY,
		hash         TEXT NOT NULL UNIQUE,
		name         TEXT NOT NULL,
		scope        TEXT NOT NULL,
		created_at   INTEGER NOT NULL,
		last_used_at INTEGER
	)`,
	`CREATE TABLE IF NOT EXISTS pairing (
		id         INTEGER PRIMARY KEY CHECK (id = 1),
		code       TEXT NOT NULL,
		expires_at INTEGER NOT NULL,
		attempts   INTEGER NOT NULL
	)`,
	`CREATE TABLE IF NOT EXISTS sync_anchors (
		type       TEXT PRIMARY KEY,
		anchor     TEXT NOT NULL,
		updated_at INTEGER NOT NULL
	)`,
	// One entry per API key request (activity.go); body is the entry's JSON.
	`CREATE TABLE IF NOT EXISTS key_activity (
		seq           INTEGER PRIMARY KEY AUTOINCREMENT,
		credential_id TEXT NOT NULL,
		at            INTEGER NOT NULL,
		body          TEXT NOT NULL
	)`,
	`CREATE INDEX IF NOT EXISTS key_activity_credential ON key_activity(credential_id, seq)`,
	`CREATE INDEX IF NOT EXISTS key_activity_at ON key_activity(at)`,
	// The phone's write authorization per type (authorization.go).
	`CREATE TABLE IF NOT EXISTS share_authorization (
		id         INTEGER PRIMARY KEY CHECK (id = 1),
		body       TEXT NOT NULL,
		updated_at INTEGER NOT NULL
	)`,
	// HKUserAnnotatedMedication list, as the phone uploaded it.
	`CREATE TABLE IF NOT EXISTS medications (
		id         INTEGER PRIMARY KEY CHECK (id = 1),
		body       TEXT NOT NULL,
		updated_at INTEGER NOT NULL
	)`,
	// What the phone's HealthKit supports (catalog.go), as uploaded.
	`CREATE TABLE IF NOT EXISTS catalog (
		id         INTEGER PRIMARY KEY CHECK (id = 1),
		body       TEXT NOT NULL,
		updated_at INTEGER NOT NULL
	)`,
}

// addedColumns were added to tables after they were first created; newer
// databases get them from the CREATE TABLE statements above. backfill runs
// in the same transaction as the ALTER, so it runs exactly once.
var addedColumns = []struct{ table, column, decl, backfill string }{
	{"writes", "submitted_by", "TEXT", ""},
	{"writes", "submitted_by_name", "TEXT", ""},
	// Existing live samples enter the change feed in arrival order (rowid);
	// deleted ones were never seen by a feed reader.
	{"samples", "change_seq", "INTEGER", `UPDATE samples SET change_seq = rowid WHERE deleted_at IS NULL`},
}

// afterColumns need the added columns.
var afterColumns = []string{
	`CREATE INDEX IF NOT EXISTS samples_change ON samples(change_seq, type) WHERE change_seq IS NOT NULL`,
	// The feed's counter starts where the backfill ended (0 when new). The
	// WHERE is SQLite's required disambiguation for an upsert from SELECT.
	`INSERT INTO kv(key, value) SELECT 'changeSeq', COALESCE(MAX(change_seq), 0) FROM samples WHERE true
	 ON CONFLICT(key) DO NOTHING`,
}

func (s *Store) migrate(ctx context.Context) error {
	// tokens and pairings were an earlier auth scheme; "last seen" times are
	// kept per credential now.
	// anchors was keyed per device before an iPhone owned the server.
	cleanup := []string{`DROP TABLE IF EXISTS tokens`, `DROP TABLE IF EXISTS pairings`, `DROP TABLE IF EXISTS anchors`,
		`DELETE FROM kv WHERE key IN ('lastDeviceSeenAt', 'lastAgentSeenAt')`}
	for _, stmt := range append(schema, cleanup...) {
		if _, err := s.db.ExecContext(ctx, stmt); err != nil {
			return fmt.Errorf("migrate: %w", err)
		}
	}
	for _, c := range addedColumns {
		if err := s.addColumn(ctx, c.table, c.column, c.decl, c.backfill); err != nil {
			return fmt.Errorf("migrate: add %s.%s: %w", c.table, c.column, err)
		}
	}
	for _, stmt := range afterColumns {
		if _, err := s.db.ExecContext(ctx, stmt); err != nil {
			return fmt.Errorf("migrate: %w", err)
		}
	}
	// A database created before dataId existed gets one now.
	if _, err := s.db.ExecContext(ctx,
		`INSERT INTO kv(key, value) VALUES('dataId', ?) ON CONFLICT(key) DO NOTHING`, newUUID()); err != nil {
		return fmt.Errorf("migrate: %w", err)
	}
	return nil
}

// addColumn adds a column unless the table has it. The check runs inside
// the (immediate) transaction, so two processes opening an old database at
// once don't both add it.
func (s *Store) addColumn(ctx context.Context, table, column, decl, backfill string) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var n int
	if err := tx.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM pragma_table_info(?) WHERE name = ?`, table, column).Scan(&n); err != nil {
		return err
	}
	if n > 0 {
		return nil
	}
	if _, err := tx.ExecContext(ctx, `ALTER TABLE `+table+` ADD COLUMN `+column+` `+decl); err != nil {
		return err
	}
	if backfill != "" {
		if _, err := tx.ExecContext(ctx, backfill); err != nil {
			return err
		}
	}
	return tx.Commit()
}

// ParseTimestamp parses an RFC 3339 timestamp (fractional seconds allowed).
func ParseTimestamp(v string) (time.Time, error) {
	return time.Parse(time.RFC3339, v)
}

// FormatTime renders server-generated timestamps (always UTC).
func FormatTime(t time.Time) string { return t.UTC().Format(time.RFC3339) }

func fromMillis(ms int64) time.Time { return time.UnixMilli(ms) }

func (s *Store) setKV(ctx context.Context, ex execer, key, value string) error {
	_, err := ex.ExecContext(ctx,
		`INSERT INTO kv(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value`,
		key, value)
	return err
}

func (s *Store) getKV(ctx context.Context, key string) (string, error) {
	var v string
	err := s.db.QueryRowContext(ctx, `SELECT value FROM kv WHERE key = ?`, key).Scan(&v)
	if errors.Is(err, sql.ErrNoRows) {
		return "", nil
	}
	return v, err
}

type execer interface {
	ExecContext(ctx context.Context, query string, args ...any) (sql.Result, error)
}

// querier is a *sql.DB or a *sql.Tx. Inside a transaction every query must
// go through the Tx: the pool has a single connection.
type querier interface {
	QueryRowContext(ctx context.Context, query string, args ...any) *sql.Row
	QueryContext(ctx context.Context, query string, args ...any) (*sql.Rows, error)
}

// Status is the agent-facing freshness summary.
type Status struct {
	ServerTime   string `json:"serverTime"`
	LastIngestAt string `json:"lastIngestAt,omitempty"`
	// LastDeviceSeenAt is when the paired iPhone last called the server.
	LastDeviceSeenAt string `json:"lastDeviceSeenAt,omitempty"`
	// DataID names this server's copy of the health data: it changes only
	// when the data is wiped (or the database is new), so a phone that
	// remembers it can tell the server lost what it had uploaded.
	DataID        string `json:"dataId"`
	Samples       int64  `json:"samples"`
	Types         int64  `json:"types"`
	PendingWrites int64  `json:"pendingWrites"`
}

func (s *Store) Status(ctx context.Context) (Status, error) {
	st := Status{ServerTime: FormatTime(s.now())}
	var err error
	if st.LastIngestAt, err = s.getKV(ctx, "lastIngestAt"); err != nil {
		return st, err
	}
	if owner, err := s.Owner(ctx); err == nil {
		st.LastDeviceSeenAt = owner.LastUsedAt
	} else if !errors.Is(err, ErrNotFound) {
		return st, err
	}
	if st.DataID, err = s.getKV(ctx, "dataId"); err != nil {
		return st, err
	}
	if err := s.db.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM samples WHERE deleted_at IS NULL`).Scan(&st.Samples); err != nil {
		return st, err
	}
	if err := s.db.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM writes WHERE status = 'pending'`).Scan(&st.PendingWrites); err != nil {
		return st, err
	}
	if err := s.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM sample_types`).Scan(&st.Types); err != nil {
		return st, err
	}
	return st, nil
}

// newUUID returns an uppercase RFC 4122 v4 UUID, matching HealthKit's style.
func newUUID() string {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		panic(err)
	}
	b[6] = b[6]&0x0f | 0x40
	b[8] = b[8]&0x3f | 0x80
	return strings.ToUpper(fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:]))
}

func nullable(v string) any {
	if v == "" {
		return nil
	}
	return v
}

// compactJSON normalizes whitespace so stored bodies are small and uniform.
func compactJSON(raw []byte) (json.RawMessage, error) {
	var buf bytes.Buffer
	if err := json.Compact(&buf, raw); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

// WipeData deletes every health record and write — what the phone uploaded
// and what agents submitted. Credentials, their activity, and the phone's
// write authorization and catalog stay: they describe the server and the
// phone, not the data.
func (s *Store) WipeData(ctx context.Context) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	for _, table := range []string{"samples", "sample_types", "deletions", "statistics", "activity_summaries", "characteristics", "medications", "writes", "sync_anchors"} {
		if _, err := tx.ExecContext(ctx, `DELETE FROM `+table); err != nil {
			return err
		}
	}
	if _, err := tx.ExecContext(ctx, `DELETE FROM kv WHERE key = 'lastIngestAt'`); err != nil {
		return err
	}
	if err := s.setKV(ctx, tx, "dataId", newUUID()); err != nil {
		return err
	}
	return tx.Commit()
}
