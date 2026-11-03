package cli

import (
	"bytes"
	"encoding/json"
	"flag"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestParseSince(t *testing.T) {
	for in, want := range map[string]time.Duration{
		"90m": 90 * time.Minute, "24h": 24 * time.Hour, "7d": 7 * 24 * time.Hour,
		"1.5d": 36 * time.Hour, "2w": 14 * 24 * time.Hour,
	} {
		if got, err := ParseSince(in); err != nil || got != want {
			t.Errorf("ParseSince(%q) = %v, %v", in, got, err)
		}
	}
	for _, in := range []string{"", "d", "7", "-1d", "soon"} {
		if _, err := ParseSince(in); err == nil {
			t.Errorf("ParseSince(%q) succeeded", in)
		}
	}
}

func TestParseTime(t *testing.T) {
	sh, _ := time.LoadLocation("Asia/Shanghai")
	cases := []struct {
		in       string
		endOfDay bool
		want     string
	}{
		{"2026-11-01T08:00:00Z", false, "2026-11-01T08:00:00Z"},
		{"2026-11-01", false, "2026-11-01T00:00:00+08:00"},
		{"2026-11-01", true, "2026-11-02T00:00:00+08:00"},
		{"2026-11-01T21:30", true, "2026-11-01T21:30:00+08:00"},
	}
	for _, c := range cases {
		got, err := ParseTime(c.in, sh, c.endOfDay)
		if err != nil || got.Format(time.RFC3339) != c.want {
			t.Errorf("ParseTime(%q, %v) = %v, %v; want %s", c.in, c.endOfDay, got.Format(time.RFC3339), err, c.want)
		}
	}
	if _, err := ParseTime("yesterday", sh, false); err == nil {
		t.Error("ParseTime(yesterday) succeeded")
	}
}

func TestParseInterleaved(t *testing.T) {
	fs := flag.NewFlagSet("x", flag.ContinueOnError)
	since := fs.String("since", "", "")
	all := fs.Bool("all", false, "")
	pos, err := ParseInterleaved(fs, []string{"--since", "7d", "HKType", "--all"})
	if err != nil || *since != "7d" || !*all || len(pos) != 1 || pos[0] != "HKType" {
		t.Fatalf("pos=%v since=%q all=%v err=%v", pos, *since, *all, err)
	}
}

// run executes the CLI against handler and returns exit code, stdout, stderr.
func run(t *testing.T, handler http.HandlerFunc, stdin string, args ...string) (int, string, string) {
	t.Helper()
	srv := httptest.NewServer(handler)
	defer srv.Close()
	env := map[string]string{"RENDU_URL": srv.URL + "/", "RENDU_API_KEY": "tok", "RENDU_TZ": "Asia/Shanghai"}
	var out, errOut bytes.Buffer
	code := Run(args, strings.NewReader(stdin), &out, &errOut, func(k string) string { return env[k] })
	return code, out.String(), errOut.String()
}

func TestSamplesAllMergesPages(t *testing.T) {
	var queries []string
	handler := func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer tok" || r.URL.Path != "/v1/samples" {
			http.Error(w, `{"error":"bad request"}`, http.StatusBadRequest)
			return
		}
		queries = append(queries, r.URL.RawQuery)
		if r.URL.Query().Get("cursor") == "" {
			io.WriteString(w, `{"samples":[{"uuid":"A"}],"nextCursor":"c1"}`)
		} else {
			io.WriteString(w, `{"samples":[{"uuid":"B"}]}`)
		}
	}
	code, out, errOut := run(t, handler, "", "samples", "HKQuantityTypeIdentifierHeartRate", "--start", "2026-11-01", "--end", "2026-11-01", "--all")
	if code != 0 {
		t.Fatalf("exit %d: %s", code, errOut)
	}
	if strings.TrimSpace(out) != `{"samples":[{"uuid":"A"},{"uuid":"B"}]}` {
		t.Fatalf("out = %s", out)
	}
	if len(queries) != 2 || !strings.Contains(queries[0], "end=2026-11-02T00%3A00%3A00%2B08%3A00") ||
		!strings.Contains(queries[0], "start=2026-11-01T00%3A00%3A00%2B08%3A00") {
		t.Fatalf("queries = %v", queries)
	}
}

func TestWriteSaveFromStdinAndErrors(t *testing.T) {
	var got map[string]any
	handler := func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodPost && r.URL.Path == "/v1/writes" {
			json.NewDecoder(r.Body).Decode(&got)
			w.WriteHeader(http.StatusCreated)
			io.WriteString(w, `{"id":"W","status":"pending"}`)
			return
		}
		w.WriteHeader(http.StatusNotFound)
		io.WriteString(w, `{"error":"not found"}`)
	}
	code, out, _ := run(t, handler, `{"kind":"quantity"}`, "write", "save", "--sync-identifier", "S1")
	if code != 0 || !strings.Contains(out, `"W"`) {
		t.Fatalf("save: %d %s", code, out)
	}
	if got["op"] != "save" || got["syncIdentifier"] != "S1" || got["object"].(map[string]any)["kind"] != "quantity" {
		t.Fatalf("request = %v", got)
	}

	code, _, errOut := run(t, handler, "", "write", "get", "missing")
	if code != 1 || !strings.Contains(errOut, "(HTTP 404)") || !strings.Contains(errOut, "not found") {
		t.Fatalf("api error: %d %s", code, errOut)
	}
	code, _, errOut = run(t, handler, "{not json", "write", "save")
	if code != 2 || !strings.Contains(errOut, "not valid JSON") {
		t.Fatalf("invalid stdin: %d %s", code, errOut)
	}
	code, _, _ = run(t, handler, "", "samples")
	if code != 2 {
		t.Fatalf("missing type: %d", code)
	}
	code, _, _ = run(t, handler, "", "stats", "X", "--since", "7d", "--start", "2026-11-01")
	if code != 2 {
		t.Fatalf("since+start: %d", code)
	}
}

func TestActivityDates(t *testing.T) {
	var q string
	handler := func(w http.ResponseWriter, r *http.Request) {
		q = r.URL.RawQuery
		io.WriteString(w, `{"activitySummaries":[]}`)
	}
	if code, _, errOut := run(t, handler, "", "activity", "--start", "2026-10-25", "--end", "2026-11-01"); code != 0 {
		t.Fatalf("exit %d: %s", code, errOut)
	}
	// Inclusive dates: the end date must not roll over.
	if q != "end=2026-11-01&start=2026-10-25" {
		t.Fatalf("query = %s", q)
	}
}

func TestVersionNeedsNoServer(t *testing.T) {
	Version = "1.2.3"
	defer func() { Version = "dev" }()
	for _, args := range [][]string{{"version"}, {"--version"}, {"-v"}} {
		var out, errOut bytes.Buffer
		code := Run(args, strings.NewReader(""), &out, &errOut, func(string) string { return "" })
		if code != 0 || out.String() != "rendu 1.2.3\n" {
			t.Fatalf("%v: exit %d, out %q, err %q", args, code, out.String(), errOut.String())
		}
	}
}

func TestChangesQuery(t *testing.T) {
	var paths []string
	handler := func(w http.ResponseWriter, r *http.Request) {
		paths = append(paths, r.URL.Path+"?"+r.URL.RawQuery)
		io.WriteString(w, `{"samples":[],"deleted":[],"anchor":"A2","more":false}`)
	}
	for _, args := range [][]string{
		{"changes"},
		{"changes", "--anchor", "A1", "--type", "T1", "--type", "T2,T3", "--wait", "60"},
		{"changes", "--limit", "0"},
		{"authorization"},
		{"medications"},
	} {
		if code, out, errOut := run(t, handler, "", args...); code != 0 || !strings.Contains(out, `"anchor":"A2"`) {
			t.Fatalf("%v: exit %d, %s %s", args, code, out, errOut)
		}
	}
	want := []string{
		"/v1/changes?",
		"/v1/changes?anchor=A1&type=T1&type=T2%2CT3&wait=60",
		"/v1/changes?limit=0",
		"/v1/authorization?",
		"/v1/medications?",
	}
	if strings.Join(paths, " ") != strings.Join(want, " ") {
		t.Fatalf("requests = %v", paths)
	}
}

func TestSchemaResolves(t *testing.T) {
	var paths []string
	// The server knows a type, a kind, an enum and a metadata key.
	known := map[string]string{
		"/v1/schema": `{"types":[]}`,
		"/v1/schema/types/HKQuantityTypeIdentifierBodyMass": `{"type":"HKQuantityTypeIdentifierBodyMass"}`,
		"/v1/schema/kinds/workout":                          `{"kind":"workout"}`,
		"/v1/schema/enums/HKStateOfMind.Label":              `{"name":"HKStateOfMindLabel"}`,
		"/v1/schema/metadata/HKFoodType":                    `{"key":"HKFoodType"}`,
		"/v1/schema/types/HKBroken":                         ``,
	}
	handler := func(w http.ResponseWriter, r *http.Request) {
		paths = append(paths, r.URL.EscapedPath())
		body, ok := known[r.URL.Path]
		switch {
		case !ok:
			w.WriteHeader(http.StatusNotFound)
			io.WriteString(w, `{"error":"no such thing"}`)
		case body == "":
			w.WriteHeader(http.StatusInternalServerError)
			io.WriteString(w, `{"error":"internal error"}`)
		default:
			io.WriteString(w, body)
		}
	}
	for _, c := range []struct {
		args  []string
		out   string
		tried []string
	}{
		{[]string{"schema"}, `{"types":[]}`, []string{"/v1/schema"}},
		{[]string{"schema", "HKQuantityTypeIdentifierBodyMass"}, `{"type":"HKQuantityTypeIdentifierBodyMass"}`,
			[]string{"/v1/schema/types/HKQuantityTypeIdentifierBodyMass"}},
		{[]string{"schema", "workout"}, `{"kind":"workout"}`, []string{"/v1/schema/types/workout", "/v1/schema/kinds/workout"}},
		{[]string{"schema", "HKStateOfMind.Label"}, `{"name":"HKStateOfMindLabel"}`,
			[]string{"/v1/schema/types/HKStateOfMind.Label", "/v1/schema/kinds/HKStateOfMind.Label", "/v1/schema/enums/HKStateOfMind.Label"}},
		{[]string{"schema", "HKFoodType"}, `{"key":"HKFoodType"}`,
			[]string{"/v1/schema/types/HKFoodType", "/v1/schema/kinds/HKFoodType", "/v1/schema/enums/HKFoodType", "/v1/schema/metadata/HKFoodType"}},
	} {
		paths = nil
		code, out, errOut := run(t, handler, "", c.args...)
		if code != 0 || strings.TrimSpace(out) != c.out || strings.Join(paths, " ") != strings.Join(c.tried, " ") {
			t.Errorf("%v: exit %d, %s %s, tried %v", c.args, code, out, errOut, paths)
		}
	}

	paths = nil
	code, _, errOut := run(t, handler, "", "schema", "HKNope")
	if code != 1 || !strings.Contains(errOut, "(HTTP 404)") || !strings.Contains(errOut, "HKNope is not a type, kind, enum or metadata key") || len(paths) != 4 {
		t.Errorf("unknown: exit %d, %s, tried %v", code, errOut, paths)
	}
	// Other errors stop the search.
	paths = nil
	if code, _, errOut := run(t, handler, "", "schema", "HKBroken"); code != 1 || !strings.Contains(errOut, "(HTTP 500)") || len(paths) != 1 {
		t.Errorf("server error: exit %d, %s, tried %v", code, errOut, paths)
	}
	if code, _, _ := run(t, handler, "", "schema", "a", "b"); code != 2 {
		t.Errorf("two names: exit %d", code)
	}
}

func TestHelpAndTypos(t *testing.T) {
	cli := func(args ...string) (int, string, string) {
		var out, errOut bytes.Buffer
		code := Run(args, strings.NewReader(""), &out, &errOut, func(string) string { return "" })
		return code, out.String(), errOut.String()
	}
	// The overview: a line a command, not every flag.
	code, out, _ := cli("help")
	if code != 0 || !strings.Contains(out, "samples <type>") || strings.Contains(out, "--source") || strings.Count(out, "\n") > 30 {
		t.Fatalf("help: %d\n%s", code, out)
	}
	if code, _, errOut := cli(); code != 2 || errOut != out {
		t.Fatalf("no arguments: %d", code)
	}
	// A command in full, however it's asked for.
	for _, args := range [][]string{{"help", "samples"}, {"samples", "--help"}, {"samples", "HKQuantityTypeIdentifierStepCount", "-h"}} {
		if code, out, _ := cli(args...); code != 0 || !strings.Contains(out, "--source BUNDLE") {
			t.Fatalf("%v: %d %s", args, code, out)
		}
	}
	if code, out, _ := cli("write", "save", "-h"); code != 0 || !strings.Contains(out, "--sync-identifier X") {
		t.Fatalf("write save -h: %d %s", code, out)
	}
	if code, out, _ := cli("help", "write"); code != 0 || !strings.Contains(out, "write delete <syncIdentifier>") {
		t.Fatalf("help write: %d %s", code, out)
	}
	// Typos get a suggestion.
	if code, _, errOut := cli("scheme", "HKVisionPrescriptionTypeIdentifier"); code != 2 || !strings.Contains(errOut, `did you mean "schema"?`) {
		t.Fatalf("scheme: %d %s", code, errOut)
	}
	if code, _, errOut := cli("write", "sav"); code != 2 || !strings.Contains(errOut, `did you mean "save"?`) {
		t.Fatalf("write sav: %d %s", code, errOut)
	}
	if code, _, errOut := cli("help", "sample"); code != 2 || !strings.Contains(errOut, `did you mean "samples"?`) {
		t.Fatalf("help sample: %d %s", code, errOut)
	}
}
