package store

import (
	"context"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"
)

const syncIdentifierKey = "HKMetadataKeySyncIdentifier"

// element is the subset of an /ingest element the server indexes; the full
// body is stored verbatim.
type element struct {
	UUID           string `json:"uuid"`
	Kind           string `json:"kind"`
	Type           string `json:"type"`
	StartDate      string `json:"startDate"`
	EndDate        string `json:"endDate"`
	SourceRevision *struct {
		Source *struct {
			BundleIdentifier string `json:"bundleIdentifier"`
		} `json:"source"`
	} `json:"sourceRevision"`
	Metadata map[string]json.RawMessage `json:"metadata"`
	Deleted  *[]string                  `json:"deleted"`
}

type IngestResult struct {
	Received int `json:"received"`
	New      int `json:"new"`
	Deleted  int `json:"deleted"`
	// Rejected counts malformed elements that were skipped. Rejecting the
	// whole batch instead would wedge the app's FIFO outbox forever.
	Rejected int `json:"rejected,omitempty"`
	// Anchor is the outcome of the batch's anchor update (AnchorSaved or
	// AnchorStale); empty when the batch carried none.
	Anchor string `json:"anchor,omitempty"`
}

type parsedSample struct {
	el      element
	startMs int64
	endMs   int64
	source  string
	syncID  string
	body    json.RawMessage
}

func parseSample(raw json.RawMessage, el element) (parsedSample, error) {
	if el.UUID == "" || el.Kind == "" || el.Type == "" {
		return parsedSample{}, errors.New("uuid, kind and type are required")
	}
	start, err := ParseTimestamp(el.StartDate)
	if err != nil {
		return parsedSample{}, fmt.Errorf("startDate: %w", err)
	}
	end, err := ParseTimestamp(el.EndDate)
	if err != nil {
		return parsedSample{}, fmt.Errorf("endDate: %w", err)
	}
	body, err := compactJSON(raw)
	if err != nil {
		return parsedSample{}, err
	}
	p := parsedSample{el: el, startMs: start.UnixMilli(), endMs: end.UnixMilli(), body: body}
	if el.SourceRevision != nil && el.SourceRevision.Source != nil {
		p.source = el.SourceRevision.Source.BundleIdentifier
	}
	if v, ok := el.Metadata[syncIdentifierKey]; ok {
		_ = json.Unmarshal(v, &p.syncID)
	}
	return p, nil
}

// Ingest stores a batch of samples and tombstones in one transaction, and
// moves the phone's anchor with it when the batch carries one (see
// anchors.go). Samples are upserted by uuid (delivery is at-least-once).
// Every insert, change and deletion takes the next position in the change
// feed (changes.go).
func (s *Store) Ingest(ctx context.Context, elements []json.RawMessage, anchor *AnchorUpdate) (IngestResult, error) {
	res := IngestResult{Received: len(elements)}
	now := s.now()
	nowMs := now.UnixMilli()

	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return res, err
	}
	defer tx.Rollback()

	seq, err := changeSeq(ctx, tx)
	if err != nil {
		return res, err
	}
	startSeq := seq

	// Prepared once per batch: a batch is up to 20k samples, and preparing
	// per row was most of the cost.
	stmts, err := prepareAll(ctx, tx, map[string]string{
		"tombstone":   `INSERT INTO deletions(uuid, deleted_at) VALUES(?, ?) ON CONFLICT(uuid) DO NOTHING`,
		"markDeleted": `UPDATE samples SET deleted_at = ?, change_seq = ? WHERE uuid = ? AND deleted_at IS NULL`,
		// A sample whose tombstone arrived first is stored as deleted, and
		// outside the feed: no reader ever saw it.
		"insert": `INSERT INTO samples(uuid, type, kind, start_ms, end_ms, source_bundle_id, sync_identifier, body, received_at, deleted_at, change_seq)
			 VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, (SELECT deleted_at FROM deletions WHERE uuid = ?1),
			   CASE WHEN EXISTS (SELECT 1 FROM deletions WHERE uuid = ?1) THEN NULL ELSE ?10 END)
			 ON CONFLICT(uuid) DO NOTHING`,
		// Re-delivery: refresh a changed body (never resurrecting a deleted
		// sample, which also stays where it left the feed); an unchanged
		// one — every sample of a re-import — writes nothing.
		"refresh": `UPDATE samples SET type = ?1, kind = ?2, start_ms = ?3, end_ms = ?4, source_bundle_id = ?5,
			 sync_identifier = ?6, body = ?7, change_seq = CASE WHEN deleted_at IS NULL THEN ?9 ELSE change_seq END
			 WHERE uuid = ?8 AND body IS NOT ?7`,
	})
	if err != nil {
		return res, err
	}
	defer func() {
		for _, st := range stmts {
			st.Close()
		}
	}()

	// changed advances the feed position when a statement touched a row.
	changed := func(r sql.Result) {
		if n, _ := r.RowsAffected(); n > 0 {
			seq++
		}
	}
	maxDur := map[string]int64{}
	kinds := map[string]string{}
	for _, raw := range elements {
		var el element
		if err := json.Unmarshal(raw, &el); err != nil {
			res.Rejected++
			continue
		}
		if el.Deleted != nil {
			for _, uuid := range *el.Deleted {
				if uuid == "" {
					continue
				}
				if _, err := stmts["tombstone"].ExecContext(ctx, uuid, nowMs); err != nil {
					return res, err
				}
				r, err := stmts["markDeleted"].ExecContext(ctx, nowMs, seq+1, uuid)
				if err != nil {
					return res, err
				}
				changed(r)
				res.Deleted++
			}
			continue
		}

		p, err := parseSample(raw, el)
		if err != nil {
			res.Rejected++
			continue
		}
		r, err := stmts["insert"].ExecContext(ctx,
			el.UUID, el.Type, el.Kind, p.startMs, p.endMs, nullable(p.source), nullable(p.syncID),
			string(p.body), nowMs, seq+1)
		if err != nil {
			return res, err
		}
		if n, _ := r.RowsAffected(); n == 1 {
			seq++
			res.New++
		} else {
			r, err := stmts["refresh"].ExecContext(ctx,
				el.Type, el.Kind, p.startMs, p.endMs, nullable(p.source), nullable(p.syncID),
				string(p.body), el.UUID, seq+1)
			if err != nil {
				return res, err
			}
			changed(r)
		}
		d := max(p.endMs-p.startMs, 0)
		if cur, ok := maxDur[el.Type]; !ok || d > cur {
			maxDur[el.Type] = d
		}
		kinds[el.Type] = el.Kind
	}

	for typ, d := range maxDur {
		if _, err := tx.ExecContext(ctx,
			`INSERT INTO sample_types(type, kind, max_duration_ms) VALUES(?, ?, ?)
			 ON CONFLICT(type) DO UPDATE SET kind = excluded.kind,
			 max_duration_ms = MAX(max_duration_ms, excluded.max_duration_ms)`,
			typ, kinds[typ], d); err != nil {
			return res, err
		}
	}
	if seq != startSeq {
		if err := s.setKV(ctx, tx, "changeSeq", strconv.FormatInt(seq, 10)); err != nil {
			return res, err
		}
	}
	if err := s.setKV(ctx, tx, "lastIngestAt", FormatTime(now)); err != nil {
		return res, err
	}
	if anchor != nil {
		if res.Anchor, err = s.updateAnchor(ctx, tx, *anchor); err != nil {
			return res, err
		}
	}
	return res, tx.Commit()
}

// Latest maps each type to the endDate (as received) of its newest live sample.
func (s *Store) Latest(ctx context.Context) (map[string]string, error) {
	// SQLite returns the bare json_extract column from the row holding MAX().
	rows, err := s.db.QueryContext(ctx,
		`SELECT type, MAX(end_ms), json_extract(body, '$.endDate')
		 FROM samples WHERE deleted_at IS NULL GROUP BY type`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[string]string{}
	for rows.Next() {
		var typ, end string
		var ms int64
		if err := rows.Scan(&typ, &ms, &end); err != nil {
			return nil, err
		}
		out[typ] = end
	}
	return out, rows.Err()
}

type TypeInfo struct {
	Type           string `json:"type"`
	Kind           string `json:"kind"`
	Count          int64  `json:"count"`
	FirstStartDate string `json:"firstStartDate"`
	LastEndDate    string `json:"lastEndDate"`
	// Share is the type's write authorization when the phone reported it
	// (authorization.go).
	Share string `json:"share,omitempty"`
}

// HasType reports whether the server holds samples or statistics of typ,
// or ever did.
func (s *Store) HasType(ctx context.Context, typ string) (bool, error) {
	var has bool
	err := s.db.QueryRowContext(ctx,
		`SELECT EXISTS(SELECT 1 FROM sample_types WHERE type = ?) OR EXISTS(SELECT 1 FROM statistics WHERE type = ?)`,
		typ, typ).Scan(&has)
	return has, err
}

func (s *Store) Types(ctx context.Context) ([]TypeInfo, error) {
	auth, err := s.Authorization(ctx)
	if err != nil {
		return nil, err
	}
	rows, err := s.db.QueryContext(ctx,
		`SELECT t.type, t.kind,
		   (SELECT COUNT(*) FROM samples WHERE type = t.type AND deleted_at IS NULL),
		   (SELECT MIN(start_ms) FROM samples WHERE type = t.type AND deleted_at IS NULL),
		   (SELECT MAX(end_ms) FROM samples WHERE type = t.type AND deleted_at IS NULL)
		 FROM sample_types t ORDER BY t.type`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []TypeInfo{}
	for rows.Next() {
		var ti TypeInfo
		var first, last sql.NullInt64
		if err := rows.Scan(&ti.Type, &ti.Kind, &ti.Count, &first, &last); err != nil {
			return nil, err
		}
		if ti.Count == 0 {
			continue
		}
		ti.FirstStartDate = FormatTime(fromMillis(first.Int64))
		ti.LastEndDate = FormatTime(fromMillis(last.Int64))
		ti.Share = auth.Share[ti.Type]
		out = append(out, ti)
	}
	return out, rows.Err()
}

// Cursor is the position after the last returned sample.
type Cursor struct {
	StartMs int64
	UUID    string
}

func (c Cursor) Encode() string {
	return base64.RawURLEncoding.EncodeToString([]byte(strconv.FormatInt(c.StartMs, 10) + ":" + c.UUID))
}

func DecodeCursor(v string) (Cursor, error) {
	b, err := base64.RawURLEncoding.DecodeString(v)
	if err != nil {
		return Cursor{}, invalid("invalid cursor")
	}
	ms, uuid, ok := strings.Cut(string(b), ":")
	n, err := strconv.ParseInt(ms, 10, 64)
	if !ok || err != nil || uuid == "" {
		return Cursor{}, invalid("invalid cursor")
	}
	return Cursor{StartMs: n, UUID: uuid}, nil
}

type SampleQuery struct {
	Type       string
	Start, End *time.Time
	Source     string
	Limit      int
	After      *Cursor
	// Desc returns the newest samples first (the app's sample browser).
	Desc bool
}

// QuerySamples returns live samples overlapping [Start, End), ordered by
// startDate (newest first with Desc). The returned cursor is nil on the
// last page.
func (s *Store) QuerySamples(ctx context.Context, q SampleQuery) ([]json.RawMessage, *Cursor, error) {
	where := []string{"type = ?", "deleted_at IS NULL"}
	args := []any{q.Type}
	if q.End != nil {
		where = append(where, "start_ms < ?")
		args = append(args, q.End.UnixMilli())
	}
	if q.Start != nil {
		var maxDur int64
		err := s.db.QueryRowContext(ctx, `SELECT max_duration_ms FROM sample_types WHERE type = ?`, q.Type).Scan(&maxDur)
		if err != nil && !errors.Is(err, sql.ErrNoRows) {
			return nil, nil, err
		}
		startMs := q.Start.UnixMilli()
		// No sample is longer than maxDur, so this lower bound is exact and
		// lets SQLite range-scan the start index. The OR keeps point samples
		// that sit exactly on Start.
		where = append(where, "start_ms >= ?", "(end_ms > ? OR start_ms >= ?)")
		args = append(args, startMs-maxDur, startMs, startMs)
	}
	if q.Source != "" {
		where = append(where, "source_bundle_id = ?")
		args = append(args, q.Source)
	}
	order, after := "start_ms, uuid", "(start_ms > ? OR (start_ms = ? AND uuid > ?))"
	if q.Desc {
		order, after = "start_ms DESC, uuid DESC", "(start_ms < ? OR (start_ms = ? AND uuid < ?))"
	}
	if q.After != nil {
		where = append(where, after)
		args = append(args, q.After.StartMs, q.After.StartMs, q.After.UUID)
	}
	args = append(args, q.Limit+1)
	rows, err := s.db.QueryContext(ctx,
		`SELECT uuid, start_ms, body FROM samples WHERE `+strings.Join(where, " AND ")+
			` ORDER BY `+order+` LIMIT ?`, args...)
	if err != nil {
		return nil, nil, err
	}
	defer rows.Close()
	samples := []json.RawMessage{}
	var last Cursor
	var more bool
	for rows.Next() {
		if len(samples) == q.Limit {
			more = true
			break
		}
		var body string
		if err := rows.Scan(&last.UUID, &last.StartMs, &body); err != nil {
			return nil, nil, err
		}
		samples = append(samples, json.RawMessage(body))
	}
	if err := rows.Err(); err != nil {
		return nil, nil, err
	}
	if more {
		return samples, &last, nil
	}
	return samples, nil, nil
}

func prepareAll(ctx context.Context, tx *sql.Tx, queries map[string]string) (map[string]*sql.Stmt, error) {
	stmts := make(map[string]*sql.Stmt, len(queries))
	for name, q := range queries {
		st, err := tx.PrepareContext(ctx, q) //nolint:sqlclosecheck // returned; the caller closes them
		if err != nil {
			for _, prepared := range stmts {
				prepared.Close()
			}
			return nil, err
		}
		stmts[name] = st
	}
	return stmts, nil
}
