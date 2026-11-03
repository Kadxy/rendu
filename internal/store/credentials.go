package store

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"errors"
	"math/big"
	"strings"
	"time"
)

// Credentials are bearer keys, stored only as SHA-256 hashes: a leaked
// database exposes the data of that moment, never lasting access. Keys are
// 256-bit random, so a fast hash is enough.
//
// Scopes:
//   - owner: the paired iPhone, at most one. Uploads, the write queue,
//     wiping, managing keys, and everything a read+write key can do. Its key
//     is generated on the phone and never leaves it.
//   - read: the read endpoints.
//   - readwrite: read, plus submitting write requests.
type Scope string

const (
	ScopeOwner     Scope = "owner"
	ScopeRead      Scope = "read"
	ScopeReadWrite Scope = "readwrite"
)

// Allows reports whether a credential of scope s may use an endpoint that
// needs need.
func (s Scope) Allows(need Scope) bool {
	switch s {
	case ScopeOwner:
		return true
	case ScopeReadWrite:
		return need == ScopeRead || need == ScopeReadWrite
	case ScopeRead:
		return need == ScopeRead
	}
	return false
}

// Credential is a key as listed to the owner (never the key itself).
type Credential struct {
	ID         string `json:"id"`
	Name       string `json:"name"`
	Scope      Scope  `json:"scope"`
	CreatedAt  string `json:"createdAt"`
	LastUsedAt string `json:"lastUsedAt,omitempty"`
}

// APIKeyPrefix marks API keys. An underscore, unlike a hyphen, keeps a
// double-click selecting the whole key.
const APIKeyPrefix = "rdk_"

func hashKey(key string) string {
	sum := sha256.Sum256([]byte(key))
	return hex.EncodeToString(sum[:])
}

func randomBase62(n int) string {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	s := new(big.Int).SetBytes(b).Text(62)
	// 32 bytes take at most 43 base-62 digits; pad so every key has one length.
	return strings.Repeat("0", 43-len(s)) + s
}

// Authenticate returns the credential a bearer key belongs to.
func (s *Store) Authenticate(ctx context.Context, key string) (Credential, error) {
	var c Credential
	var created int64
	var used sql.NullInt64
	err := s.db.QueryRowContext(ctx,
		`SELECT id, name, scope, created_at, last_used_at FROM credentials WHERE hash = ?`, hashKey(key),
	).Scan(&c.ID, &c.Name, &c.Scope, &created, &used)
	if errors.Is(err, sql.ErrNoRows) {
		return c, ErrNotFound
	}
	c.CreatedAt = FormatTime(fromMillis(created))
	if used.Valid {
		c.LastUsedAt = FormatTime(fromMillis(used.Int64))
	}
	return c, err
}

// TouchCredential records when a credential was last used.
func (s *Store) TouchCredential(ctx context.Context, id string, at time.Time) error {
	_, err := s.db.ExecContext(ctx, `UPDATE credentials SET last_used_at = ? WHERE id = ?`, at.UnixMilli(), id)
	return err
}

// Credentials lists every credential, the owner first.
func (s *Store) Credentials(ctx context.Context) ([]Credential, error) {
	rows, err := s.db.QueryContext(ctx,
		`SELECT id, name, scope, created_at, last_used_at FROM credentials
		 ORDER BY scope = 'owner' DESC, created_at`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Credential{}
	for rows.Next() {
		var c Credential
		var created int64
		var used sql.NullInt64
		if err := rows.Scan(&c.ID, &c.Name, &c.Scope, &created, &used); err != nil {
			return nil, err
		}
		c.CreatedAt = FormatTime(fromMillis(created))
		if used.Valid {
			c.LastUsedAt = FormatTime(fromMillis(used.Int64))
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

// CreateAPIKey makes a read or readwrite key and returns it with its key —
// the only time the key exists in plain text.
func (s *Store) CreateAPIKey(ctx context.Context, name string, scope Scope) (Credential, string, error) {
	name = strings.TrimSpace(name)
	if name == "" || len(name) > 100 {
		return Credential{}, "", invalid("name must be 1–100 characters")
	}
	if scope != ScopeRead && scope != ScopeReadWrite {
		return Credential{}, "", invalid(`scope must be "read" or "readwrite"`)
	}
	key := APIKeyPrefix + randomBase62(32)
	now := s.now()
	c := Credential{ID: newUUID()[:8], Name: name, Scope: scope, CreatedAt: FormatTime(now)}
	_, err := s.db.ExecContext(ctx,
		`INSERT INTO credentials(id, hash, name, scope, created_at) VALUES(?, ?, ?, ?, ?)`,
		c.ID, hashKey(key), c.Name, string(c.Scope), now.UnixMilli())
	return c, key, err
}

// RevokeAPIKey deletes an API key and its activity. The owner key can't be
// revoked this way: pairing another iPhone replaces it.
func (s *Store) RevokeAPIKey(ctx context.Context, id string) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	res, err := tx.ExecContext(ctx, `DELETE FROM credentials WHERE id = ? AND scope != 'owner'`, id)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrNotFound
	}
	if _, err := tx.ExecContext(ctx, `DELETE FROM key_activity WHERE credential_id = ?`, id); err != nil {
		return err
	}
	return tx.Commit()
}

// Pairing: the phone shows a 6-digit code and holds a key it generated;
// the server's operator enters the code (StartPairing), and the phone,
// polling, presents code and key (CompletePairing). The code is accepted
// only after the operator entered it, for PairingTTL, and is voided after
// MaxPairingAttempts wrong codes, so a guess succeeds with odds of 5 in a
// million.
const (
	PairingTTL         = 5 * time.Minute
	MaxPairingAttempts = 5
)

var (
	// ErrNoPairing: no code was entered on the server, or it expired.
	ErrNoPairing = errors.New("no pairing in progress")
	// ErrWrongCode: a code was entered, but not this one.
	ErrWrongCode = errors.New("wrong pairing code")
)

// ValidPairingCode reports whether code is six digits.
func ValidPairingCode(code string) bool {
	if len(code) != 6 {
		return false
	}
	for _, r := range code {
		if r < '0' || r > '9' {
			return false
		}
	}
	return true
}

// StartPairing accepts code for PairingTTL, replacing any earlier code.
func (s *Store) StartPairing(ctx context.Context, code string) error {
	if !ValidPairingCode(code) {
		return invalid("the pairing code is six digits")
	}
	_, err := s.db.ExecContext(ctx,
		`INSERT INTO pairing(id, code, expires_at, attempts) VALUES(1, ?, ?, 0)
		 ON CONFLICT(id) DO UPDATE SET code = excluded.code, expires_at = excluded.expires_at, attempts = 0`,
		code, s.now().Add(PairingTTL).UnixMilli())
	return err
}

// PairingPending reports whether the code entered on the server still waits
// for the phone.
func (s *Store) PairingPending(ctx context.Context) (bool, error) {
	var n int
	err := s.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM pairing WHERE expires_at > ?`, s.now().UnixMilli()).Scan(&n)
	return n > 0, err
}

// CompletePairing makes key the owner key if code is the one entered on the
// server, replacing the previous owner (whose requests start failing at
// once) and using up the code. The sync progress starts over with the new
// iPhone (anchors.go), and its write authorization and catalog are unknown
// until it uploads them (authorization.go, catalog.go).
func (s *Store) CompletePairing(ctx context.Context, code, key string) (Credential, error) {
	if len(key) < 43 || len(key) > 128 || strings.ContainsFunc(key, func(r rune) bool { return r <= ' ' || r > '~' }) {
		return Credential{}, invalid("the key must be 43–128 printable characters")
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return Credential{}, err
	}
	defer tx.Rollback()
	var want string
	var attempts int
	err = tx.QueryRowContext(ctx, `SELECT code, attempts FROM pairing WHERE id = 1 AND expires_at > ?`,
		s.now().UnixMilli()).Scan(&want, &attempts)
	if errors.Is(err, sql.ErrNoRows) {
		return Credential{}, ErrNoPairing
	}
	if err != nil {
		return Credential{}, err
	}
	if code != want {
		if attempts+1 >= MaxPairingAttempts {
			_, err = tx.ExecContext(ctx, `DELETE FROM pairing`)
		} else {
			_, err = tx.ExecContext(ctx, `UPDATE pairing SET attempts = attempts + 1`)
		}
		if err != nil {
			return Credential{}, err
		}
		if err := tx.Commit(); err != nil {
			return Credential{}, err
		}
		return Credential{}, ErrWrongCode
	}
	now := s.now()
	c := Credential{ID: newUUID()[:8], Name: "iPhone", Scope: ScopeOwner, CreatedAt: FormatTime(now)}
	for _, q := range []struct {
		sql  string
		args []any
	}{
		{`DELETE FROM credentials WHERE scope = 'owner'`, nil},
		{`INSERT INTO credentials(id, hash, name, scope, created_at) VALUES(?, ?, ?, ?, ?)`,
			[]any{c.ID, hashKey(key), c.Name, string(c.Scope), now.UnixMilli()}},
		{`DELETE FROM pairing`, nil},
		{`DELETE FROM sync_anchors`, nil},
		{`DELETE FROM share_authorization`, nil},
		{`DELETE FROM catalog`, nil},
	} {
		if _, err := tx.ExecContext(ctx, q.sql, q.args...); err != nil {
			return Credential{}, err
		}
	}
	return c, tx.Commit()
}

// Owner returns the paired iPhone's credential, if any.
func (s *Store) Owner(ctx context.Context) (Credential, error) {
	creds, err := s.Credentials(ctx)
	if err != nil {
		return Credential{}, err
	}
	for _, c := range creds {
		if c.Scope == ScopeOwner {
			return c, nil
		}
	}
	return Credential{}, ErrNotFound
}
