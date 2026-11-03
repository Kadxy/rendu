package store

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"path/filepath"
	"sync"
	"testing"
	"time"
)

// The server and `rendu-server token create` open the same database file;
// whichever starts second must wait for the lock, not fail.
func TestConcurrentOpenOfFreshDatabase(t *testing.T) {
	for i := 0; i < 10; i++ {
		path := filepath.Join(t.TempDir(), "rendu.db")
		var wg sync.WaitGroup
		errs := make(chan error, 4)
		for j := 0; j < 4; j++ {
			wg.Add(1)
			go func() {
				defer wg.Done()
				s, err := Open(path)
				if err != nil {
					errs <- err
					return
				}
				defer s.Close()
				var timeout int
				if err := s.db.QueryRowContext(context.Background(), `PRAGMA busy_timeout`).Scan(&timeout); err != nil || timeout == 0 {
					errs <- err
				}
			}()
		}
		wg.Wait()
		close(errs)
		for err := range errs {
			t.Fatalf("round %d: %v", i, err)
		}
	}
}

// A database from before the change feed and write sources: live samples
// enter the feed in arrival order, deleted ones don't, the feed continues
// from there, and old writes have no submitter.
func TestMigrateOldDatabase(t *testing.T) {
	ctx := context.Background()
	path := filepath.Join(t.TempDir(), "old.db")
	old, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	for _, stmt := range []string{
		`CREATE TABLE samples (uuid TEXT PRIMARY KEY, type TEXT NOT NULL, kind TEXT NOT NULL,
		 start_ms INTEGER NOT NULL, end_ms INTEGER NOT NULL, source_bundle_id TEXT, sync_identifier TEXT,
		 body TEXT NOT NULL, received_at INTEGER NOT NULL, deleted_at INTEGER)`,
		`CREATE TABLE writes (seq INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL UNIQUE, op TEXT NOT NULL,
		 sync_identifier TEXT NOT NULL, sync_version INTEGER, object TEXT, status TEXT NOT NULL, uuids TEXT,
		 error TEXT, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL)`,
		`INSERT INTO samples VALUES ('Z', 't', 'quantity', 0, 0, NULL, NULL, '{"uuid":"Z"}', 0, NULL)`,
		`INSERT INTO samples VALUES ('A', 't', 'quantity', 0, 0, NULL, NULL, '{"uuid":"A"}', 0, NULL)`,
		`INSERT INTO samples VALUES ('D', 't', 'quantity', 0, 0, NULL, NULL, '{"uuid":"D"}', 0, 5)`,
		`INSERT INTO writes(id, op, sync_identifier, sync_version, object, status, created_at, updated_at)
		 VALUES ('W', 'save', 'S', 1, '{}', 'pending', 0, 0)`,
	} {
		if _, err := old.Exec(stmt); err != nil {
			t.Fatal(err)
		}
	}
	old.Close()

	s, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	// Opening again finds the columns in place.
	if again, err := Open(path); err != nil {
		t.Fatal(err)
	} else {
		again.Close()
	}

	feed, err := s.Changes(ctx, "", nil, 10)
	if err != nil {
		t.Fatal(err)
	}
	if fmt.Sprint(rawUUIDs(feed.Samples)) != "[Z A]" || len(feed.Deleted) != 0 {
		t.Fatalf("backfilled feed = %+v", feed)
	}
	if _, err := s.Ingest(ctx, []json.RawMessage{
		json.RawMessage(`{"uuid":"N","kind":"quantity","type":"t","startDate":"2026-11-01T08:00:00Z","endDate":"2026-11-01T08:00:00Z"}`),
	}, nil); err != nil {
		t.Fatal(err)
	}
	next, err := s.Changes(ctx, feed.Anchor, nil, 10)
	if err != nil || fmt.Sprint(rawUUIDs(next.Samples)) != "[N]" {
		t.Fatalf("after migration = %+v, %v", next, err)
	}
	w, err := s.GetWrite(ctx, "W")
	if err != nil || w.SubmittedBy != nil {
		t.Fatalf("old write = %+v, %v", w, err)
	}
}

func rawUUIDs(samples []json.RawMessage) []string {
	var out []string
	for _, raw := range samples {
		var v struct{ UUID string }
		json.Unmarshal(raw, &v)
		out = append(out, v.UUID)
	}
	return out
}

func TestActivityPruneAndRevoke(t *testing.T) {
	ctx := context.Background()
	s, err := Open(filepath.Join(t.TempDir(), "rendu.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	now := time.Date(2026, 11, 2, 12, 0, 0, 0, time.UTC)
	s.SetClock(func() time.Time { return now })
	key, _, err := s.CreateAPIKey(ctx, "agent", ScopeRead)
	if err != nil {
		t.Fatal(err)
	}
	for _, at := range []time.Time{now.Add(-ActivityRetention - time.Hour), now.Add(-ActivityRetention + time.Hour), now} {
		if err := s.RecordActivity(ctx, key.ID, at, Activity{Method: "GET", Path: "/v1/status", Status: 200}); err != nil {
			t.Fatal(err)
		}
	}
	if n, err := s.PruneActivity(ctx); err != nil || n != 1 {
		t.Fatalf("pruned %d, %v", n, err)
	}
	entries, next, err := s.KeyActivity(ctx, key.ID, 10, nil)
	if err != nil || len(entries) != 2 || next != nil {
		t.Fatalf("entries = %s, %v, %v", entries, next, err)
	}
	if err := s.RevokeAPIKey(ctx, key.ID); err != nil {
		t.Fatal(err)
	}
	var left int
	if err := s.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM key_activity`).Scan(&left); err != nil || left != 0 {
		t.Fatalf("activity left after revoking: %d, %v", left, err)
	}
}
