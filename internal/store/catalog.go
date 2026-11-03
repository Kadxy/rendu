package store

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
)

// The phone's catalog: what its HealthKit supports (PUT /v1/catalog), next
// to what the SDK declares (package schema). The phone uploads it whole and
// it is stored verbatim; it describes the phone, so pairing another iPhone
// clears it and wiping the data keeps it.

// Catalog is the last upload; OS and UpdatedAt are null (nil) until the
// phone uploads one.
type Catalog struct {
	OS        *string        `json:"os"`
	Types     []CatalogEntry `json:"types"`
	UpdatedAt *string        `json:"updatedAt"`
}

// CatalogEntry is one type as the phone's HealthKit has it. Fields beyond
// these are kept as uploaded (Raw).
type CatalogEntry struct {
	Type          string            `json:"type"`
	Kind          string            `json:"kind"`
	Name          map[string]string `json:"name,omitempty"`
	Unit          string            `json:"unit,omitempty"`
	PreferredUnit string            `json:"preferredUnit,omitempty"`
	Aggregation   string            `json:"aggregation,omitempty"`
	PerObject     bool              `json:"perObject,omitempty"`
	// Raw is the entry as uploaded.
	Raw json.RawMessage `json:"-"`
}

func (e CatalogEntry) MarshalJSON() ([]byte, error) { return e.Raw, nil }

// PutCatalog replaces the catalog, given the body as uploaded, and returns
// how many types it has.
func (s *Store) PutCatalog(ctx context.Context, body json.RawMessage) (int, error) {
	var c struct {
		OS    *string           `json:"os"`
		Types []json.RawMessage `json:"types"`
	}
	if json.Unmarshal(body, &c) != nil {
		return 0, invalid("the catalog must be an object")
	}
	if c.OS == nil || *c.OS == "" {
		return 0, invalid("os must be a non-empty string")
	}
	if len(c.Types) == 0 {
		return 0, invalid("types must be a non-empty array")
	}
	for i, raw := range c.Types {
		var head struct {
			Type *string `json:"type"`
			Kind *string `json:"kind"`
		}
		if _, ok := objectOf(raw); !ok || json.Unmarshal(raw, &head) != nil || head.Type == nil || head.Kind == nil || *head.Type == "" || *head.Kind == "" {
			return 0, invalid("types[%d] must be an object with type and kind strings", i)
		}
	}
	compact, err := compactJSON(body)
	if err != nil {
		return 0, invalid("the catalog: %v", err)
	}
	_, err = s.db.ExecContext(ctx,
		`INSERT INTO catalog(id, body, updated_at) VALUES(1, ?, ?)
		 ON CONFLICT(id) DO UPDATE SET body = excluded.body, updated_at = excluded.updated_at`,
		string(compact), s.now().UnixMilli())
	return len(c.Types), err
}

// Catalog returns the last upload, with its types in the order uploaded.
func (s *Store) Catalog(ctx context.Context) (Catalog, error) {
	c := Catalog{Types: []CatalogEntry{}}
	var body string
	var updated int64
	err := s.db.QueryRowContext(ctx, `SELECT body, updated_at FROM catalog WHERE id = 1`).Scan(&body, &updated)
	if errors.Is(err, sql.ErrNoRows) {
		return c, nil
	}
	if err != nil {
		return c, err
	}
	var stored struct {
		OS    string            `json:"os"`
		Types []json.RawMessage `json:"types"`
	}
	if err := json.Unmarshal([]byte(body), &stored); err != nil {
		return c, err
	}
	for _, raw := range stored.Types {
		var e CatalogEntry
		// A field of another shape than expected is skipped (it stays in
		// Raw); type and kind were checked on upload.
		_ = json.Unmarshal(raw, &e)
		e.Raw = raw
		c.Types = append(c.Types, e)
	}
	at := FormatTime(fromMillis(updated))
	c.OS, c.UpdatedAt = &stored.OS, &at
	return c, nil
}
