package store

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
)

// The phone's write ("share") authorization per type, as HealthKit reports
// it to the app (HKAuthorizationStatus), so a write the phone can't execute
// is refused when it's submitted rather than failing later. A type missing
// from the map is one HealthKit doesn't let third-party apps write. The
// phone uploads the whole map; pairing another iPhone clears it, wiping the
// data keeps it.

const (
	SharingAuthorized = "sharingAuthorized"
	SharingDenied     = "sharingDenied"
	NotDetermined     = "notDetermined"
)

// UnwritableError marks a write that HealthKit, or the user's Health
// settings, won't let the phone execute; the HTTP layer maps it to 422.
type UnwritableError struct{ Msg string }

func (e *UnwritableError) Error() string { return e.Msg }

// Authorization is the last uploaded map; both fields are null (nil) until
// the phone uploads one.
type Authorization struct {
	Share     map[string]string `json:"share"`
	UpdatedAt *string           `json:"updatedAt"`
}

// PutAuthorization replaces the map.
func (s *Store) PutAuthorization(ctx context.Context, share map[string]string) error {
	for typ, status := range share {
		if typ == "" {
			return invalid("share: empty type")
		}
		if status != SharingAuthorized && status != SharingDenied && status != NotDetermined {
			return invalid("share.%s must be sharingAuthorized, sharingDenied or notDetermined", typ)
		}
	}
	body, err := json.Marshal(share)
	if err != nil {
		return err
	}
	_, err = s.db.ExecContext(ctx,
		`INSERT INTO share_authorization(id, body, updated_at) VALUES(1, ?, ?)
		 ON CONFLICT(id) DO UPDATE SET body = excluded.body, updated_at = excluded.updated_at`,
		string(body), s.now().UnixMilli())
	return err
}

// Authorization returns the map and when it was uploaded.
func (s *Store) Authorization(ctx context.Context) (Authorization, error) {
	return s.authorization(ctx, s.db)
}

func (s *Store) authorization(ctx context.Context, q querier) (Authorization, error) {
	var a Authorization
	var body string
	var updated int64
	err := q.QueryRowContext(ctx, `SELECT body, updated_at FROM share_authorization WHERE id = 1`).Scan(&body, &updated)
	if errors.Is(err, sql.ErrNoRows) {
		return a, nil
	}
	if err != nil {
		return a, err
	}
	if err := json.Unmarshal([]byte(body), &a.Share); err != nil {
		return a, err
	}
	if a.Share == nil {
		a.Share = map[string]string{}
	}
	at := FormatTime(fromMillis(updated))
	a.UpdatedAt = &at
	return a, nil
}

// checkShare refuses a write touching types the phone can't write, when
// the phone has reported its authorization. Correlations aren't authorized
// themselves, only their members. notDetermined passes: the write waits
// until the user allows the type on the phone.
func (s *Store) checkShare(ctx context.Context, q querier, types []string) error {
	auth, err := s.authorization(ctx, q)
	if err != nil || auth.Share == nil {
		return err
	}
	var checked []string
	for _, t := range types {
		if !strings.HasPrefix(t, correlationPrefix) {
			checked = append(checked, t)
		}
	}
	for _, t := range checked {
		if _, ok := auth.Share[t]; !ok {
			return &UnwritableError{fmt.Sprintf("HealthKit doesn't allow apps to write %s", t)}
		}
	}
	for _, t := range checked {
		if auth.Share[t] == SharingDenied {
			return &UnwritableError{fmt.Sprintf("write access to %s is turned off for Rendu in Apple Health settings", t)}
		}
	}
	return nil
}
