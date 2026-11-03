// Package cli implements the rendu command, a thin JSON client of the agent API.
package cli

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"runtime/debug"
	"slices"
	"strings"
	"time"
)

// command is one of rendu's commands: the overview lists them by group,
// and `rendu help <command>` (or `<command> --help`) prints one in full.
type command struct {
	group, name, args, summary, details string
}

var commands = []command{
	{"Read", "status", "", "Server and sync status", ""},
	{"Read", "types", "", "Types the server has data for", ""},
	{"Read", "samples", "<type>", "Samples of a type", `Flags:
  --since 7d           look back this far: 90m, 24h, 7d, 2w
  --start T --end T    a range: RFC 3339 or YYYY-MM-DD (a bare --end date includes that day)
  --source BUNDLE      only from this source (bundle identifier)
  --limit N            page size (default 1000, max 10000)
  --all                every page, merged`},
	{"Read", "stats", "<type>", "Statistics of a type, by day or hour", `Flags:
  --interval day|hour  default day
  --since 30d | --start T --end T`},
	{"Read", "activity", "", "Activity ring summaries", `Flags:
  --since 7d | --start DATE --end DATE`},
	{"Read", "changes", "", "What changed since an anchor", `Flags:
  --anchor A    the previous response's anchor (default: from the beginning)
  --type T      only these types (repeat, or comma-separated)
  --limit N     at most this many (default 500, max 5000; 0 for just the anchor)
  --wait S      wait up to S seconds (max 60) for a change instead of an empty page`},
	{"Read", "characteristics", "", "Date of birth, sex, blood type…", ""},
	{"Read", "medications", "", "Medications shared with Rendu", ""},
	{"Read", "authorization", "", "Which types Rendu may write", ""},
	{"Write", "write save", "[--sync-identifier X] [--file F]", "Save an object (JSON from stdin or --file)", `Flags:
  --sync-identifier X  replace the object saved under this syncIdentifier
  --file F             read the object from F instead of stdin`},
	{"Write", "write delete", "<syncIdentifier>", "Delete an object Rendu saved", ""},
	{"Write", "write get", "<id>", "A write and its status", ""},
	{"Write", "write list", "", "Writes, newest first", `Flags:
  --status S           pending, written, failed or conflict
  --sync-identifier X  only this object's
  --limit N            at most this many (default 100)`},
	{"Reference", "schema", "[name]", "Definitions of types, kinds, enums, metadata keys", `Without a name, lists what there is. With one — a type
(HKQuantityTypeIdentifierBodyMass), a kind (workout), an enum
(HKStateOfMind.Label) or a metadata key (HKFoodType) — everything about it:
its fields, its values, and an example to write.`},
	{"Reference", "update", "", "Update rendu to the latest release", `Flags:
  --check       only say whether there's a newer release
  --version V   install this release instead (e.g. v0.1.0)`},
}

// overview is `rendu` and `rendu help`: the commands, one line each.
func overview() string {
	var b strings.Builder
	b.WriteString("rendu — read and write Apple Health through a Rendu server\n\nUsage: rendu <command> [arguments]\n")
	group := ""
	for _, c := range commands {
		if c.group != group {
			group = c.group
			fmt.Fprintf(&b, "\n%s\n", group)
		}
		fmt.Fprintf(&b, "  %-18s %s\n", strings.TrimSpace(c.name+" "+firstWord(c.args)), c.summary)
	}
	b.WriteString(`
Needs RENDU_URL and RENDU_API_KEY (an API key from the Rendu app). Output is JSON.
'rendu help <command>' for its flags, 'rendu -v' for the version, 'rendu update' to update.
`)
	return b.String()
}

// firstWord keeps a short positional argument ("<type>") for the
// overview; the flags and longer ones are in the command's help.
func firstWord(args string) string {
	if args == "" || strings.HasPrefix(args, "[-") || len(strings.Fields(args)[0]) > 8 {
		return ""
	}
	return strings.Fields(args)[0]
}

// helpFor prints a command in full; "write" lists its subcommands.
func helpFor(name string) (string, bool) {
	var b strings.Builder
	for _, c := range commands {
		if c.name == name {
			usage := strings.TrimSpace(c.name + " " + c.args)
			if strings.HasPrefix(c.details, "Flags:") && !strings.Contains(c.args, "--") {
				usage += " [flags]"
			}
			fmt.Fprintf(&b, "Usage: rendu %s\n\n%s.\n", usage, c.summary)
			if c.name == "samples" || c.name == "stats" || c.name == "changes" {
				b.WriteString("Types are HealthKit identifiers, e.g. HKQuantityTypeIdentifierStepCount.\n")
			}
			if c.details != "" {
				fmt.Fprintf(&b, "\n%s\n", c.details)
			}
			if strings.Contains(c.details, "--start") {
				b.WriteString("\nDates without an offset are in RENDU_TZ (an IANA time zone; default: local).\n")
			}
			return b.String(), true
		}
		if strings.HasPrefix(c.name, name+" ") {
			if b.Len() == 0 {
				fmt.Fprintf(&b, "Usage: rendu %s <subcommand>\n\n", name)
			}
			fmt.Fprintf(&b, "  %-36s %s\n", strings.TrimSpace(c.name+" "+c.args), c.summary)
		}
	}
	return b.String(), b.Len() > 0
}

// suggest finds the names `name` is likely a typo of ("scheme": schema).
func suggest(name string, names []string) string {
	best, bestDist := "", 3
	for _, n := range names {
		if d := distance(name, n); d < bestDist {
			best, bestDist = n, d
		}
	}
	return best
}

// distance is the Levenshtein distance between a and b.
func distance(a, b string) int {
	prev := make([]int, len(b)+1)
	for j := range prev {
		prev[j] = j
	}
	for i := 1; i <= len(a); i++ {
		cur := make([]int, len(b)+1)
		cur[0] = i
		for j := 1; j <= len(b); j++ {
			cost := 1
			if a[i-1] == b[j-1] {
				cost = 0
			}
			cur[j] = min(prev[j]+1, cur[j-1]+1, prev[j-1]+cost)
		}
		prev = cur
	}
	return prev[len(b)]
}

// topNames are the first words of the commands, and help and version.
func topNames() []string {
	names := []string{"help", "version"}
	for _, c := range commands {
		if w := strings.Fields(c.name)[0]; !slices.Contains(names, w) {
			names = append(names, w)
		}
	}
	return names
}

// Version is set at build time (-ldflags "-X …/cli.Version=…"); go install
// builds fall back to the module version.
var Version = "dev"

type app struct {
	baseURL string
	token   string
	loc     *time.Location
	now     func() time.Time
	stdin   io.Reader
	stdout  io.Writer
	stderr  io.Writer
	http    *http.Client
	pretty  bool
}

// usageError is reported with exit code 2.
type usageError struct{ msg string }

func (e *usageError) Error() string { return e.msg }

func usagef(format string, args ...any) error { return &usageError{fmt.Sprintf(format, args...)} }

// apiError is a non-2xx response from the server.
type apiError struct {
	Status  int
	Message string
}

func (e *apiError) Error() string { return e.Message }

// Run executes the CLI and returns the process exit code.
func Run(args []string, stdin io.Reader, stdout, stderr io.Writer, getenv func(string) string) int {
	if len(args) == 0 {
		fmt.Fprint(stderr, overview())
		return 2
	}
	switch args[0] {
	case "-v", "--version", "version":
		fmt.Fprintf(stdout, "rendu %s\n", version())
		return 0
	case "help", "-h", "--help":
		if len(args) == 1 || strings.HasPrefix(args[1], "-") {
			fmt.Fprint(stdout, overview())
			return 0
		}
		return printHelp(strings.Join(args[1:], " "), stdout, stderr)
	}
	// "rendu samples X --help", "rendu write save -h": that command's help.
	for i, arg := range args {
		if arg == "-h" || arg == "--help" || arg == "-help" {
			name := args[0]
			if name == "write" && i > 1 {
				name += " " + args[1]
			}
			return printHelp(name, stdout, stderr)
		}
	}
	a := &app{
		baseURL: strings.TrimRight(getenv("RENDU_URL"), "/"),
		token:   getenv("RENDU_API_KEY"),
		loc:     time.Local,
		now:     time.Now,
		stdin:   stdin,
		stdout:  stdout,
		stderr:  stderr,
		http:    &http.Client{Timeout: 2 * time.Minute},
		pretty:  isTerminal(stdout),
	}
	err := a.setTimeZone(getenv("RENDU_TZ"))
	if err == nil {
		err = a.dispatch(args)
	}
	if err == nil {
		return 0
	}
	// One line on stderr, as git and gh do; the exit code says it failed.
	if ae := (*apiError)(nil); errors.As(err, &ae) {
		fmt.Fprintf(stderr, "rendu: %s (HTTP %d)\n", err, ae.Status)
	} else {
		fmt.Fprintf(stderr, "rendu: %s\n", err)
	}
	var ue *usageError
	if errors.As(err, &ue) {
		return 2
	}
	return 1
}

func (a *app) setTimeZone(name string) error {
	if name == "" {
		return nil
	}
	loc, err := time.LoadLocation(name)
	if err != nil {
		return usagef("RENDU_TZ: %v", err)
	}
	a.loc = loc
	return nil
}

func (a *app) dispatch(args []string) error {
	cmd, rest := args[0], args[1:]
	switch cmd {
	case "status":
		return a.simpleGet(cmd, rest, "/v1/status")
	case "types":
		return a.simpleGet(cmd, rest, "/v1/types")
	case "characteristics":
		return a.simpleGet(cmd, rest, "/v1/characteristics")
	case "medications":
		return a.simpleGet(cmd, rest, "/v1/medications")
	case "authorization":
		return a.simpleGet(cmd, rest, "/v1/authorization")
	case "changes":
		return a.changes(rest)
	case "schema":
		return a.schema(rest)
	case "samples":
		return a.samples(rest)
	case "stats":
		return a.stats(rest)
	case "activity":
		return a.activity(rest)
	case "write":
		return a.write(rest)
	case "update":
		return a.update(rest)
	}
	if close := suggest(cmd, topNames()); close != "" {
		return usagef("unknown command %q; did you mean %q?", cmd, close)
	}
	return usagef("unknown command %q (run 'rendu help')", cmd)
}

// printHelp prints a command's help, or says there's no such command.
func printHelp(name string, stdout, stderr io.Writer) int {
	if text, ok := helpFor(name); ok {
		fmt.Fprint(stdout, text)
		return 0
	}
	msg := fmt.Sprintf("no command %q", name)
	if close := suggest(name, topNames()); close != "" {
		msg += fmt.Sprintf("; did you mean %q?", close)
	}
	fmt.Fprintf(stderr, "rendu: %s\n", msg)
	return 2
}

func version() string {
	if Version == "dev" {
		if bi, ok := debug.ReadBuildInfo(); ok && bi.Main.Version != "" && bi.Main.Version != "(devel)" {
			return strings.TrimPrefix(bi.Main.Version, "v")
		}
	}
	return Version
}

func newFlags(name string) *flag.FlagSet {
	fs := flag.NewFlagSet(name, flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	return fs
}

func parse(fs *flag.FlagSet, args []string, wantPositional int) ([]string, error) {
	pos, err := ParseInterleaved(fs, args)
	if err != nil {
		return nil, usagef("%s: %v", fs.Name(), err)
	}
	if len(pos) != wantPositional {
		return nil, usagef("%s: expected %d argument(s), got %d (run 'rendu help %s')", fs.Name(), wantPositional, len(pos), fs.Name())
	}
	return pos, nil
}

func (a *app) simpleGet(name string, args []string, path string) error {
	if _, err := parse(newFlags(name), args, 0); err != nil {
		return err
	}
	body, err := a.do(http.MethodGet, path, nil, nil)
	if err != nil {
		return err
	}
	return a.emit(body)
}

type rangeFlags struct{ since, start, end *string }

func addRange(fs *flag.FlagSet) rangeFlags {
	return rangeFlags{
		since: fs.String("since", "", "look back this far, e.g. 7d"),
		start: fs.String("start", "", "range start"),
		end:   fs.String("end", "", "range end"),
	}
}

// resolve turns the range flags into absolute times (nil when unbounded).
func (r rangeFlags) resolve(a *app) (start, end *time.Time, err error) {
	if *r.since != "" && (*r.start != "" || *r.end != "") {
		return nil, nil, usagef("use either --since or --start/--end")
	}
	if *r.since != "" {
		d, err := ParseSince(*r.since)
		if err != nil {
			return nil, nil, usagef("--since: %v", err)
		}
		t := a.now().Add(-d)
		return &t, nil, nil
	}
	if *r.start != "" {
		t, err := ParseTime(*r.start, a.loc, false)
		if err != nil {
			return nil, nil, usagef("--start: %v", err)
		}
		start = &t
	}
	if *r.end != "" {
		t, err := ParseTime(*r.end, a.loc, true)
		if err != nil {
			return nil, nil, usagef("--end: %v", err)
		}
		end = &t
	}
	return start, end, nil
}

func (a *app) setRange(q url.Values, r rangeFlags) error {
	start, end, err := r.resolve(a)
	if err != nil {
		return err
	}
	if start != nil {
		q.Set("start", start.In(a.loc).Format(time.RFC3339))
	}
	if end != nil {
		q.Set("end", end.In(a.loc).Format(time.RFC3339))
	}
	return nil
}

func (a *app) samples(args []string) error {
	fs := newFlags("samples")
	r := addRange(fs)
	source := fs.String("source", "", "bundle identifier of the source")
	limit := fs.Int("limit", 0, "page size (server default 1000, max 10000)")
	all := fs.Bool("all", false, "follow nextCursor and merge every page")
	pos, err := parse(fs, args, 1)
	if err != nil {
		return err
	}
	q := url.Values{"type": {pos[0]}}
	if err := a.setRange(q, r); err != nil {
		return err
	}
	if *source != "" {
		q.Set("source", *source)
	}
	if *limit > 0 {
		q.Set("limit", fmt.Sprint(*limit))
	}
	if !*all {
		body, err := a.do(http.MethodGet, "/v1/samples", q, nil)
		if err != nil {
			return err
		}
		return a.emit(body)
	}

	merged := []json.RawMessage{}
	for {
		body, err := a.do(http.MethodGet, "/v1/samples", q, nil)
		if err != nil {
			return err
		}
		var page struct {
			Samples    []json.RawMessage `json:"samples"`
			NextCursor string            `json:"nextCursor"`
		}
		if err := json.Unmarshal(body, &page); err != nil {
			return fmt.Errorf("decoding response: %w", err)
		}
		merged = append(merged, page.Samples...)
		if page.NextCursor == "" {
			break
		}
		q.Set("cursor", page.NextCursor)
	}
	out, err := json.Marshal(map[string]any{"samples": merged})
	if err != nil {
		return err
	}
	return a.emit(out)
}

func (a *app) stats(args []string) error {
	fs := newFlags("stats")
	r := addRange(fs)
	interval := fs.String("interval", "day", "day or hour")
	pos, err := parse(fs, args, 1)
	if err != nil {
		return err
	}
	q := url.Values{"type": {pos[0]}, "interval": {*interval}}
	if err := a.setRange(q, r); err != nil {
		return err
	}
	body, err := a.do(http.MethodGet, "/v1/statistics", q, nil)
	if err != nil {
		return err
	}
	return a.emit(body)
}

// listFlag collects a repeatable flag.
type listFlag []string

func (l *listFlag) String() string     { return strings.Join(*l, ",") }
func (l *listFlag) Set(v string) error { *l = append(*l, v); return nil }

func (a *app) changes(args []string) error {
	fs := newFlags("changes")
	anchor := fs.String("anchor", "", "anchor from the previous response (default: from the beginning)")
	var types listFlag
	fs.Var(&types, "type", "only this type (repeatable, or comma-separated)")
	limit := fs.Int("limit", -1, "max changes (server default 500, max 5000; 0 for just the current anchor)")
	wait := fs.Int("wait", 0, "seconds to wait for a change when there is none (max 60)")
	if _, err := parse(fs, args, 0); err != nil {
		return err
	}
	q := url.Values{}
	if *anchor != "" {
		q.Set("anchor", *anchor)
	}
	for _, t := range types {
		q.Add("type", t)
	}
	if *limit >= 0 {
		q.Set("limit", fmt.Sprint(*limit))
	}
	if *wait > 0 {
		q.Set("wait", fmt.Sprint(*wait))
	}
	body, err := a.do(http.MethodGet, "/v1/changes", q, nil)
	if err != nil {
		return err
	}
	return a.emit(body)
}

// schemaPaths are where a name may be defined, in the order tried.
var schemaPaths = []string{"/v1/schema/types/", "/v1/schema/kinds/", "/v1/schema/enums/", "/v1/schema/metadata/"}

// schema shows the overview, or what a name is: a type, a kind, an enum or
// a metadata key, the first that the server knows.
func (a *app) schema(args []string) error {
	fs := newFlags("schema")
	pos, err := ParseInterleaved(fs, args)
	if err != nil {
		return usagef("schema: %v", err)
	}
	switch len(pos) {
	case 0:
		return a.simpleGet("schema", nil, "/v1/schema")
	case 1:
	default:
		return usagef("schema: expected at most 1 argument, got %d (run 'rendu help')", len(pos))
	}
	for _, prefix := range schemaPaths {
		body, err := a.do(http.MethodGet, prefix+url.PathEscape(pos[0]), nil, nil)
		var ae *apiError
		if errors.As(err, &ae) && ae.Status == http.StatusNotFound {
			continue
		}
		if err != nil {
			return err
		}
		return a.emit(body)
	}
	return &apiError{Status: http.StatusNotFound,
		Message: fmt.Sprintf("%s is not a type, kind, enum or metadata key the server knows (rendu schema lists them)", pos[0])}
}

func (a *app) activity(args []string) error {
	fs := newFlags("activity")
	r := addRange(fs)
	if _, err := parse(fs, args, 0); err != nil {
		return err
	}
	// Activity summaries are keyed by calendar date and both ends are
	// inclusive, so a bare --end date must not roll over to the next day.
	q := url.Values{}
	date := func(v string) (string, error) {
		t, err := ParseTime(v, a.loc, false)
		if err != nil {
			return "", err
		}
		return t.In(a.loc).Format("2006-01-02"), nil
	}
	switch {
	case *r.since != "" && (*r.start != "" || *r.end != ""):
		return usagef("use either --since or --start/--end")
	case *r.since != "":
		d, err := ParseSince(*r.since)
		if err != nil {
			return usagef("--since: %v", err)
		}
		q.Set("start", a.now().Add(-d).In(a.loc).Format("2006-01-02"))
	default:
		if *r.start != "" {
			v, err := date(*r.start)
			if err != nil {
				return usagef("--start: %v", err)
			}
			q.Set("start", v)
		}
		if *r.end != "" {
			v, err := date(*r.end)
			if err != nil {
				return usagef("--end: %v", err)
			}
			q.Set("end", v)
		}
	}
	body, err := a.do(http.MethodGet, "/v1/activity-summaries", q, nil)
	if err != nil {
		return err
	}
	return a.emit(body)
}

func (a *app) write(args []string) error {
	if len(args) == 0 {
		return usagef("write: expected save, delete, get or list (run 'rendu help write')")
	}
	sub, rest := args[0], args[1:]
	switch sub {
	case "save":
		fs := newFlags("write save")
		syncID := fs.String("sync-identifier", "", "replace the object with this syncIdentifier")
		file := fs.String("file", "", "object JSON file (default: stdin)")
		if _, err := parse(fs, rest, 0); err != nil {
			return err
		}
		var raw []byte
		var err error
		if *file == "" || *file == "-" {
			raw, err = io.ReadAll(a.stdin)
		} else {
			raw, err = os.ReadFile(*file)
		}
		if err != nil {
			return err
		}
		if !json.Valid(raw) {
			return usagef("write save: object is not valid JSON")
		}
		body, err := json.Marshal(struct {
			Op             string          `json:"op"`
			SyncIdentifier string          `json:"syncIdentifier,omitempty"`
			Object         json.RawMessage `json:"object"`
		}{"save", *syncID, raw})
		if err != nil {
			return err
		}
		return a.post("/v1/writes", body)
	case "delete":
		pos, err := parse(newFlags("write delete"), rest, 1)
		if err != nil {
			return err
		}
		body, _ := json.Marshal(map[string]string{"op": "delete", "syncIdentifier": pos[0]})
		return a.post("/v1/writes", body)
	case "get":
		pos, err := parse(newFlags("write get"), rest, 1)
		if err != nil {
			return err
		}
		body, err := a.do(http.MethodGet, "/v1/writes/"+url.PathEscape(pos[0]), nil, nil)
		if err != nil {
			return err
		}
		return a.emit(body)
	case "list":
		fs := newFlags("write list")
		status := fs.String("status", "", "pending, written, failed or conflict")
		syncID := fs.String("sync-identifier", "", "only this object")
		limit := fs.Int("limit", 0, "max results (server default 100)")
		if _, err := parse(fs, rest, 0); err != nil {
			return err
		}
		q := url.Values{}
		if *status != "" {
			q.Set("status", *status)
		}
		if *syncID != "" {
			q.Set("syncIdentifier", *syncID)
		}
		if *limit > 0 {
			q.Set("limit", fmt.Sprint(*limit))
		}
		body, err := a.do(http.MethodGet, "/v1/writes", q, nil)
		if err != nil {
			return err
		}
		return a.emit(body)
	}
	if close := suggest(sub, []string{"save", "delete", "get", "list"}); close != "" {
		return usagef("write: unknown subcommand %q; did you mean %q?", sub, close)
	}
	return usagef("write: unknown subcommand %q (run 'rendu help write')", sub)
}

func (a *app) post(path string, body []byte) error {
	out, err := a.do(http.MethodPost, path, nil, body)
	if err != nil {
		return err
	}
	return a.emit(out)
}

func (a *app) do(method, path string, q url.Values, body []byte) ([]byte, error) {
	if a.baseURL == "" {
		return nil, usagef("RENDU_URL is not set")
	}
	if a.token == "" {
		return nil, usagef("RENDU_API_KEY is not set")
	}
	u := a.baseURL + path
	if len(q) > 0 {
		u += "?" + q.Encode()
	}
	var rd io.Reader
	if body != nil {
		rd = bytes.NewReader(body)
	}
	req, err := http.NewRequestWithContext(context.Background(), method, u, rd)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+a.token)
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := a.http.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}
	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		var e struct {
			Error string `json:"error"`
		}
		msg := strings.TrimSpace(string(data))
		if json.Unmarshal(data, &e) == nil && e.Error != "" {
			msg = e.Error
		}
		if msg == "" {
			msg = resp.Status
		}
		return nil, &apiError{Status: resp.StatusCode, Message: msg}
	}
	return data, nil
}

// emit prints JSON, indented for humans and compact for pipes and agents.
func (a *app) emit(data []byte) error {
	var buf bytes.Buffer
	var err error
	if a.pretty {
		err = json.Indent(&buf, data, "", "  ")
	} else {
		err = json.Compact(&buf, data)
	}
	if err != nil {
		return fmt.Errorf("server returned invalid JSON: %w", err)
	}
	buf.WriteByte('\n')
	_, err = a.stdout.Write(buf.Bytes())
	return err
}

func isTerminal(w io.Writer) bool {
	f, ok := w.(*os.File)
	if !ok {
		return false
	}
	info, err := f.Stat()
	return err == nil && info.Mode()&os.ModeCharDevice != 0
}
