package store

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"strconv"
	"strings"
)

// The change feed, HKAnchoredObjectQuery-style: every insert, change and
// deletion of a sample takes the next value of a counter (kv changeSeq)
// inside the ingest transaction and stores it in samples.change_seq, so
// "what changed after position n" is an index range. A changed sample moves
// to its new position (and reappears to readers past its old one); a
// deleted one keeps its row, at the position of its deletion, until the
// data is wiped. Statistics and activity summaries aren't in the feed.
//
// Anchors are opaque to clients: the dataId plus a position. The dataId
// makes one from before DELETE /v1/data recognizably expired, instead of
// silently skipping what was uploaded since.

// ErrAnchorExpired: the anchor is from before the server's data was wiped.
var ErrAnchorExpired = errors.New("anchor expired: the server's data was cleared; start again without an anchor")

// DeletedObject is a sample deleted in Health (HKDeletedObject).
type DeletedObject struct {
	UUID string `json:"uuid"`
	Type string `json:"type"`
}

// Changes is one page of the feed.
type Changes struct {
	Samples []json.RawMessage `json:"samples"`
	Deleted []DeletedObject   `json:"deleted"`
	// Anchor is where the next request continues: after the last change
	// returned, or at the newest change when this page reached it.
	Anchor string `json:"anchor"`
	// More reports changes past Anchor that didn't fit in this page.
	More bool `json:"more"`
}

// Empty reports whether the page has no changes.
func (c Changes) Empty() bool { return len(c.Samples) == 0 && len(c.Deleted) == 0 }

func encodeChangeAnchor(dataID string, seq int64) string {
	return base64.RawURLEncoding.EncodeToString([]byte(dataID + ":" + strconv.FormatInt(seq, 10)))
}

func decodeChangeAnchor(v string) (dataID string, seq int64, err error) {
	b, err := base64.RawURLEncoding.DecodeString(v)
	if err != nil {
		return "", 0, invalid("invalid anchor")
	}
	dataID, n, ok := strings.Cut(string(b), ":")
	seq, err = strconv.ParseInt(n, 10, 64)
	if !ok || err != nil || dataID == "" || seq < 0 {
		return "", 0, invalid("invalid anchor")
	}
	return dataID, seq, nil
}

func changeSeq(ctx context.Context, q querier) (int64, error) {
	var seq int64
	err := q.QueryRowContext(ctx,
		`SELECT COALESCE((SELECT CAST(value AS INTEGER) FROM kv WHERE key = 'changeSeq'), 0)`).Scan(&seq)
	return seq, err
}

// Changes returns up to limit changes after anchor ("" for the beginning),
// ordered by change, optionally only of types. limit 0 returns no changes,
// just the anchor of the newest one.
func (s *Store) Changes(ctx context.Context, anchor string, types []string, limit int) (Changes, error) {
	res := Changes{Samples: []json.RawMessage{}, Deleted: []DeletedObject{}}
	dataID, err := s.getKV(ctx, "dataId")
	if err != nil {
		return res, err
	}
	var after int64
	if anchor != "" {
		id, seq, err := decodeChangeAnchor(anchor)
		if err != nil {
			return res, err
		}
		if id != dataID {
			return res, ErrAnchorExpired
		}
		after = seq
	}
	// The counter is read first: it commits with the rows it numbers, so
	// every change up to head is visible below, and one committing after
	// this read lands past head, where the next request finds it.
	head, err := changeSeq(ctx, s.db)
	if err != nil {
		return res, err
	}
	head = max(head, after)
	res.Anchor = encodeChangeAnchor(dataID, head)
	if limit == 0 || head == after {
		return res, nil
	}

	where := `change_seq > ? AND change_seq <= ?`
	args := []any{after, head}
	if len(types) > 0 {
		where += ` AND type IN (?` + strings.Repeat(`, ?`, len(types)-1) + `)`
		for _, t := range types {
			args = append(args, t)
		}
	}
	rows, err := s.db.QueryContext(ctx,
		`SELECT change_seq, uuid, type, deleted_at IS NOT NULL, body FROM samples
		 WHERE `+where+` ORDER BY change_seq LIMIT ?`, append(args, limit+1)...)
	if err != nil {
		return res, err
	}
	defer rows.Close()
	n := 0
	var last int64
	for rows.Next() {
		if n == limit {
			res.More = true
			break
		}
		var seq int64
		var uuid, typ, body string
		var deleted bool
		if err := rows.Scan(&seq, &uuid, &typ, &deleted, &body); err != nil {
			return res, err
		}
		if deleted {
			res.Deleted = append(res.Deleted, DeletedObject{UUID: uuid, Type: typ})
		} else {
			res.Samples = append(res.Samples, json.RawMessage(body))
		}
		last = seq
		n++
	}
	if err := rows.Err(); err != nil {
		return res, err
	}
	if res.More {
		res.Anchor = encodeChangeAnchor(dataID, last)
	}
	return res, nil
}
