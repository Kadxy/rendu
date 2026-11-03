package store

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
)

// The user's medication list (HKUserAnnotatedMedication, iOS 26). They
// aren't samples: the phone uploads the whole list, stored verbatim; dose
// events are ordinary samples that refer to it by id.

// Medications is the last uploaded list; UpdatedAt is null (nil) until the
// phone uploads one.
type Medications struct {
	Medications []json.RawMessage `json:"medications"`
	UpdatedAt   *string           `json:"updatedAt"`
}

// PutMedications replaces the list and returns its length.
func (s *Store) PutMedications(ctx context.Context, items []json.RawMessage) (int, error) {
	if items == nil {
		return 0, invalid("medications must be an array")
	}
	for i, raw := range items {
		var obj map[string]json.RawMessage
		if err := json.Unmarshal(raw, &obj); err != nil || obj == nil {
			return 0, invalid("medications[%d] must be an object", i)
		}
	}
	body, err := json.Marshal(items)
	if err != nil {
		return 0, err
	}
	body, err = compactJSON(body)
	if err != nil {
		return 0, err
	}
	_, err = s.db.ExecContext(ctx,
		`INSERT INTO medications(id, body, updated_at) VALUES(1, ?, ?)
		 ON CONFLICT(id) DO UPDATE SET body = excluded.body, updated_at = excluded.updated_at`,
		string(body), s.now().UnixMilli())
	return len(items), err
}

func (s *Store) Medications(ctx context.Context) (Medications, error) {
	m := Medications{Medications: []json.RawMessage{}}
	var body string
	var updated int64
	err := s.db.QueryRowContext(ctx, `SELECT body, updated_at FROM medications WHERE id = 1`).Scan(&body, &updated)
	if errors.Is(err, sql.ErrNoRows) {
		return m, nil
	}
	if err != nil {
		return m, err
	}
	if err := json.Unmarshal([]byte(body), &m.Medications); err != nil {
		return m, err
	}
	at := FormatTime(fromMillis(updated))
	m.UpdatedAt = &at
	return m, nil
}
