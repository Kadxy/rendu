package cli

import (
	"errors"
	"flag"
	"strconv"
	"strings"
	"time"
)

// ParseSince accepts Go durations plus day and week suffixes: 90m, 24h, 7d, 2w.
func ParseSince(v string) (time.Duration, error) {
	bad := errors.New("invalid duration " + strconv.Quote(v) + " (use e.g. 90m, 24h, 7d, 2w)")
	for suffix, per := range map[string]time.Duration{"d": 24 * time.Hour, "w": 7 * 24 * time.Hour} {
		if n, ok := strings.CutSuffix(v, suffix); ok {
			f, err := strconv.ParseFloat(n, 64)
			if err != nil || f <= 0 {
				return 0, bad
			}
			return time.Duration(f * float64(per)), nil
		}
	}
	d, err := time.ParseDuration(v)
	if err != nil || d <= 0 {
		return 0, bad
	}
	return d, nil
}

var localLayouts = []string{
	"2006-01-02T15:04:05",
	"2006-01-02T15:04",
	"2006-01-02 15:04:05",
	"2006-01-02 15:04",
}

// ParseTime accepts RFC 3339, YYYY-MM-DD, or a local date-time without
// offset; the last two are read in loc. With endOfDay, a bare date means the
// end of that day, so "--start 2026-11-01 --end 2026-11-01" covers the day.
func ParseTime(v string, loc *time.Location, endOfDay bool) (time.Time, error) {
	if t, err := time.Parse(time.RFC3339, v); err == nil {
		return t, nil
	}
	if t, err := time.ParseInLocation("2006-01-02", v, loc); err == nil {
		if endOfDay {
			t = t.AddDate(0, 0, 1)
		}
		return t, nil
	}
	for _, layout := range localLayouts {
		if t, err := time.ParseInLocation(layout, v, loc); err == nil {
			return t, nil
		}
	}
	return time.Time{}, errors.New("invalid time " + strconv.Quote(v) + " (use RFC 3339 or YYYY-MM-DD)")
}

// ParseInterleaved parses flags that may appear before, between or after
// positional arguments, which the flag package alone does not allow.
func ParseInterleaved(fs *flag.FlagSet, args []string) ([]string, error) {
	var positional []string
	for {
		if err := fs.Parse(args); err != nil {
			return nil, err
		}
		args = fs.Args()
		if len(args) == 0 {
			return positional, nil
		}
		positional = append(positional, args[0])
		args = args[1:]
	}
}
