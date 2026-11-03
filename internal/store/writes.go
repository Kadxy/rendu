package store

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"slices"
	"strconv"
)

const (
	OpSave   = "save"
	OpDelete = "delete"

	StatusPending  = "pending"
	StatusWritten  = "written"
	StatusFailed   = "failed"
	StatusConflict = "conflict"
)

func ValidStatus(v string) bool {
	switch v {
	case StatusPending, StatusWritten, StatusFailed, StatusConflict:
		return true
	}
	return false
}

// Submitter is the credential that submitted a write, with its name at
// the time (so it survives revocation and renaming).
type Submitter struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}

type Write struct {
	ID             string          `json:"id"`
	Op             string          `json:"op"`
	SyncIdentifier string          `json:"syncIdentifier"`
	SyncVersion    *int64          `json:"syncVersion,omitempty"`
	Status         string          `json:"status"`
	CreatedAt      string          `json:"createdAt"`
	UpdatedAt      string          `json:"updatedAt"`
	SubmittedBy    *Submitter      `json:"submittedBy,omitempty"`
	Object         json.RawMessage `json:"object,omitempty"`
	UUIDs          []string        `json:"uuids,omitempty"`
	Error          string          `json:"error,omitempty"`
}

type WriteRequest struct {
	Op             string          `json:"op"`
	SyncIdentifier string          `json:"syncIdentifier"`
	Object         json.RawMessage `json:"object"`
}

type PendingWrite struct {
	ID             string          `json:"id"`
	Op             string          `json:"op"`
	SyncIdentifier string          `json:"syncIdentifier"`
	SyncVersion    *int64          `json:"syncVersion,omitempty"`
	Object         json.RawMessage `json:"object,omitempty"`
	ReplaceUUIDs   []string        `json:"replaceUUIDs"`
	ReplaceTypes   []string        `json:"replaceTypes"`
	SubmittedBy    *Submitter      `json:"submittedBy,omitempty"`
}

type WriteResult struct {
	ID     string   `json:"id"`
	Status string   `json:"status"`
	UUIDs  []string `json:"uuids"`
	Error  string   `json:"error"`
}

// WritesAnchor marks the newest write submitted: it changes with each
// submission, so whoever holds it can wait for the next one.
func (s *Store) WritesAnchor(ctx context.Context) (string, error) {
	var seq int64
	err := s.db.QueryRowContext(ctx, `SELECT COALESCE(MAX(seq), 0) FROM writes`).Scan(&seq)
	return strconv.FormatInt(seq, 10), err
}

// SubmitWrite queues a save or delete, submitted by by, for the app to
// execute. It refuses one the phone has reported it can't write
// (authorization.go).
func (s *Store) SubmitWrite(ctx context.Context, req WriteRequest, by Submitter) (Write, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return Write{}, err
	}
	defer tx.Rollback()

	var version sql.NullInt64
	var object any
	var types []string
	switch req.Op {
	case OpSave:
		if len(req.Object) == 0 || string(req.Object) == "null" {
			return Write{}, invalid("save requires an object")
		}
		if err := validateObject(req.Object, "object", topLevel); err != nil {
			return Write{}, err
		}
		body, err := compactJSON(req.Object)
		if err != nil {
			return Write{}, invalid("object: %v", err)
		}
		object = string(body)
		types = objectTypes(body)
		if req.SyncIdentifier == "" {
			req.SyncIdentifier = newUUID()
		}
		// Versions only need to grow; failed saves still consume theirs.
		// They also grow past what's in Health (HealthKit ignores a save
		// whose version is lower than the existing object's), which the
		// server no longer has writes for after its data was cleared.
		var cur int64
		if err := tx.QueryRowContext(ctx,
			`SELECT MAX(
			   (SELECT COALESCE(MAX(sync_version), 0) FROM writes WHERE sync_identifier = ?1 AND op = 'save'),
			   (SELECT COALESCE(MAX(CAST(json_extract(body, '$.metadata.HKMetadataKeySyncVersion') AS INTEGER)), 0)
			    FROM samples WHERE sync_identifier = ?1 AND deleted_at IS NULL))`,
			req.SyncIdentifier).Scan(&cur); err != nil {
			return Write{}, err
		}
		version = sql.NullInt64{Int64: cur + 1, Valid: true}
	case OpDelete:
		if req.SyncIdentifier == "" {
			return Write{}, invalid("delete requires syncIdentifier")
		}
		if len(req.Object) != 0 && string(req.Object) != "null" {
			return Write{}, invalid("delete takes no object")
		}
		// Something to delete: a write, or (the writes were cleared with
		// the server's data) an object in Health under this syncIdentifier.
		var known bool
		if err := tx.QueryRowContext(ctx,
			`SELECT EXISTS (SELECT 1 FROM writes WHERE sync_identifier = ?1)
			   OR EXISTS (SELECT 1 FROM samples WHERE sync_identifier = ?1 AND deleted_at IS NULL)`,
			req.SyncIdentifier).Scan(&known); err != nil {
			return Write{}, err
		}
		if !known {
			return Write{}, ErrNotFound
		}
		// What the delete will remove: the object of the latest save that
		// is in Health or on its way there (a later delete or conflict
		// leaves nothing); without any such write, what's in Health under
		// the syncIdentifier.
		var op, status string
		var prev []byte
		err := tx.QueryRowContext(ctx,
			`SELECT op, status, object FROM writes WHERE sync_identifier = ? AND status != 'failed'
			 ORDER BY seq DESC LIMIT 1`, req.SyncIdentifier).Scan(&op, &status, &prev)
		switch {
		case errors.Is(err, sql.ErrNoRows):
			if _, types, err = syncedObjects(ctx, tx, req.SyncIdentifier); err != nil {
				return Write{}, err
			}
		case err != nil:
			return Write{}, err
		case op == OpSave && (status == StatusPending || status == StatusWritten):
			types = objectTypes(prev)
		}
	default:
		return Write{}, invalid("op must be \"save\" or \"delete\"")
	}
	if err := s.checkShare(ctx, tx, types); err != nil {
		return Write{}, err
	}

	id := newUUID()
	now := s.now().UnixMilli()
	if _, err := tx.ExecContext(ctx,
		`INSERT INTO writes(id, op, sync_identifier, sync_version, object, status, created_at, updated_at,
		   submitted_by, submitted_by_name)
		 VALUES(?, ?, ?, ?, ?, 'pending', ?, ?, ?, ?)`,
		id, req.Op, req.SyncIdentifier, version, object, now, now, nullable(by.ID), nullable(by.Name)); err != nil {
		return Write{}, err
	}
	if err := tx.Commit(); err != nil {
		return Write{}, err
	}
	return s.GetWrite(ctx, id)
}

const writeColumns = `seq, id, op, sync_identifier, sync_version, object, status, uuids, error, created_at, updated_at,
	submitted_by, submitted_by_name`

func scanWrite(sc interface{ Scan(...any) error }) (Write, int64, error) {
	var w Write
	var seq, created, updated int64
	var version sql.NullInt64
	var object, uuids, errMsg, byID, byName sql.NullString
	if err := sc.Scan(&seq, &w.ID, &w.Op, &w.SyncIdentifier, &version, &object, &w.Status,
		&uuids, &errMsg, &created, &updated, &byID, &byName); err != nil {
		return w, 0, err
	}
	if byID.Valid {
		w.SubmittedBy = &Submitter{ID: byID.String, Name: byName.String}
	}
	if version.Valid {
		v := version.Int64
		w.SyncVersion = &v
	}
	if object.Valid {
		w.Object = json.RawMessage(object.String)
	}
	if uuids.Valid {
		_ = json.Unmarshal([]byte(uuids.String), &w.UUIDs)
	}
	w.Error = errMsg.String
	w.CreatedAt = FormatTime(fromMillis(created))
	w.UpdatedAt = FormatTime(fromMillis(updated))
	return w, seq, nil
}

func (s *Store) GetWrite(ctx context.Context, id string) (Write, error) {
	w, _, err := scanWrite(s.db.QueryRowContext(ctx, `SELECT `+writeColumns+` FROM writes WHERE id = ?`, id))
	if errors.Is(err, sql.ErrNoRows) {
		return Write{}, ErrNotFound
	}
	return w, err
}

func (s *Store) ListWrites(ctx context.Context, status, syncIdentifier string, limit int) ([]Write, error) {
	rows, err := s.db.QueryContext(ctx,
		`SELECT `+writeColumns+` FROM writes
		 WHERE (?1 = '' OR status = ?1) AND (?2 = '' OR sync_identifier = ?2)
		 ORDER BY seq DESC LIMIT ?3`, status, syncIdentifier, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Write{}
	for rows.Next() {
		w, _, err := scanWrite(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, w)
	}
	return out, rows.Err()
}

// maxPending caps one /writes/pending response; the app pulls again after
// reporting results.
const maxPending = 500

// maxPendingBytes caps the objects in one /writes/pending response (a CDA
// document can be 10 MB); at least one write is always returned.
const maxPendingBytes = 16 << 20

// PendingWrites returns the oldest pending write per syncIdentifier, so the
// app always sees an object's operations one at a time and in order.
func (s *Store) PendingWrites(ctx context.Context) ([]PendingWrite, error) {
	rows, err := s.db.QueryContext(ctx,
		`SELECT `+writeColumns+` FROM writes w
		 WHERE w.status = 'pending' AND NOT EXISTS (
		   SELECT 1 FROM writes e WHERE e.sync_identifier = w.sync_identifier
		   AND e.status = 'pending' AND e.seq < w.seq)
		 ORDER BY w.seq LIMIT ?`, maxPending)
	if err != nil {
		return nil, err
	}
	type entry struct {
		w   Write
		seq int64
	}
	var entries []entry
	// Read and closed before replaceTargets queries again.
	err = func() error {
		defer rows.Close()
		for rows.Next() {
			w, seq, err := scanWrite(rows)
			if err != nil {
				return err
			}
			entries = append(entries, entry{w, seq})
		}
		return rows.Err()
	}()
	if err != nil {
		return nil, err
	}

	out := make([]PendingWrite, 0, len(entries))
	size := 0
	for _, e := range entries {
		size += len(e.w.Object)
		if len(out) > 0 && size > maxPendingBytes {
			break
		}
		uuids, types, err := s.replaceTargets(ctx, e.w.SyncIdentifier, e.seq)
		if err != nil {
			return nil, err
		}
		out = append(out, PendingWrite{
			ID: e.w.ID, Op: e.w.Op, SyncIdentifier: e.w.SyncIdentifier,
			SyncVersion: e.w.SyncVersion, Object: e.w.Object,
			ReplaceUUIDs: uuids, ReplaceTypes: types, SubmittedBy: e.w.SubmittedBy,
		})
	}
	return out, nil
}

// replaceTargets is what currently exists in Health for the object: the
// uuids of the last effective write before seq, plus the types of that
// write's object, correlation members, workout samples and route
// (HealthKit can only look objects up by uuid within a type). A delete or
// a conflict (the user removed the object in Health) leaves nothing
// behind; failed writes never touched Health and are skipped. Without any
// effective write — the first save, or the server's data (writes included)
// was cleared since — it's what the phone uploaded under the
// syncIdentifier.
func (s *Store) replaceTargets(ctx context.Context, syncIdentifier string, seq int64) (uuids, types []string, err error) {
	var op, status string
	var uuidsJSON sql.NullString
	var object []byte
	err = s.db.QueryRowContext(ctx,
		`SELECT op, status, uuids, object FROM writes
		 WHERE sync_identifier = ? AND seq < ? AND status IN ('written', 'conflict')
		 ORDER BY seq DESC LIMIT 1`, syncIdentifier, seq).Scan(&op, &status, &uuidsJSON, &object)
	if errors.Is(err, sql.ErrNoRows) {
		return syncedObjects(ctx, s.db, syncIdentifier)
	}
	if err != nil {
		return nil, nil, err
	}
	uuids, types = []string{}, []string{}
	if op != OpSave || status != StatusWritten || !uuidsJSON.Valid {
		return uuids, types, nil
	}
	_ = json.Unmarshal([]byte(uuidsJSON.String), &uuids)
	return uuids, objectTypes(object), nil
}

// syncedObjects are the live samples the phone uploaded under a
// syncIdentifier X: the object itself (metadata HKMetadataKeySyncIdentifier
// X) first, then its correlation members and workout samples (X:<n>, in n
// order) and a workout's route (X:route). Their uuids, and their types
// deduplicated.
func syncedObjects(ctx context.Context, q querier, syncIdentifier string) (uuids, types []string, err error) {
	// [X:, X;) is every identifier that starts with "X:", as a range the
	// sync_identifier index can scan.
	rows, err := q.QueryContext(ctx,
		`SELECT uuid, type FROM samples
		 WHERE deleted_at IS NULL
		   AND (sync_identifier = ?1 OR (sync_identifier >= (?1 || ':') AND sync_identifier < (?1 || ';')))
		 ORDER BY length(sync_identifier), sync_identifier, uuid`, syncIdentifier)
	if err != nil {
		return nil, nil, err
	}
	defer rows.Close()
	uuids, types = []string{}, []string{}
	for rows.Next() {
		var uuid, typ string
		if err := rows.Scan(&uuid, &typ); err != nil {
			return nil, nil, err
		}
		uuids = append(uuids, uuid)
		if !slices.Contains(types, typ) {
			types = append(types, typ)
		}
	}
	return uuids, types, rows.Err()
}

// RecordResults finalizes pending writes. A write that already has a result
// is left alone, which makes re-reporting idempotent.
func (s *Store) RecordResults(ctx context.Context, results []WriteResult) (int, error) {
	for i, r := range results {
		if r.ID == "" {
			return 0, invalid("results[%d].id is required", i)
		}
		if r.Status != StatusWritten && r.Status != StatusFailed && r.Status != StatusConflict {
			return 0, invalid("results[%d].status must be written, failed or conflict", i)
		}
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback()
	now := s.now().UnixMilli()
	updated := 0
	for _, r := range results {
		var uuids any
		if r.Status == StatusWritten {
			list := r.UUIDs
			if list == nil {
				list = []string{}
			}
			b, _ := json.Marshal(list)
			uuids = string(b)
		}
		res, err := tx.ExecContext(ctx,
			`UPDATE writes SET status = ?, uuids = ?, error = ?, updated_at = ?
			 WHERE id = ? AND status = 'pending'`,
			r.Status, uuids, nullable(r.Error), now, r.ID)
		if err != nil {
			return 0, err
		}
		if n, _ := res.RowsAffected(); n == 1 {
			updated++
		}
	}
	return updated, tx.Commit()
}
