package store

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"strconv"
	"time"
)

// API activity, like iOS's App Privacy Report: one entry per request an
// API key makes (never the owner), so the owner sees what each agent read
// and wrote. Entries are kept for ActivityRetention; revoking a key deletes
// them.

const ActivityRetention = 90 * 24 * time.Hour

// Activity is one request. Path is the route pattern (/v1/writes/{id}), and
// Type, Start, End and Interval are the request's parameters as given.
type Activity struct {
	At       string `json:"at"`
	Method   string `json:"method"`
	Path     string `json:"path"`
	Type     string `json:"type,omitempty"`
	Start    string `json:"start,omitempty"`
	End      string `json:"end,omitempty"`
	Interval string `json:"interval,omitempty"`
	// Count is how many items the response held (samples, statistics,
	// days, writes, changes), or 1 for a submitted write.
	Count   *int   `json:"count,omitempty"`
	WriteID string `json:"writeId,omitempty"`
	Status  int    `json:"status"`
}

// RecordActivity stores a request made at at by credential id.
func (s *Store) RecordActivity(ctx context.Context, id string, at time.Time, a Activity) error {
	a.At = FormatTime(at)
	body, err := json.Marshal(a)
	if err != nil {
		return err
	}
	_, err = s.db.ExecContext(ctx,
		`INSERT INTO key_activity(credential_id, at, body) VALUES(?, ?, ?)`, id, at.UnixMilli(), string(body))
	return err
}

// PruneActivity deletes entries older than ActivityRetention.
func (s *Store) PruneActivity(ctx context.Context) (int64, error) {
	res, err := s.db.ExecContext(ctx,
		`DELETE FROM key_activity WHERE at < ?`, s.now().Add(-ActivityRetention).UnixMilli())
	if err != nil {
		return 0, err
	}
	return res.RowsAffected()
}

// ActivityCursor is the position after the last entry of a page.
type ActivityCursor int64

func (c ActivityCursor) Encode() string { return strconv.FormatInt(int64(c), 10) }

func DecodeActivityCursor(v string) (ActivityCursor, error) {
	n, err := strconv.ParseInt(v, 10, 64)
	if err != nil || n < 1 {
		return 0, invalid("invalid cursor")
	}
	return ActivityCursor(n), nil
}

// KeyActivity returns a key's entries, newest first, before the cursor
// (nil for the newest). The returned cursor is nil on the last page.
func (s *Store) KeyActivity(ctx context.Context, id string, limit int, before *ActivityCursor) ([]json.RawMessage, *ActivityCursor, error) {
	var exists int
	err := s.db.QueryRowContext(ctx, `SELECT 1 FROM credentials WHERE id = ?`, id).Scan(&exists)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil, ErrNotFound
	}
	if err != nil {
		return nil, nil, err
	}
	var bound any
	if before != nil {
		bound = int64(*before)
	}
	rows, err := s.db.QueryContext(ctx,
		`SELECT seq, body FROM key_activity WHERE credential_id = ? AND (? IS NULL OR seq < ?)
		 ORDER BY seq DESC LIMIT ?`, id, bound, bound, limit+1)
	if err != nil {
		return nil, nil, err
	}
	defer rows.Close()
	out := []json.RawMessage{}
	var last int64
	var more bool
	for rows.Next() {
		if len(out) == limit {
			more = true
			break
		}
		var body string
		if err := rows.Scan(&last, &body); err != nil {
			return nil, nil, err
		}
		out = append(out, json.RawMessage(body))
	}
	if err := rows.Err(); err != nil {
		return nil, nil, err
	}
	if more {
		c := ActivityCursor(last)
		return out, &c, nil
	}
	return out, nil, nil
}
