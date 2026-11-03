package store

import (
	"context"
	"database/sql"
	"errors"
)

// The paired iPhone's sync progress per type: the HealthKit query anchor
// (opaque, base64) up to which the server holds the phone's samples. It is
// stored in the same transaction as the samples it covers, so it always
// says what the server really has; the phone reads it before each pass and
// continues from there. Pairing an iPhone clears it: anchors belong to one
// phone's Health database, so a newly paired phone uploads everything once
// (the server dedupes by uuid).

// AnchorUpdate asks Ingest to move a type's anchor from Base to New along
// with the batch. Base "" means "no anchor yet".
type AnchorUpdate struct {
	Type, Base, New string
}

const (
	// AnchorSaved: the server's anchor was Base and is now New.
	AnchorSaved = "saved"
	// AnchorStale: the server's anchor wasn't Base (its data was wiped or
	// restored, or the batch was read from an older state); it is left as
	// is and the phone continues from it on its next pass.
	AnchorStale = "stale"
)

func (s *Store) updateAnchor(ctx context.Context, tx *sql.Tx, u AnchorUpdate) (string, error) {
	var stored string
	err := tx.QueryRowContext(ctx, `SELECT anchor FROM sync_anchors WHERE type = ?`, u.Type).Scan(&stored)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return "", err
	}
	if stored == u.New {
		// The same batch again (its reply was lost and the phone retried):
		// already where it leads.
		return AnchorSaved, nil
	}
	if stored != u.Base {
		return AnchorStale, nil
	}
	_, err = tx.ExecContext(ctx,
		`INSERT INTO sync_anchors(type, anchor, updated_at) VALUES(?, ?, ?)
		 ON CONFLICT(type) DO UPDATE SET anchor = excluded.anchor, updated_at = excluded.updated_at`,
		u.Type, u.New, s.now().UnixMilli())
	if err != nil {
		return "", err
	}
	return AnchorSaved, nil
}

// Anchors returns the sync progress by type.
func (s *Store) Anchors(ctx context.Context) (map[string]string, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT type, anchor FROM sync_anchors`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[string]string{}
	for rows.Next() {
		var typ, anchor string
		if err := rows.Scan(&typ, &anchor); err != nil {
			return nil, err
		}
		out[typ] = anchor
	}
	return out, rows.Err()
}

// ReplaceAnchors sets the sync progress to exactly these (none to start
// over).
func (s *Store) ReplaceAnchors(ctx context.Context, anchors map[string]string) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err := tx.ExecContext(ctx, `DELETE FROM sync_anchors`); err != nil {
		return err
	}
	now := s.now().UnixMilli()
	for typ, anchor := range anchors {
		if typ == "" || anchor == "" {
			return invalid("anchors: empty type or anchor")
		}
		if _, err := tx.ExecContext(ctx,
			`INSERT INTO sync_anchors(type, anchor, updated_at) VALUES(?, ?, ?)`, typ, anchor, now); err != nil {
			return err
		}
	}
	return tx.Commit()
}
