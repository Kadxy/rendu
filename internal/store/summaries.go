package store

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"time"
)

type StatisticsUpload struct {
	Type       string            `json:"type"`
	Interval   string            `json:"interval"`
	Unit       string            `json:"unit"`
	TimeZone   string            `json:"timeZone"`
	RangeStart string            `json:"rangeStart"`
	RangeEnd   string            `json:"rangeEnd"`
	Statistics []json.RawMessage `json:"statistics"`
}

func ValidInterval(v string) bool { return v == "hour" || v == "day" }

type bucket struct {
	StartDate string `json:"startDate"`
	EndDate   string `json:"endDate"`
}

// StoreStatistics replaces every bucket of (type, interval) whose start lies
// in [rangeStart, rangeEnd) with the uploaded ones, so buckets that lost all
// their samples disappear too.
func (s *Store) StoreStatistics(ctx context.Context, up StatisticsUpload) (int, error) {
	if up.Type == "" || up.Unit == "" {
		return 0, invalid("type and unit are required")
	}
	if !ValidInterval(up.Interval) {
		return 0, invalid("interval must be \"hour\" or \"day\"")
	}
	rs, err := ParseTimestamp(up.RangeStart)
	if err != nil {
		return 0, invalid("rangeStart: %v", err)
	}
	re, err := ParseTimestamp(up.RangeEnd)
	if err != nil {
		return 0, invalid("rangeEnd: %v", err)
	}
	if re.Before(rs) {
		return 0, invalid("rangeEnd is before rangeStart")
	}

	type row struct {
		startMs, endMs int64
		body           json.RawMessage
	}
	rows := make([]row, 0, len(up.Statistics))
	for i, raw := range up.Statistics {
		var b bucket
		if err := json.Unmarshal(raw, &b); err != nil {
			return 0, invalid("statistics[%d]: %v", i, err)
		}
		start, err := ParseTimestamp(b.StartDate)
		if err != nil {
			return 0, invalid("statistics[%d].startDate: %v", i, err)
		}
		end, err := ParseTimestamp(b.EndDate)
		if err != nil {
			return 0, invalid("statistics[%d].endDate: %v", i, err)
		}
		body, err := compactJSON(raw)
		if err != nil {
			return 0, invalid("statistics[%d]: %v", i, err)
		}
		rows = append(rows, row{start.UnixMilli(), end.UnixMilli(), body})
	}

	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback()
	if _, err := tx.ExecContext(ctx,
		`DELETE FROM statistics WHERE type = ? AND interval = ? AND start_ms >= ? AND start_ms < ?`,
		up.Type, up.Interval, rs.UnixMilli(), re.UnixMilli()); err != nil {
		return 0, err
	}
	now := s.now().UnixMilli()
	for _, r := range rows {
		if _, err := tx.ExecContext(ctx,
			`INSERT OR REPLACE INTO statistics(type, interval, start_ms, end_ms, unit, time_zone, body, computed_at)
			 VALUES(?, ?, ?, ?, ?, ?, ?, ?)`,
			up.Type, up.Interval, r.startMs, r.endMs, up.Unit, nullable(up.TimeZone), string(r.body), now); err != nil {
			return 0, err
		}
	}
	return len(rows), tx.Commit()
}

type StatisticsResult struct {
	Type       string            `json:"type"`
	Interval   string            `json:"interval"`
	Unit       string            `json:"unit,omitempty"`
	Statistics []json.RawMessage `json:"statistics"`
}

// maxBucket bounds bucket length (a DST day is 25h) so range queries can
// use the primary key from below.
const maxBucket = 48 * time.Hour

// QueryStatistics returns buckets overlapping [start, end). Each bucket gets
// its timeZone; if the type's unit ever changed, buckets carry their own unit
// and the top-level unit is omitted.
func (s *Store) QueryStatistics(ctx context.Context, typ, interval string, start, end *time.Time) (StatisticsResult, error) {
	res := StatisticsResult{Type: typ, Interval: interval, Statistics: []json.RawMessage{}}
	q := `SELECT unit, time_zone, body FROM statistics WHERE type = ? AND interval = ?`
	args := []any{typ, interval}
	if end != nil {
		q += ` AND start_ms < ?`
		args = append(args, end.UnixMilli())
	}
	if start != nil {
		q += ` AND start_ms > ? AND end_ms > ?`
		args = append(args, start.Add(-maxBucket).UnixMilli(), start.UnixMilli())
	}
	rows, err := s.db.QueryContext(ctx, q+` ORDER BY start_ms`, args...)
	if err != nil {
		return res, err
	}
	defer rows.Close()

	type item struct {
		unit string
		obj  map[string]json.RawMessage
	}
	var items []item
	units := map[string]bool{}
	for rows.Next() {
		var unit, body string
		var tz sql.NullString
		if err := rows.Scan(&unit, &tz, &body); err != nil {
			return res, err
		}
		obj := map[string]json.RawMessage{}
		if err := json.Unmarshal([]byte(body), &obj); err != nil {
			return res, err
		}
		if tz.Valid {
			obj["timeZone"], _ = json.Marshal(tz.String)
		}
		items = append(items, item{unit, obj})
		units[unit] = true
	}
	if err := rows.Err(); err != nil {
		return res, err
	}
	for _, it := range items {
		if len(units) > 1 {
			it.obj["unit"], _ = json.Marshal(it.unit)
		} else {
			res.Unit = it.unit
		}
		b, err := json.Marshal(it.obj)
		if err != nil {
			return res, err
		}
		res.Statistics = append(res.Statistics, b)
	}
	return res, nil
}

const dateLayout = "2006-01-02"

func ValidDate(v string) bool {
	_, err := time.Parse(dateLayout, v)
	return err == nil
}

func (s *Store) StoreActivitySummaries(ctx context.Context, items []json.RawMessage) (int, error) {
	type parsed struct {
		date string
		body json.RawMessage
	}
	all := make([]parsed, 0, len(items))
	for i, raw := range items {
		var v struct {
			DateComponents string `json:"dateComponents"`
		}
		if err := json.Unmarshal(raw, &v); err != nil {
			return 0, invalid("activitySummaries[%d]: %v", i, err)
		}
		if !ValidDate(v.DateComponents) {
			return 0, invalid("activitySummaries[%d].dateComponents must be YYYY-MM-DD", i)
		}
		body, err := compactJSON(raw)
		if err != nil {
			return 0, invalid("activitySummaries[%d]: %v", i, err)
		}
		all = append(all, parsed{v.DateComponents, body})
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback()
	now := s.now().UnixMilli()
	for _, p := range all {
		if _, err := tx.ExecContext(ctx,
			`INSERT INTO activity_summaries(date, body, updated_at) VALUES(?, ?, ?)
			 ON CONFLICT(date) DO UPDATE SET body = excluded.body, updated_at = excluded.updated_at`,
			p.date, string(p.body), now); err != nil {
			return 0, err
		}
	}
	return len(all), tx.Commit()
}

// QueryActivitySummaries returns summaries with start <= date <= end; empty
// bounds are open. YYYY-MM-DD compares correctly as text.
func (s *Store) QueryActivitySummaries(ctx context.Context, start, end string) ([]json.RawMessage, error) {
	rows, err := s.db.QueryContext(ctx,
		`SELECT body FROM activity_summaries
		 WHERE (?1 = '' OR date >= ?1) AND (?2 = '' OR date <= ?2) ORDER BY date`, start, end)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []json.RawMessage{}
	for rows.Next() {
		var body string
		if err := rows.Scan(&body); err != nil {
			return nil, err
		}
		out = append(out, json.RawMessage(body))
	}
	return out, rows.Err()
}

func (s *Store) PutCharacteristics(ctx context.Context, raw json.RawMessage) error {
	var obj map[string]json.RawMessage
	if err := json.Unmarshal(raw, &obj); err != nil || obj == nil {
		return invalid("characteristics must be a JSON object")
	}
	body, err := compactJSON(raw)
	if err != nil {
		return invalid("characteristics: %v", err)
	}
	_, err = s.db.ExecContext(ctx,
		`INSERT INTO characteristics(id, body, updated_at) VALUES(1, ?, ?)
		 ON CONFLICT(id) DO UPDATE SET body = excluded.body, updated_at = excluded.updated_at`,
		string(body), s.now().UnixMilli())
	return err
}

func (s *Store) GetCharacteristics(ctx context.Context) (json.RawMessage, error) {
	var body string
	err := s.db.QueryRowContext(ctx, `SELECT body FROM characteristics WHERE id = 1`).Scan(&body)
	if errors.Is(err, sql.ErrNoRows) {
		return json.RawMessage(`{}`), nil
	}
	return json.RawMessage(body), err
}
