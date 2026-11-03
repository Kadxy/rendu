package server

import (
	"bytes"
	"compress/gzip"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/Kadxy/rendu/internal/store"
)

type env struct {
	t     *testing.T
	srv   *httptest.Server
	store *store.Store
	// device is the paired iPhone's owner key; agent a read+write API key;
	// reader a read-only one.
	device string
	agent  string
	reader string
}

func newEnv(t *testing.T) *env {
	t.Helper()
	st, err := store.Open(filepath.Join(t.TempDir(), "rendu.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })
	srv := httptest.NewServer(New(st).Handler())
	t.Cleanup(srv.Close)
	ctx := context.Background()
	if err := st.StartPairing(ctx, "123456"); err != nil {
		t.Fatal(err)
	}
	if _, err := st.CompletePairing(ctx, "123456", ownerKey); err != nil {
		t.Fatal(err)
	}
	_, agent, err := st.CreateAPIKey(ctx, "agent", store.ScopeReadWrite)
	if err != nil {
		t.Fatal(err)
	}
	_, reader, err := st.CreateAPIKey(ctx, "reader", store.ScopeRead)
	if err != nil {
		t.Fatal(err)
	}
	return &env{t: t, srv: srv, store: st, device: ownerKey, agent: agent, reader: reader}
}

// ownerKey stands in for the key an iPhone generates (32 random bytes,
// base64url).
const ownerKey = "q8b0Zp3XW1vR7kE2nT5yU9iO4lA6sD8fG0hJ2kL4mN6"

// call sends body (marshalled unless already []byte) and decodes the JSON
// response into a generic value.
func (e *env) call(method, path, token string, body any, gz bool) (int, any) {
	e.t.Helper()
	return e.callWith(method, path, token, nil, body, gz)
}

func (e *env) callWith(method, path, token string, headers map[string]string, body any, gz bool) (int, any) {
	e.t.Helper()
	var data []byte
	switch b := body.(type) {
	case nil:
	case []byte:
		data = b
	case string:
		data = []byte(b)
	default:
		var err error
		if data, err = json.Marshal(b); err != nil {
			e.t.Fatal(err)
		}
	}
	if gz {
		var buf bytes.Buffer
		w := gzip.NewWriter(&buf)
		w.Write(data)
		w.Close()
		data = buf.Bytes()
	}
	req, err := http.NewRequest(method, e.srv.URL+path, bytes.NewReader(data))
	if err != nil {
		e.t.Fatal(err)
	}
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	if gz {
		req.Header.Set("Content-Encoding", "gzip")
	}
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		e.t.Fatal(err)
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	var out any
	if len(raw) > 0 {
		if err := json.Unmarshal(raw, &out); err != nil {
			e.t.Fatalf("%s %s: invalid JSON %q", method, path, raw)
		}
	}
	return resp.StatusCode, out
}

func (e *env) must(status int, method, path, token string, body any) map[string]any {
	e.t.Helper()
	got, out := e.call(method, path, token, body, false)
	if got != status {
		e.t.Fatalf("%s %s: status %d, want %d (%v)", method, path, got, status, out)
	}
	m, _ := out.(map[string]any)
	return m
}

func (e *env) mustWith(status int, method, path, token string, headers map[string]string, body any) map[string]any {
	e.t.Helper()
	got, out := e.callWith(method, path, token, headers, body, false)
	if got != status {
		e.t.Fatalf("%s %s: status %d, want %d (%v)", method, path, got, status, out)
	}
	m, _ := out.(map[string]any)
	return m
}

func quantity(uuid, typ, start, end string, value float64, source string) map[string]any {
	return map[string]any{
		"uuid": uuid, "kind": "quantity", "type": typ,
		"startDate": start, "endDate": end,
		"quantity":       map[string]any{"value": value, "unit": "count/min"},
		"sourceRevision": map[string]any{"source": map[string]any{"name": source, "bundleIdentifier": source}},
	}
}

const hr = "HKQuantityTypeIdentifierHeartRate"

func uuids(t *testing.T, resp map[string]any) []string {
	t.Helper()
	var out []string
	for _, s := range resp["samples"].([]any) {
		out = append(out, s.(map[string]any)["uuid"].(string))
	}
	return out
}

func equal(a, b []string) bool {
	return fmt.Sprint(a) == fmt.Sprint(b)
}

func TestAuthAndScopes(t *testing.T) {
	e := newEnv(t)
	e.must(http.StatusOK, "GET", "/v1/health", "", nil)
	e.must(http.StatusUnauthorized, "GET", "/v1/status", "", nil)
	e.must(http.StatusUnauthorized, "GET", "/v1/status", "rdk_bogus", nil)
	e.must(http.StatusUnauthorized, "GET", "/v1/status", e.agent[:len(e.agent)-1], nil)
	e.must(http.StatusNotFound, "GET", "/v1/nope", e.reader, nil)
	e.must(http.StatusUnauthorized, "GET", "/v1/nope", "", nil)

	for _, key := range []string{e.device, e.agent, e.reader} {
		e.must(http.StatusOK, "GET", "/v1/status", key, nil)
		e.must(http.StatusOK, "GET", "/v1/writes", key, nil)
	}
	// Writing takes read+write; the phone's own endpoints take the owner.
	e.must(http.StatusForbidden, "POST", "/v1/writes", e.reader, map[string]any{"op": "delete", "syncIdentifier": "x"})
	for _, key := range []string{e.agent, e.reader} {
		e.must(http.StatusForbidden, "POST", "/v1/ingest", key, []any{})
		e.must(http.StatusForbidden, "GET", "/v1/writes/pending", key, nil)
		e.must(http.StatusForbidden, "DELETE", "/v1/data", key, nil)
		e.must(http.StatusForbidden, "GET", "/v1/keys", key, nil)
		e.must(http.StatusForbidden, "POST", "/v1/keys", key, map[string]any{"name": "x", "scope": "read"})
	}
	e.must(http.StatusOK, "GET", "/v1/writes/pending", e.device, nil)
}

func TestPairingReplacesTheOwner(t *testing.T) {
	e := newEnv(t)
	newKey := "Zx9Yw8Vu7Ts6Rq5Po4Nm3Lk2Jh1Gf0EdCbA9z8y7x6w"
	pair := func(code, key string) int {
		t.Helper()
		status, _ := e.call("POST", "/v1/pair", "", map[string]string{"code": code, "key": key}, false)
		return status
	}

	// Nothing entered on the server: refused, and not counted.
	if got := pair("654321", newKey); got != http.StatusNotFound {
		t.Fatalf("pair before start = %d", got)
	}
	if err := e.store.StartPairing(context.Background(), "654321"); err != nil {
		t.Fatal(err)
	}
	if got := pair("654321", "short"); got != http.StatusBadRequest {
		t.Fatalf("pair with a weak key = %d", got)
	}
	if got := pair("654321", newKey); got != http.StatusOK {
		t.Fatalf("pair = %d", got)
	}
	// The code is used up; the old iPhone is out, the new one in; API keys stay.
	if got := pair("654321", newKey); got != http.StatusNotFound {
		t.Fatalf("pair again = %d", got)
	}
	e.must(http.StatusUnauthorized, "GET", "/v1/status", e.device, nil)
	e.must(http.StatusOK, "GET", "/v1/writes/pending", newKey, nil)
	e.must(http.StatusOK, "GET", "/v1/status", e.agent, nil)
	keys := e.must(http.StatusOK, "GET", "/v1/keys", newKey, nil)["keys"].([]any)
	if len(keys) != 3 || keys[0].(map[string]any)["scope"] != "owner" {
		t.Fatalf("keys = %v", keys)
	}

	// Wrong codes: the fifth voids the code, even for the right one after.
	if err := e.store.StartPairing(context.Background(), "111111"); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < store.MaxPairingAttempts; i++ {
		if got := pair(fmt.Sprintf("00000%d", i), newKey); got != http.StatusForbidden {
			t.Fatalf("wrong code %d = %d", i, got)
		}
	}
	if got := pair("111111", e.device); got != http.StatusNotFound {
		t.Fatalf("pair after too many attempts = %d", got)
	}
}

func TestAPIKeys(t *testing.T) {
	e := newEnv(t)
	created := e.must(http.StatusCreated, "POST", "/v1/keys", e.device, map[string]any{"name": "My Agent", "scope": "read"})
	key, _ := created["key"].(string)
	if !strings.HasPrefix(key, store.APIKeyPrefix) || len(key) != len(store.APIKeyPrefix)+43 || strings.ContainsAny(key, "-+/=") {
		t.Fatalf("key = %q", key)
	}
	e.must(http.StatusOK, "GET", "/v1/types", key, nil)
	e.must(http.StatusForbidden, "POST", "/v1/writes", key, map[string]any{"op": "delete", "syncIdentifier": "x"})

	// Listed with when it was last used, never with the key.
	keys := e.must(http.StatusOK, "GET", "/v1/keys", e.device, nil)["keys"].([]any)
	var listed map[string]any
	for _, k := range keys {
		if k.(map[string]any)["id"] == created["id"] {
			listed = k.(map[string]any)
		}
	}
	if listed == nil || listed["lastUsedAt"] == nil || listed["key"] != nil || listed["name"] != "My Agent" {
		t.Fatalf("listed = %v", listed)
	}

	e.must(http.StatusOK, "DELETE", "/v1/keys/"+created["id"].(string), e.device, nil)
	e.must(http.StatusUnauthorized, "GET", "/v1/types", key, nil)
	// The owner key isn't revoked this way.
	owner := keys[0].(map[string]any)["id"].(string)
	e.must(http.StatusNotFound, "DELETE", "/v1/keys/"+owner, e.device, nil)
	e.must(http.StatusBadRequest, "POST", "/v1/keys", e.device, map[string]any{"name": "x", "scope": "owner"})
	e.must(http.StatusBadRequest, "POST", "/v1/keys", e.device, map[string]any{"name": "", "scope": "read"})

	// Wiping the data keeps every key.
	e.must(http.StatusOK, "DELETE", "/v1/data", e.device, nil)
	e.must(http.StatusOK, "GET", "/v1/status", e.agent, nil)
}

func TestIngestDedupAndDeletion(t *testing.T) {
	e := newEnv(t)
	a := quantity("A", hr, "2026-11-01T08:00:00+08:00", "2026-11-01T08:00:00+08:00", 60, "watch")
	b := quantity("B", hr, "2026-11-01T09:00:00+08:00", "2026-11-01T09:00:00+08:00", 70, "watch")

	res := e.must(200, "POST", "/v1/ingest", e.device, []any{a, b})
	if res["received"] != 2.0 || res["new"] != 2.0 || res["deleted"] != 0.0 {
		t.Fatalf("first ingest: %v", res)
	}
	// Re-delivery of A with a corrected value updates in place.
	a["quantity"] = map[string]any{"value": 61, "unit": "count/min"}
	res = e.must(200, "POST", "/v1/ingest", e.device, []any{a, map[string]any{"deleted": []string{"B", "C"}}})
	if res["new"] != 0.0 || res["deleted"] != 2.0 {
		t.Fatalf("second ingest: %v", res)
	}

	got := e.must(200, "GET", "/v1/samples?type="+hr, e.agent, nil)
	if ids := uuids(t, got); !equal(ids, []string{"A"}) {
		t.Fatalf("live samples = %v", ids)
	}
	if v := got["samples"].([]any)[0].(map[string]any)["quantity"].(map[string]any)["value"]; v != 61.0 {
		t.Fatalf("A not updated: %v", v)
	}

	// C was tombstoned before it ever arrived: it must stay deleted, and
	// re-sending B must not resurrect it.
	c := quantity("C", hr, "2026-11-01T10:00:00+08:00", "2026-11-01T10:00:00+08:00", 80, "watch")
	e.must(200, "POST", "/v1/ingest", e.device, []any{b, c})
	if ids := uuids(t, e.must(200, "GET", "/v1/samples?type="+hr, e.agent, nil)); !equal(ids, []string{"A"}) {
		t.Fatalf("after late arrival = %v", ids)
	}

	// Malformed elements are skipped rather than wedging the batch.
	res = e.must(200, "POST", "/v1/ingest", e.device, []any{map[string]any{"uuid": "X"}, 42})
	if res["rejected"] != 2.0 {
		t.Fatalf("rejected = %v", res)
	}
	e.must(400, "POST", "/v1/ingest", e.device, map[string]any{"not": "an array"})

	st := e.must(200, "GET", "/v1/status", e.agent, nil)
	if st["samples"] != 1.0 || st["lastIngestAt"] == nil || st["lastDeviceSeenAt"] == nil {
		t.Fatalf("status = %v", st)
	}
	types := e.must(200, "GET", "/v1/types", e.agent, nil)["types"].([]any)
	if len(types) != 1 || types[0].(map[string]any)["count"] != 1.0 {
		t.Fatalf("types = %v", types)
	}
}

func TestGzipIngestAndLatest(t *testing.T) {
	e := newEnv(t)
	batch, _ := json.Marshal([]any{
		quantity("A", hr, "2026-11-01T08:00:00+08:00", "2026-11-01T08:00:00+08:00", 60, "watch"),
		// Later in absolute time despite the smaller wall-clock string.
		quantity("B", hr, "2026-11-01T01:30:00Z", "2026-11-01T01:30:00Z", 62, "watch"),
	})
	status, out := e.call("POST", "/v1/ingest", e.device, batch, true)
	if status != 200 || out.(map[string]any)["new"] != 2.0 {
		t.Fatalf("gzip ingest: %d %v", status, out)
	}
	if status, _ := e.call("POST", "/v1/ingest", e.device, []byte("not gzip"), false); status != 400 {
		t.Fatalf("plain garbage: %d", status)
	}
	latest := e.must(200, "GET", "/v1/latest", e.device, nil)
	if latest[hr] != "2026-11-01T01:30:00Z" {
		t.Fatalf("latest = %v", latest)
	}
}

func TestSamplesRangeAndPagination(t *testing.T) {
	e := newEnv(t)
	sleep := "HKCategoryTypeIdentifierSleepAnalysis"
	night := map[string]any{
		"uuid": "N", "kind": "category", "type": sleep, "value": 3,
		"startDate": "2026-10-31T23:00:00+08:00", "endDate": "2026-11-01T07:00:00+08:00",
	}
	nap := map[string]any{
		"uuid": "P", "kind": "category", "type": sleep, "value": 3,
		"startDate": "2026-11-01T13:00:00+08:00", "endDate": "2026-11-01T13:30:00+08:00",
	}
	early := map[string]any{
		"uuid": "E", "kind": "category", "type": sleep, "value": 3,
		"startDate": "2026-10-30T23:00:00+08:00", "endDate": "2026-10-31T06:00:00+08:00",
	}
	e.must(200, "POST", "/v1/ingest", e.device, []any{night, nap, early})

	q := url.Values{"type": {sleep}, "start": {"2026-11-01T00:00:00+08:00"}, "end": {"2026-11-02T00:00:00+08:00"}}
	// The night started before the window but overlaps it.
	if ids := uuids(t, e.must(200, "GET", "/v1/samples?"+q.Encode(), e.agent, nil)); !equal(ids, []string{"N", "P"}) {
		t.Fatalf("overlap = %v", ids)
	}
	// Unencoded "+" (a space after decoding) is tolerated.
	raw := "/v1/samples?type=" + sleep + "&start=2026-11-01T12:00:00+08:00"
	if ids := uuids(t, e.must(200, "GET", raw, e.agent, nil)); !equal(ids, []string{"P"}) {
		t.Fatalf("unencoded plus = %v", ids)
	}

	var batch []any
	for i := range 5 {
		ts := fmt.Sprintf("2026-11-01T08:0%d:00+08:00", i)
		src := "watch"
		if i == 4 {
			src = "phone"
		}
		batch = append(batch, quantity(fmt.Sprintf("H%d", i), hr, ts, ts, 60, src))
	}
	// A point sample exactly on the window start is included.
	batch = append(batch, quantity("H00", hr, "2026-11-01T08:00:00+08:00", "2026-11-01T08:00:00+08:00", 60, "watch"))
	e.must(200, "POST", "/v1/ingest", e.device, batch)

	var all []string
	cursor := ""
	pages := 0
	for {
		q := url.Values{"type": {hr}, "limit": {"2"}, "start": {"2026-11-01T08:00:00+08:00"}}
		if cursor != "" {
			q.Set("cursor", cursor)
		}
		page := e.must(200, "GET", "/v1/samples?"+q.Encode(), e.agent, nil)
		all = append(all, uuids(t, page)...)
		pages++
		next, _ := page["nextCursor"].(string)
		if next == "" {
			break
		}
		cursor = next
	}
	if !equal(all, []string{"H0", "H00", "H1", "H2", "H3", "H4"}) || pages != 3 {
		t.Fatalf("paged = %v in %d pages", all, pages)
	}
	if ids := uuids(t, e.must(200, "GET", "/v1/samples?type="+hr+"&source=phone", e.agent, nil)); !equal(ids, []string{"H4"}) {
		t.Fatalf("source filter = %v", ids)
	}
	e.must(400, "GET", "/v1/samples", e.agent, nil)
	e.must(400, "GET", "/v1/samples?type="+hr+"&start=yesterday", e.agent, nil)
	e.must(400, "GET", "/v1/samples?type="+hr+"&limit=10001", e.agent, nil)
	e.must(400, "GET", "/v1/samples?type="+hr+"&cursor=bm9wZQ", e.agent, nil)
}

func TestStatisticsRangeReplace(t *testing.T) {
	e := newEnv(t)
	steps := "HKQuantityTypeIdentifierStepCount"
	day := func(d string, sum float64) map[string]any {
		return map[string]any{
			"startDate": "2026-11-0" + d + "T00:00:00+08:00", "endDate": fmt.Sprintf("2026-11-0%dT00:00:00+08:00", int(d[0]-'0')+1),
			"sumQuantity": sum,
		}
	}
	upload := func(start, end string, rows ...any) {
		e.must(200, "POST", "/v1/statistics", e.device, map[string]any{
			"type": steps, "interval": "day", "unit": "count", "timeZone": "Asia/Shanghai",
			"rangeStart": start, "rangeEnd": end, "statistics": rows,
		})
	}
	upload("2026-11-01T00:00:00+08:00", "2026-11-04T00:00:00+08:00", day("1", 100), day("2", 200), day("3", 300))
	// Recompute days 2–3: day 3 lost its samples, day 2 changed, day 1 untouched.
	upload("2026-11-02T00:00:00+08:00", "2026-11-04T00:00:00+08:00", day("2", 250))

	res := e.must(200, "GET", "/v1/statistics?type="+steps, e.agent, nil)
	rows := res["statistics"].([]any)
	if res["unit"] != "count" || len(rows) != 2 {
		t.Fatalf("statistics = %v", res)
	}
	if r := rows[1].(map[string]any); r["sumQuantity"] != 250.0 || r["timeZone"] != "Asia/Shanghai" {
		t.Fatalf("day 2 = %v", r)
	}
	// Overlap: a window starting mid-day 2 still returns day 2.
	q := url.Values{"type": {steps}, "start": {"2026-11-02T12:00:00+08:00"}}
	if rows := e.must(200, "GET", "/v1/statistics?"+q.Encode(), e.agent, nil)["statistics"].([]any); len(rows) != 1 {
		t.Fatalf("overlap rows = %v", rows)
	}
	if rows := e.must(200, "GET", "/v1/statistics?type="+steps+"&interval=hour", e.agent, nil)["statistics"].([]any); len(rows) != 0 {
		t.Fatalf("hour rows = %v", rows)
	}
	e.must(400, "POST", "/v1/statistics", e.device, map[string]any{"type": steps, "interval": "week", "unit": "count"})
	e.must(400, "GET", "/v1/statistics?type="+steps+"&interval=week", e.agent, nil)
}

func TestActivitySummariesAndCharacteristics(t *testing.T) {
	e := newEnv(t)
	summary := func(date string, energy float64) map[string]any {
		return map[string]any{
			"dateComponents": date, "activityMoveMode": 1, "paused": false,
			"activeEnergyBurned": energy, "activeEnergyBurnedGoal": 600,
			"appleExerciseTime": 32, "exerciseTimeGoal": 30,
			"appleStandHours": 10, "standHoursGoal": 12,
		}
	}
	e.must(200, "POST", "/v1/activity-summaries", e.device, []any{summary("2026-10-31", 400), summary("2026-11-01", 500)})
	e.must(200, "POST", "/v1/activity-summaries", e.device, []any{summary("2026-11-01", 520)})
	got := e.must(200, "GET", "/v1/activity-summaries?start=2026-11-01&end=2026-11-01", e.agent, nil)["activitySummaries"].([]any)
	if len(got) != 1 || got[0].(map[string]any)["activeEnergyBurned"] != 520.0 {
		t.Fatalf("activity = %v", got)
	}
	e.must(400, "POST", "/v1/activity-summaries", e.device, []any{map[string]any{"dateComponents": "11/01"}})

	if c := e.must(200, "GET", "/v1/characteristics", e.agent, nil); len(c) != 0 {
		t.Fatalf("empty characteristics = %v", c)
	}
	e.must(200, "PUT", "/v1/characteristics", e.device, map[string]any{"biologicalSex": 2, "dateOfBirth": "1995-01-01"})
	if c := e.must(200, "GET", "/v1/characteristics", e.agent, nil); c["biologicalSex"] != 2.0 {
		t.Fatalf("characteristics = %v", c)
	}
	e.must(400, "PUT", "/v1/characteristics", e.device, []any{})
}

func bodyMass(kg float64) map[string]any {
	return map[string]any{
		"kind": "quantity", "type": "HKQuantityTypeIdentifierBodyMass",
		"startDate": "2026-11-01T08:00:00+08:00", "endDate": "2026-11-01T08:00:00+08:00",
		"quantity": map[string]any{"value": kg, "unit": "kg"},
		"metadata": map[string]any{"HKWasUserEntered": true},
	}
}

func pending(t *testing.T, e *env) []map[string]any {
	t.Helper()
	var out []map[string]any
	for _, w := range e.must(200, "GET", "/v1/writes/pending", e.device, nil)["writes"].([]any) {
		out = append(out, w.(map[string]any))
	}
	return out
}

func TestWritesLifecycle(t *testing.T) {
	e := newEnv(t)

	w1 := e.must(201, "POST", "/v1/writes", e.agent, map[string]any{"op": "save", "object": bodyMass(72.5)})
	sid := w1["syncIdentifier"].(string)
	if w1["status"] != "pending" || w1["syncVersion"] != 1.0 || sid == "" {
		t.Fatalf("w1 = %v", w1)
	}
	// An update queued before w1 ran must wait behind it.
	w2 := e.must(201, "POST", "/v1/writes", e.agent, map[string]any{"op": "save", "syncIdentifier": sid, "object": bodyMass(72.0)})
	if w2["syncVersion"] != 2.0 {
		t.Fatalf("w2 = %v", w2)
	}
	other := e.must(201, "POST", "/v1/writes", e.agent, map[string]any{"op": "save", "syncIdentifier": "meal-1", "object": map[string]any{
		"kind": "correlation", "type": "HKCorrelationTypeIdentifierFood",
		"startDate": "2026-11-01T12:30:00+08:00", "endDate": "2026-11-01T12:30:00+08:00",
		"metadata": map[string]any{"HKFoodType": "午餐"},
		"objects": []any{map[string]any{"kind": "quantity", "type": "HKQuantityTypeIdentifierDietaryProtein",
			"quantity": map[string]any{"value": 32, "unit": "g"}}},
	}})
	if other["syncVersion"] != 1.0 {
		t.Fatalf("custom syncIdentifier = %v", other)
	}

	p := pending(t, e)
	if len(p) != 2 || p[0]["id"] != w1["id"] || p[1]["id"] != other["id"] {
		t.Fatalf("pending = %v", p)
	}
	if r := p[0]["replaceUUIDs"].([]any); len(r) != 0 {
		t.Fatalf("first write replaceUUIDs = %v", r)
	}
	if r := p[0]["replaceTypes"].([]any); len(r) != 0 {
		t.Fatalf("first write replaceTypes = %v", r)
	}

	results := []any{
		map[string]any{"id": w1["id"], "status": "written", "uuids": []string{"HK-1"}},
		map[string]any{"id": other["id"], "status": "written", "uuids": []string{"HK-C", "HK-C0"}},
	}
	if res := e.must(200, "POST", "/v1/writes/results", e.device, results); res["updated"] != 2.0 {
		t.Fatalf("results = %v", res)
	}
	// Re-reporting is a no-op.
	if res := e.must(200, "POST", "/v1/writes/results", e.device, results); res["updated"] != 0.0 {
		t.Fatalf("re-report = %v", res)
	}

	p = pending(t, e)
	if len(p) != 1 || p[0]["id"] != w2["id"] || fmt.Sprint(p[0]["replaceUUIDs"]) != "[HK-1]" ||
		fmt.Sprint(p[0]["replaceTypes"]) != "[HKQuantityTypeIdentifierBodyMass]" {
		t.Fatalf("pending after w1 = %v", p)
	}
	// The user deleted the sample in Health meanwhile.
	e.must(200, "POST", "/v1/writes/results", e.device, []any{
		map[string]any{"id": w2["id"], "status": "conflict", "error": "previous objects no longer exist in Health"},
	})
	if got := e.must(200, "GET", "/v1/writes/"+w2["id"].(string), e.agent, nil); got["status"] != "conflict" || got["error"] == nil {
		t.Fatalf("w2 = %v", got)
	}

	// After a conflict nothing is left to replace.
	w3 := e.must(201, "POST", "/v1/writes", e.agent, map[string]any{"op": "save", "syncIdentifier": sid, "object": bodyMass(71.8)})
	if w3["syncVersion"] != 3.0 {
		t.Fatalf("w3 = %v", w3)
	}
	p = pending(t, e)
	if len(p) != 1 || len(p[0]["replaceUUIDs"].([]any)) != 0 {
		t.Fatalf("pending w3 = %v", p)
	}
	e.must(200, "POST", "/v1/writes/results", e.device, []any{map[string]any{"id": w3["id"], "status": "written", "uuids": []string{"HK-3"}}})

	del := e.must(201, "POST", "/v1/writes", e.agent, map[string]any{"op": "delete", "syncIdentifier": sid})
	if _, ok := del["syncVersion"]; ok || del["object"] != nil {
		t.Fatalf("delete = %v", del)
	}
	p = pending(t, e)
	if len(p) != 1 || p[0]["op"] != "delete" || fmt.Sprint(p[0]["replaceUUIDs"]) != "[HK-3]" {
		t.Fatalf("pending delete = %v", p)
	}
	e.must(200, "POST", "/v1/writes/results", e.device, []any{map[string]any{"id": del["id"], "status": "written"}})
	if p := pending(t, e); len(p) != 0 {
		t.Fatalf("pending at end = %v", p)
	}

	// Replacing a meal targets the correlation and its member types.
	e.must(201, "POST", "/v1/writes", e.agent, map[string]any{"op": "delete", "syncIdentifier": "meal-1"})
	p = pending(t, e)
	if len(p) != 1 || fmt.Sprint(p[0]["replaceUUIDs"]) != "[HK-C HK-C0]" ||
		fmt.Sprint(p[0]["replaceTypes"]) != "[HKCorrelationTypeIdentifierFood HKQuantityTypeIdentifierDietaryProtein]" {
		t.Fatalf("pending meal delete = %v", p)
	}
	e.must(200, "POST", "/v1/writes/results", e.device, []any{map[string]any{"id": p[0]["id"], "status": "written"}})

	list := e.must(200, "GET", "/v1/writes?syncIdentifier="+sid, e.agent, nil)["writes"].([]any)
	if len(list) != 4 || list[0].(map[string]any)["id"] != del["id"] {
		t.Fatalf("list = %v", list)
	}
	if got := e.must(200, "GET", "/v1/writes?status=written&limit=1", e.agent, nil)["writes"].([]any); len(got) != 1 {
		t.Fatalf("filtered list = %v", got)
	}
	if got := e.must(200, "GET", "/v1/writes/"+w1["id"].(string), e.agent, nil); fmt.Sprint(got["uuids"]) != "[HK-1]" {
		t.Fatalf("w1 uuids = %v", got)
	}
}

func TestWriteValidation(t *testing.T) {
	e := newEnv(t)
	bad := []map[string]any{
		{"op": "save"},
		{"op": "upsert", "object": bodyMass(70)},
		{"op": "delete", "syncIdentifier": "never-written"},
		{"op": "delete"},
	}
	statuses := []int{400, 400, 404, 400}
	for i, req := range bad {
		e.must(statuses[i], "POST", "/v1/writes", e.agent, req)
	}
	mutate := func(f func(o map[string]any)) map[string]any {
		o := bodyMass(70)
		f(o)
		return map[string]any{"op": "save", "object": o}
	}
	for name, req := range map[string]map[string]any{
		"reserved metadata": mutate(func(o map[string]any) { o["metadata"] = map[string]any{"HKMetadataKeySyncVersion": 9} }),
		"kind/type":         mutate(func(o map[string]any) { o["kind"] = "category" }),
		"uuid":              mutate(func(o map[string]any) { o["uuid"] = "X" }),
		"end before start":  mutate(func(o map[string]any) { o["endDate"] = "2026-11-01T07:00:00+08:00" }),
		"no unit":           mutate(func(o map[string]any) { o["quantity"] = map[string]any{"value": 70} }),
		"string value":      mutate(func(o map[string]any) { o["quantity"] = map[string]any{"value": "70", "unit": "kg"} }),
		"no dates":          mutate(func(o map[string]any) { delete(o, "startDate") }),
		"unknown kind":      mutate(func(o map[string]any) { o["kind"] = "medication" }),
		"empty correlation": {"op": "save", "object": map[string]any{"kind": "correlation", "type": "HKCorrelationTypeIdentifierFood",
			"startDate": "2026-11-01T12:30:00+08:00", "endDate": "2026-11-01T12:30:00+08:00", "objects": []any{}}},
		"float category": {"op": "save", "object": map[string]any{"kind": "category", "type": "HKCategoryTypeIdentifierMindfulSession",
			"startDate": "2026-11-01T12:30:00+08:00", "endDate": "2026-11-01T12:40:00+08:00", "value": 0.5}},
	} {
		if status, out := e.call("POST", "/v1/writes", e.agent, req, false); status != 400 {
			t.Errorf("%s: status %d (%v)", name, status, out)
		}
	}
	e.must(400, "POST", "/v1/writes/results", e.device, []any{map[string]any{"id": "x", "status": "done"}})
	e.must(400, "GET", "/v1/writes?status=done", e.agent, nil)
	e.must(404, "GET", "/v1/writes/unknown", e.agent, nil)
}

func TestDeviceBrowsesAndWipes(t *testing.T) {
	e := newEnv(t)
	mk := func(uuid, start string) map[string]any {
		return map[string]any{"uuid": uuid, "kind": "quantity", "type": "HKQuantityTypeIdentifierStepCount",
			"startDate": start, "endDate": start, "quantity": map[string]any{"value": 1, "unit": "count"}}
	}
	e.must(200, "POST", "/v1/ingest", e.device, []any{
		mk("A", "2026-11-01T08:00:00+08:00"), mk("B", "2026-11-01T09:00:00+08:00"), mk("C", "2026-11-01T10:00:00+08:00"),
	})
	types := e.must(200, "GET", "/v1/types", e.device, nil)["types"].([]any)
	if len(types) != 1 || types[0].(map[string]any)["count"] != 3.0 {
		t.Fatalf("types = %v", types)
	}
	page := e.must(200, "GET", "/v1/samples?type=HKQuantityTypeIdentifierStepCount&order=desc&limit=2", e.device, nil)
	got := page["samples"].([]any)
	if len(got) != 2 || got[0].(map[string]any)["uuid"] != "C" || got[1].(map[string]any)["uuid"] != "B" || page["nextCursor"] == nil {
		t.Fatalf("desc page = %v", page)
	}
	rest := e.must(200, "GET", "/v1/samples?type=HKQuantityTypeIdentifierStepCount&order=desc&limit=2&cursor="+page["nextCursor"].(string), e.device, nil)
	if r := rest["samples"].([]any); len(r) != 1 || r[0].(map[string]any)["uuid"] != "A" {
		t.Fatalf("desc page 2 = %v", rest)
	}

	if st := e.must(200, "GET", "/v1/status", e.agent, nil); st["lastDeviceSeenAt"] == nil {
		t.Fatalf("status = %v", st)
	}

	before := e.must(200, "GET", "/v1/status", e.device, nil)["dataId"]
	if before == "" || before == nil {
		t.Fatal("status has no dataId")
	}
	e.must(200, "DELETE", "/v1/data", e.device, nil)
	if st := e.must(200, "GET", "/v1/status", e.device, nil); st["samples"] != 0.0 || st["dataId"] == before {
		t.Fatalf("after wipe = %v (dataId before %v)", st, before)
	}
	e.must(200, "GET", "/v1/latest", e.device, nil) // still connected
}

func TestAnchorsMoveWithTheirSamples(t *testing.T) {
	e := newEnv(t)
	ingest := func(uuid, base, anchor string) map[string]any {
		t.Helper()
		headers := map[string]string{AnchorTypeHeader: hr, AnchorHeader: anchor}
		if base != "" {
			headers[BaseAnchorHeader] = base
		}
		return e.mustWith(200, "POST", "/v1/ingest", e.device, headers,
			[]any{quantity(uuid, hr, "2026-11-01T08:00:00+08:00", "2026-11-01T08:00:00+08:00", 60, "watch")})
	}
	anchors := func() map[string]any {
		t.Helper()
		return e.must(200, "GET", "/v1/anchors", e.device, nil)["anchors"].(map[string]any)
	}

	if res := ingest("A", "", "a1"); res["anchor"] != "saved" {
		t.Fatalf("first batch = %v", res)
	}
	if res := ingest("B", "a1", "a2"); res["anchor"] != "saved" {
		t.Fatalf("second batch = %v", res)
	}
	// Sent again (its reply was lost): it already led here, so saved.
	if res := ingest("B", "a1", "a2"); res["anchor"] != "saved" || res["new"] != 0.0 {
		t.Fatalf("retried batch = %v", res)
	}
	if got := anchors(); got[hr] != "a2" {
		t.Fatalf("anchors = %v", got)
	}

	// The server lost its data; a batch read from before is stored but
	// can't move the anchor, so the phone starts that type over.
	e.must(200, "DELETE", "/v1/data", e.device, nil)
	if got := anchors(); len(got) != 0 {
		t.Fatalf("anchors after wipe = %v", got)
	}
	if res := ingest("C", "a2", "a3"); res["anchor"] != "stale" || res["new"] != 1.0 {
		t.Fatalf("stale batch = %v", res)
	}
	if got := anchors(); len(got) != 0 {
		t.Fatalf("stale batch moved the anchor: %v", got)
	}

	e.must(200, "PUT", "/v1/anchors", e.device, map[string]any{"anchors": map[string]string{hr: "x"}})
	if got := anchors(); got[hr] != "x" {
		t.Fatalf("set = %v", got)
	}
	e.mustWith(400, "POST", "/v1/ingest", e.device, map[string]string{AnchorHeader: "z"}, []any{})

	// A newly paired iPhone starts over.
	if err := e.store.StartPairing(context.Background(), "222222"); err != nil {
		t.Fatal(err)
	}
	newKey := "Zx9Yw8Vu7Ts6Rq5Po4Nm3Lk2Jh1Gf0EdCbA9z8y7x6w"
	e.must(200, "POST", "/v1/pair", "", map[string]string{"code": "222222", "key": newKey})
	if got := e.must(200, "GET", "/v1/anchors", newKey, nil)["anchors"].(map[string]any); len(got) != 0 {
		t.Fatalf("anchors after pairing = %v", got)
	}
}

// keyID finds a credential's id by name.
func (e *env) keyID(name string) string {
	e.t.Helper()
	for _, k := range e.must(200, "GET", "/v1/keys", e.device, nil)["keys"].([]any) {
		if k := k.(map[string]any); k["name"] == name {
			return k["id"].(string)
		}
	}
	e.t.Fatalf("no key named %q", name)
	return ""
}

func TestNewEndpointScopes(t *testing.T) {
	e := newEnv(t)
	agentID := e.keyID("agent")
	for _, key := range []string{e.device, e.agent, e.reader} {
		e.must(200, "GET", "/v1/changes", key, nil)
		e.must(200, "GET", "/v1/authorization", key, nil)
		e.must(200, "GET", "/v1/medications", key, nil)
	}
	for _, key := range []string{e.agent, e.reader} {
		e.must(403, "PUT", "/v1/authorization", key, map[string]any{"share": map[string]string{}})
		e.must(403, "PUT", "/v1/medications", key, map[string]any{"medications": []any{}})
		e.must(403, "GET", "/v1/keys/"+agentID+"/activity", key, nil)
	}
	for _, path := range []string{"/v1/changes", "/v1/authorization", "/v1/medications", "/v1/keys/" + agentID + "/activity"} {
		e.must(401, "GET", path, "", nil)
	}
}

func activity(t *testing.T, e *env, id, query string) ([]map[string]any, any) {
	t.Helper()
	res := e.must(200, "GET", "/v1/keys/"+id+"/activity"+query, e.device, nil)
	var out []map[string]any
	for _, a := range res["activity"].([]any) {
		out = append(out, a.(map[string]any))
	}
	return out, res["next"]
}

func TestAPIActivity(t *testing.T) {
	e := newEnv(t)
	agentID, readerID, ownerID := e.keyID("agent"), e.keyID("reader"), e.keyID("iPhone")
	e.must(200, "POST", "/v1/ingest", e.device, []any{
		quantity("A", hr, "2026-11-01T08:00:00+08:00", "2026-11-01T08:00:00+08:00", 60, "watch"),
		quantity("B", hr, "2026-11-01T09:00:00+08:00", "2026-11-01T09:00:00+08:00", 61, "watch"),
	})
	// The owner's own requests aren't recorded.
	e.must(200, "GET", "/v1/samples?type="+hr, e.device, nil)
	if got, next := activity(t, e, ownerID, ""); len(got) != 0 || next != nil {
		t.Fatalf("owner activity = %v %v", got, next)
	}

	q := url.Values{"type": {hr}, "start": {"2026-11-01T00:00:00+08:00"}, "end": {"2026-11-02T00:00:00+08:00"}}
	e.must(200, "GET", "/v1/samples?"+q.Encode(), e.agent, nil)
	e.must(200, "GET", "/v1/statistics?type=HKQuantityTypeIdentifierStepCount&interval=hour", e.agent, nil)
	w := e.must(201, "POST", "/v1/writes", e.agent, map[string]any{"op": "save", "object": bodyMass(72)})
	e.must(200, "GET", "/v1/writes/"+w["id"].(string), e.agent, nil)
	e.must(200, "GET", "/v1/changes?type="+hr+"&type=HKQuantityTypeIdentifierStepCount", e.agent, nil)
	e.must(400, "POST", "/v1/writes", e.agent, map[string]any{"op": "save", "object": map[string]any{"kind": "quantity", "type": hr}})
	e.must(403, "POST", "/v1/writes", e.reader, map[string]any{"op": "save", "object": bodyMass(72)})

	got, next := activity(t, e, agentID, "")
	if len(got) != 6 || next != nil {
		t.Fatalf("agent activity = %v (next %v)", got, next)
	}
	// Newest first.
	want := []string{
		`{"at":"*","method":"POST","path":"/v1/writes","status":400,"type":"HKQuantityTypeIdentifierHeartRate"}`,
		`{"at":"*","count":2,"method":"GET","path":"/v1/changes","status":200,"type":"HKQuantityTypeIdentifierHeartRate,HKQuantityTypeIdentifierStepCount"}`,
		`{"at":"*","method":"GET","path":"/v1/writes/{id}","status":200,"writeId":"` + w["id"].(string) + `"}`,
		`{"at":"*","count":1,"method":"POST","path":"/v1/writes","status":201,"type":"HKQuantityTypeIdentifierBodyMass","writeId":"` + w["id"].(string) + `"}`,
		`{"at":"*","count":0,"interval":"hour","method":"GET","path":"/v1/statistics","status":200,"type":"HKQuantityTypeIdentifierStepCount"}`,
		`{"at":"*","count":2,"end":"2026-11-02T00:00:00+08:00","method":"GET","path":"/v1/samples","start":"2026-11-01T00:00:00+08:00","status":200,"type":"HKQuantityTypeIdentifierHeartRate"}`,
	}
	for i, a := range got {
		if _, err := store.ParseTimestamp(a["at"].(string)); err != nil {
			t.Fatalf("activity[%d].at = %v", i, a["at"])
		}
		a["at"] = "*"
		b, _ := json.Marshal(a)
		if string(b) != want[i] {
			t.Errorf("activity[%d] = %s\nwant          %s", i, b, want[i])
		}
	}
	// A refused request is recorded too.
	if got, _ := activity(t, e, readerID, ""); len(got) != 1 || got[0]["status"] != 403.0 || got[0]["path"] != "/v1/writes" {
		t.Fatalf("reader activity = %v", got)
	}

	// Paging.
	page, next := activity(t, e, agentID, "?limit=4")
	if len(page) != 4 || next == nil {
		t.Fatalf("page 1 = %d entries, next %v", len(page), next)
	}
	rest, next2 := activity(t, e, agentID, "?limit=4&before="+next.(string))
	if len(rest) != 2 || next2 != nil || rest[1]["path"] != "/v1/samples" {
		t.Fatalf("page 2 = %v, next %v", rest, next2)
	}
	e.must(400, "GET", "/v1/keys/"+agentID+"/activity?limit=501", e.device, nil)
	e.must(400, "GET", "/v1/keys/"+agentID+"/activity?before=x", e.device, nil)
	e.must(404, "GET", "/v1/keys/nope/activity", e.device, nil)

	// Revoking a key deletes its activity with it.
	e.must(200, "DELETE", "/v1/keys/"+agentID, e.device, nil)
	e.must(404, "GET", "/v1/keys/"+agentID+"/activity", e.device, nil)
}

type changesPage struct {
	Samples []struct {
		UUID string `json:"uuid"`
	} `json:"samples"`
	Deleted []store.DeletedObject `json:"deleted"`
	Anchor  string                `json:"anchor"`
	More    bool                  `json:"more"`
}

func (p changesPage) uuids() []string {
	out := []string{}
	for _, s := range p.Samples {
		out = append(out, s.UUID)
	}
	return out
}

func (e *env) changes(query string) changesPage {
	e.t.Helper()
	m := e.must(200, "GET", "/v1/changes"+query, e.agent, nil)
	b, _ := json.Marshal(m)
	var p changesPage
	if err := json.Unmarshal(b, &p); err != nil {
		e.t.Fatal(err)
	}
	return p
}

func TestChangeFeed(t *testing.T) {
	e := newEnv(t)
	steps := "HKQuantityTypeIdentifierStepCount"
	ts := "2026-11-01T08:00:00+08:00"
	a := quantity("A", hr, ts, ts, 60, "watch")
	e.must(200, "POST", "/v1/ingest", e.device, []any{a, quantity("B", hr, ts, ts, 61, "watch"), quantity("C", steps, ts, ts, 5, "phone")})

	all := e.changes("")
	if !equal(all.uuids(), []string{"A", "B", "C"}) || len(all.Deleted) != 0 || all.More || all.Anchor == "" {
		t.Fatalf("from the beginning = %+v", all)
	}
	p := e.changes("?limit=2")
	if !equal(p.uuids(), []string{"A", "B"}) || !p.More {
		t.Fatalf("page 1 = %+v", p)
	}
	if p = e.changes("?limit=2&anchor=" + p.Anchor); !equal(p.uuids(), []string{"C"}) || p.More || p.Anchor != all.Anchor {
		t.Fatalf("page 2 = %+v", p)
	}
	none := "HKQuantityTypeIdentifierBodyMass" // no data: filters nothing in
	for _, q := range []string{"?type=" + hr, "?type=" + hr + "," + none, "?type=" + none + "&type=" + hr} {
		if p := e.changes(q); !equal(p.uuids(), []string{"A", "B"}) {
			t.Fatalf("%s = %+v", q, p)
		}
	}
	e.must(400, "GET", "/v1/changes?type="+hr+",nope", e.agent, nil)
	if p := e.changes("?anchor=" + all.Anchor); len(p.Samples) != 0 || p.Anchor != all.Anchor {
		t.Fatalf("nothing new = %+v", p)
	}

	// A changed sample reappears; an unchanged re-delivery doesn't.
	a["quantity"] = map[string]any{"value": 65, "unit": "count/min"}
	e.must(200, "POST", "/v1/ingest", e.device, []any{a, quantity("C", steps, ts, ts, 5, "phone")})
	changed := e.changes("?anchor=" + all.Anchor)
	if !equal(changed.uuids(), []string{"A"}) {
		t.Fatalf("after a change = %+v", changed)
	}
	if p := e.changes(""); !equal(p.uuids(), []string{"B", "C", "A"}) {
		t.Fatalf("ordered by change = %+v", p)
	}

	// A deletion appears once; a tombstone that arrived before its sample
	// never enters the feed.
	e.must(200, "POST", "/v1/ingest", e.device, []any{map[string]any{"deleted": []string{"B", "D"}}})
	e.must(200, "POST", "/v1/ingest", e.device, []any{quantity("D", hr, ts, ts, 70, "watch"), quantity("B", hr, ts, ts, 99, "watch")})
	del := e.changes("?anchor=" + changed.Anchor)
	if len(del.Samples) != 0 || fmt.Sprint(del.Deleted) != "[{B "+hr+"}]" {
		t.Fatalf("deleted = %+v", del)
	}
	if p := e.changes("?anchor=" + del.Anchor); len(p.Samples)+len(p.Deleted) != 0 {
		t.Fatalf("after the deletion = %+v", p)
	}

	// limit=0 is just the current anchor.
	if p := e.changes("?limit=0"); len(p.Samples) != 0 || p.Anchor != del.Anchor || p.More {
		t.Fatalf("limit=0 = %+v", p)
	}
	for _, q := range []string{"?anchor=bm9wZQ", "?anchor=!", "?limit=5001", "?limit=-1", "?wait=61", "?wait=x"} {
		e.must(400, "GET", "/v1/changes"+q, e.agent, nil)
	}

	// After a wipe an old anchor is expired; starting over works.
	e.must(200, "DELETE", "/v1/data", e.device, nil)
	status, out := e.call("GET", "/v1/changes?anchor="+del.Anchor, e.agent, nil, false)
	if status != 410 || out.(map[string]any)["error"] != "anchor expired: the server's data was cleared; start again without an anchor" {
		t.Fatalf("old anchor after wipe: %d %v", status, out)
	}
	if p := e.changes(""); len(p.Samples)+len(p.Deleted) != 0 {
		t.Fatalf("after wipe = %+v", p)
	}
}

// waitChanges starts a waiting change-feed request; the result arrives on
// the returned channel.
func (e *env) waitChanges(query string) <-chan string {
	return e.waitGet("/v1/changes"+query, e.agent)
}

// waitGet sends a GET that may wait; the channel gets "<status> <body>".
func (e *env) waitGet(path, token string) <-chan string {
	done := make(chan string, 1)
	go func() {
		req, _ := http.NewRequest(http.MethodGet, e.srv.URL+path, nil)
		req.Header.Set("Authorization", "Bearer "+token)
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			done <- err.Error()
			return
		}
		defer resp.Body.Close()
		b, _ := io.ReadAll(resp.Body)
		done <- fmt.Sprintf("%d %s", resp.StatusCode, b)
	}()
	return done
}

func TestChangeFeedWaits(t *testing.T) {
	e := newEnv(t)
	ts := "2026-11-01T08:00:00+08:00"
	head := e.changes("?limit=0").Anchor

	// Waits through a change of another type, wakes for a matching one.
	start := time.Now()
	done := e.waitChanges("?wait=30&type=" + hr + "&anchor=" + head)
	time.Sleep(200 * time.Millisecond)
	e.must(200, "POST", "/v1/ingest", e.device, []any{quantity("S", "HKQuantityTypeIdentifierStepCount", ts, ts, 5, "phone")})
	select {
	case got := <-done:
		t.Fatalf("woke for another type: %s", got)
	case <-time.After(300 * time.Millisecond):
	}
	e.must(200, "POST", "/v1/ingest", e.device, []any{quantity("H", hr, ts, ts, 60, "watch")})
	select {
	case got := <-done:
		if !strings.HasPrefix(got, "200 ") || !strings.Contains(got, `"uuid":"H"`) || strings.Contains(got, `"uuid":"S"`) {
			t.Fatalf("woken = %s", got)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("not woken by a matching ingest")
	}
	if time.Since(start) > 10*time.Second {
		t.Fatal("waited out the timeout")
	}

	// With nothing new, it answers empty when the time is up.
	head = e.changes("?limit=0").Anchor
	start = time.Now()
	p := e.changes("?wait=1&anchor=" + head)
	if len(p.Samples) != 0 || p.Anchor != head || time.Since(start) < time.Second {
		t.Fatalf("timed out = %+v after %v", p, time.Since(start))
	}

	// A wipe tells a waiting request its anchor expired.
	done = e.waitChanges("?wait=30&anchor=" + head)
	time.Sleep(200 * time.Millisecond)
	e.must(200, "DELETE", "/v1/data", e.device, nil)
	select {
	case got := <-done:
		if !strings.HasPrefix(got, "410 ") {
			t.Fatalf("after wipe = %s", got)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("not woken by the wipe")
	}
}

// A type that isn't one is an error, not "no data"; a close name is
// suggested.
func TestUnknownTypes(t *testing.T) {
	e := newEnv(t)
	ts := "2026-11-01T08:00:00+08:00"
	e.must(200, "POST", "/v1/ingest", e.device, []any{quantity("H", hr, ts, ts, 60, "watch")})

	for _, path := range []string{"/v1/samples?type=", "/v1/statistics?type=", "/v1/changes?type="} {
		got := e.must(400, "GET", path+"NotAType", e.agent, nil)
		if msg, _ := got["error"].(string); !strings.Contains(msg, `unknown type "NotAType"`) {
			t.Errorf("%s: %v", path, got)
		}
	}
	got := e.must(400, "GET", "/v1/samples?type=stepcount", e.agent, nil)
	if msg, _ := got["error"].(string); !strings.Contains(msg, "did you mean HKQuantityTypeIdentifierStepCount?") {
		t.Errorf("short name: %v", got)
	}

	// A real type with no data is empty, not an error.
	if got := e.must(200, "GET", "/v1/samples?type=HKQuantityTypeIdentifierStepCount", e.agent, nil); len(got["samples"].([]any)) != 0 {
		t.Errorf("no data: %v", got)
	}
	// A type the SDK snapshot doesn't know but the server has data of (one
	// newer than the snapshot) is fine.
	future := "HKQuantityTypeIdentifierFromTheFuture"
	e.must(200, "POST", "/v1/ingest", e.device, []any{quantity("F", future, ts, ts, 1, "watch")})
	if got := e.must(200, "GET", "/v1/samples?type="+future, e.agent, nil); len(got["samples"].([]any)) != 1 {
		t.Errorf("newer type: %v", got)
	}
}

func TestPendingWritesWait(t *testing.T) {
	e := newEnv(t)
	// Without an anchor it answers at once, with the anchor to wait from.
	head := e.must(200, "GET", "/v1/writes/pending?wait=30", e.device, nil)["anchor"].(string)

	// A write left pending (no access yet, say) doesn't end the wait;
	// the next one submitted does.
	e.must(201, "POST", "/v1/writes", e.agent, map[string]any{"op": "save", "object": bodyMass(72.5)})
	got := e.must(200, "GET", "/v1/writes/pending?wait=30&anchor="+head, e.device, nil)
	if got["anchor"] == head || len(got["writes"].([]any)) != 1 {
		t.Fatalf("after a submit = %v", got)
	}
	head = got["anchor"].(string)
	start := time.Now()
	done := e.waitGet("/v1/writes/pending?wait=30&anchor="+head, e.device)
	time.Sleep(200 * time.Millisecond)
	e.must(201, "POST", "/v1/writes", e.agent, map[string]any{"op": "save", "object": bodyMass(72.0)})
	select {
	case got := <-done:
		if !strings.HasPrefix(got, "200 ") || strings.Contains(got, `"anchor":"`+head+`"`) || strings.Count(got, `"op":"save"`) != 2 {
			t.Fatalf("woken = %s", got)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("not woken by a submit")
	}
	if time.Since(start) > 10*time.Second {
		t.Fatal("waited out the timeout")
	}

	// With nothing new, it answers when the time is up.
	head = e.must(200, "GET", "/v1/writes/pending", e.device, nil)["anchor"].(string)
	start = time.Now()
	got = e.must(200, "GET", "/v1/writes/pending?wait=1&anchor="+head, e.device, nil)
	if got["anchor"] != head || time.Since(start) < time.Second {
		t.Fatalf("timed out = %v after %v", got, time.Since(start))
	}
	e.must(400, "GET", "/v1/writes/pending?wait=61", e.device, nil)
}

func TestAuthorizationChecksWrites(t *testing.T) {
	e := newEnv(t)
	protein := "HKQuantityTypeIdentifierDietaryProtein"
	energy := "HKQuantityTypeIdentifierDietaryEnergyConsumed"
	meal := func(member string) map[string]any {
		return map[string]any{"op": "save", "object": map[string]any{
			"kind": "correlation", "type": "HKCorrelationTypeIdentifierFood",
			"startDate": "2026-11-01T12:30:00+08:00", "endDate": "2026-11-01T12:30:00+08:00",
			"objects": []any{map[string]any{"kind": "quantity", "type": member, "quantity": map[string]any{"value": 30, "unit": "g"}}},
		}}
	}
	steps := map[string]any{"op": "save", "object": map[string]any{
		"kind": "quantity", "type": "HKQuantityTypeIdentifierStepCount",
		"startDate": "2026-11-01T08:00:00+08:00", "endDate": "2026-11-01T08:10:00+08:00",
		"quantity": map[string]any{"value": 900, "unit": "count"},
	}}

	if got := e.must(200, "GET", "/v1/authorization", e.reader, nil); got["share"] != nil || got["updatedAt"] != nil || len(got) != 2 {
		t.Fatalf("before upload = %v", got)
	}
	// Unknown: nothing is checked.
	e.must(201, "POST", "/v1/writes", e.agent, meal(protein))

	share := map[string]string{
		"HKQuantityTypeIdentifierBodyMass":  "sharingAuthorized",
		energy:                              "sharingAuthorized",
		protein:                             "sharingDenied",
		"HKQuantityTypeIdentifierStepCount": "notDetermined",
		"HKWorkoutTypeIdentifier":           "sharingAuthorized",
		"HKQuantityTypeIdentifierActiveEnergyBurned":     "sharingAuthorized",
		"HKQuantityTypeIdentifierDistanceWalkingRunning": "sharingDenied",
	}
	if got := e.must(200, "PUT", "/v1/authorization", e.device, map[string]any{"share": share}); got["stored"] != 7.0 {
		t.Fatalf("put = %v", got)
	}
	e.must(400, "PUT", "/v1/authorization", e.device, map[string]any{"share": map[string]string{"X": "allowed"}})
	e.must(400, "PUT", "/v1/authorization", e.device, map[string]any{})
	got := e.must(200, "GET", "/v1/authorization", e.reader, nil)
	if len(got["share"].(map[string]any)) != 7 || got["updatedAt"] == nil {
		t.Fatalf("after upload = %v", got)
	}

	refused := func(req map[string]any, want string) {
		t.Helper()
		status, out := e.call("POST", "/v1/writes", e.agent, req, false)
		if status != 422 || out.(map[string]any)["error"] != want {
			t.Fatalf("status %d (%v), want 422 %q", status, out, want)
		}
	}
	e.must(201, "POST", "/v1/writes", e.agent, map[string]any{"op": "save", "object": bodyMass(72)})
	// The correlation type itself isn't authorized; its members are.
	e.must(201, "POST", "/v1/writes", e.agent, meal(energy))
	refused(meal(protein), "write access to "+protein+" is turned off for Rendu in Apple Health settings")
	e.must(201, "POST", "/v1/writes", e.agent, steps) // notDetermined: waits for the user
	refused(map[string]any{"op": "save", "object": map[string]any{
		"kind": "quantity", "type": "HKQuantityTypeIdentifierWalkingHeartRateAverage",
		"startDate": "2026-11-01T08:00:00+08:00", "endDate": "2026-11-01T08:00:00+08:00",
		"quantity": map[string]any{"value": 90, "unit": "count/min"},
	}}, "HealthKit doesn't allow apps to write HKQuantityTypeIdentifierWalkingHeartRateAverage")
	run := workout(map[string]any{"workoutActivityTypeName": "running"}, "HKQuantityTypeIdentifierActiveEnergyBurned")
	e.must(201, "POST", "/v1/writes", e.agent, map[string]any{"op": "save", "object": run})
	run = workout(map[string]any{"workoutActivityTypeName": "running"}, "HKQuantityTypeIdentifierDistanceWalkingRunning")
	refused(map[string]any{"op": "save", "object": run},
		"write access to HKQuantityTypeIdentifierDistanceWalkingRunning is turned off for Rendu in Apple Health settings")
	refused(map[string]any{"op": "save", "object": stateOfMind(nil)}, "HealthKit doesn't allow apps to write HKDataTypeStateOfMind")

	// Deleting checks the types of what the delete removes.
	w := e.must(201, "POST", "/v1/writes", e.agent, map[string]any{"op": "save", "syncIdentifier": "bm", "object": bodyMass(71)})
	e.must(200, "POST", "/v1/writes/results", e.device, []any{map[string]any{"id": w["id"], "status": "written", "uuids": []string{"HK-BM"}}})
	share["HKQuantityTypeIdentifierBodyMass"] = "sharingDenied"
	e.must(200, "PUT", "/v1/authorization", e.device, map[string]any{"share": share})
	refused(map[string]any{"op": "delete", "syncIdentifier": "bm"},
		"write access to HKQuantityTypeIdentifierBodyMass is turned off for Rendu in Apple Health settings")

	// Types carry their status when the phone reported one.
	e.must(200, "POST", "/v1/ingest", e.device, []any{
		quantity("A", hr, "2026-11-01T08:00:00+08:00", "2026-11-01T08:00:00+08:00", 60, "watch"),
		map[string]any{"uuid": "S", "kind": "quantity", "type": "HKQuantityTypeIdentifierStepCount",
			"startDate": "2026-11-01T08:00:00+08:00", "endDate": "2026-11-01T08:00:00+08:00",
			"quantity": map[string]any{"value": 1, "unit": "count"}},
	})
	for _, ti := range e.must(200, "GET", "/v1/types", e.agent, nil)["types"].([]any) {
		ti := ti.(map[string]any)
		if want := map[string]any{hr: nil, "HKQuantityTypeIdentifierStepCount": "notDetermined"}[ti["type"].(string)]; ti["share"] != want {
			t.Errorf("types: %v", ti)
		}
	}

	// Wiping the data keeps it; a newly paired iPhone starts without.
	e.must(200, "DELETE", "/v1/data", e.device, nil)
	if got := e.must(200, "GET", "/v1/authorization", e.reader, nil); got["share"] == nil {
		t.Fatalf("after wipe = %v", got)
	}
	if err := e.store.StartPairing(context.Background(), "333333"); err != nil {
		t.Fatal(err)
	}
	e.must(200, "POST", "/v1/pair", "", map[string]string{"code": "333333", "key": "Zx9Yw8Vu7Ts6Rq5Po4Nm3Lk2Jh1Gf0EdCbA9z8y7x6w"})
	if got := e.must(200, "GET", "/v1/authorization", e.reader, nil); got["share"] != nil || got["updatedAt"] != nil {
		t.Fatalf("after pairing = %v", got)
	}
}

func workout(activity map[string]any, sampleTypes ...string) map[string]any {
	o := map[string]any{
		"kind": "workout", "type": "HKWorkoutTypeIdentifier",
		"startDate": "2026-11-01T18:00:00+08:00", "endDate": "2026-11-01T19:00:00+08:00",
		"metadata": map[string]any{"HKIndoorWorkout": true},
	}
	for k, v := range activity {
		o[k] = v
	}
	var samples []any
	for _, typ := range sampleTypes {
		samples = append(samples, map[string]any{
			"kind": "quantity", "type": typ,
			"startDate": "2026-11-01T18:00:00+08:00", "endDate": "2026-11-01T19:00:00+08:00",
			"quantity": map[string]any{"value": 320, "unit": "kcal"},
		})
	}
	if samples != nil {
		o["samples"] = samples
	}
	return o
}

func stateOfMind(change func(o map[string]any)) map[string]any {
	o := map[string]any{
		"kind": "stateOfMind", "type": "HKDataTypeStateOfMind",
		"startDate": "2026-11-01T21:00:00+08:00", "stateOfMindKind": 1, "valence": -0.6,
		"labels": []int{29}, "associations": []int{17},
	}
	if change != nil {
		change(o)
	}
	return o
}

func TestWorkoutAndStateOfMindWrites(t *testing.T) {
	e := newEnv(t)
	energy := "HKQuantityTypeIdentifierActiveEnergyBurned"
	save := func(o map[string]any) map[string]any { return map[string]any{"op": "save", "object": o} }

	strength := e.must(201, "POST", "/v1/writes", e.agent,
		save(workout(map[string]any{"workoutActivityType": 50}, energy)))
	e.must(201, "POST", "/v1/writes", e.agent, save(workout(map[string]any{"workoutActivityTypeName": "running"})))
	e.must(201, "POST", "/v1/writes", e.agent, save(stateOfMind(nil)))
	e.must(201, "POST", "/v1/writes", e.agent, save(stateOfMind(func(o map[string]any) {
		o["endDate"] = "2026-11-01T13:00:00Z" // the same moment
		o["stateOfMindKind"] = 2
		delete(o, "labels")
	})))

	edit := func(base func() map[string]any, f func(o map[string]any)) map[string]any {
		o := base()
		f(o)
		return save(o)
	}
	run := func() map[string]any { return workout(map[string]any{"workoutActivityTypeName": "running"}, energy) }
	mind := func() map[string]any { return stateOfMind(nil) }
	for name, req := range map[string]map[string]any{
		"both activity fields": edit(run, func(o map[string]any) { o["workoutActivityType"] = 37 }),
		"no activity field":    edit(run, func(o map[string]any) { delete(o, "workoutActivityTypeName") }),
		"activity type 0":      save(workout(map[string]any{"workoutActivityType": 0})),
		"activity name number": save(workout(map[string]any{"workoutActivityTypeName": 37})),
		"workout no endDate":   edit(run, func(o map[string]any) { delete(o, "endDate") }),
		"workout type":         edit(run, func(o map[string]any) { o["type"] = "HKWorkoutTypeIdentifierX" }),
		"workout statistics":   edit(run, func(o map[string]any) { o["statistics"] = map[string]any{} }),
		"sample outside": edit(run, func(o map[string]any) {
			o["samples"].([]any)[0].(map[string]any)["endDate"] = "2026-11-01T19:30:00+08:00"
		}),
		"sample without dates": edit(run, func(o map[string]any) {
			delete(o["samples"].([]any)[0].(map[string]any), "startDate")
		}),
		"category sample": edit(run, func(o map[string]any) {
			o["samples"] = []any{map[string]any{"kind": "category", "type": "HKCategoryTypeIdentifierMindfulSession", "value": 0,
				"startDate": "2026-11-01T18:00:00+08:00", "endDate": "2026-11-01T18:10:00+08:00"}}
		}),
		"samples on a quantity": save(map[string]any{"kind": "quantity", "type": energy, "startDate": "2026-11-01T18:00:00+08:00",
			"endDate": "2026-11-01T19:00:00+08:00", "quantity": map[string]any{"value": 1, "unit": "kcal"}, "samples": []any{}}),
		"mind endDate":        edit(mind, func(o map[string]any) { o["endDate"] = "2026-11-01T21:05:00+08:00" }),
		"mind no startDate":   edit(mind, func(o map[string]any) { delete(o, "startDate") }),
		"mind kind 3":         edit(mind, func(o map[string]any) { o["stateOfMindKind"] = 3 }),
		"mind valence":        edit(mind, func(o map[string]any) { o["valence"] = 1.5 }),
		"mind no valence":     edit(mind, func(o map[string]any) { delete(o, "valence") }),
		"mind null valence":   edit(mind, func(o map[string]any) { o["valence"] = nil }),
		"mind string labels":  edit(mind, func(o map[string]any) { o["labels"] = []string{"stressed"} }),
		"mind type":           edit(mind, func(o map[string]any) { o["type"] = "HKDataTypeIdentifierStateOfMind" }),
		"mind classification": edit(mind, func(o map[string]any) { o["valenceClassification"] = 2 }),
	} {
		if status, out := e.call("POST", "/v1/writes", e.agent, req, false); status != 400 {
			t.Errorf("%s: status %d (%v)", name, status, out)
		}
	}
	for kind, want := range map[string]string{
		"electrocardiogram":   "read-only",
		"medicationDoseEvent": "read-only",
		"workoutRoute":        "write a route as part of its workout (the workout's route field)",
	} {
		status, out := e.call("POST", "/v1/writes", e.agent, save(map[string]any{"kind": kind, "type": "X",
			"startDate": "2026-11-01T18:00:00+08:00", "endDate": "2026-11-01T19:00:00+08:00"}), false)
		if status != 400 || !strings.Contains(out.(map[string]any)["error"].(string), want) {
			t.Errorf("%s: %d %v", kind, status, out)
		}
	}

	// Replacing a workout targets the workout and the samples added to it.
	sid := strength["syncIdentifier"].(string)
	e.must(200, "POST", "/v1/writes/results", e.device, []any{map[string]any{"id": strength["id"], "status": "written", "uuids": []string{"HK-W", "HK-E"}}})
	e.must(201, "POST", "/v1/writes", e.agent, map[string]any{"op": "save", "syncIdentifier": sid,
		"object": workout(map[string]any{"workoutActivityType": 50}, energy)})
	for _, p := range pending(t, e) {
		if p["syncIdentifier"] == sid && (fmt.Sprint(p["replaceUUIDs"]) != "[HK-W HK-E]" ||
			fmt.Sprint(p["replaceTypes"]) != "[HKWorkoutTypeIdentifier "+energy+"]") {
			t.Fatalf("pending replacement = %v", p)
		}
	}
}

func TestWritesShowWhoSubmitted(t *testing.T) {
	e := newEnv(t)
	agentID := e.keyID("agent")
	w := e.must(201, "POST", "/v1/writes", e.agent, map[string]any{"op": "save", "object": bodyMass(72)})
	mine := e.must(201, "POST", "/v1/writes", e.device, map[string]any{"op": "save", "object": bodyMass(73)})
	by := func(v any) string {
		m, _ := v.(map[string]any)["submittedBy"].(map[string]any)
		return fmt.Sprint(m["id"], " ", m["name"])
	}
	if by(w) != agentID+" agent" || by(mine) != e.keyID("iPhone")+" iPhone" {
		t.Fatalf("submittedBy = %v / %v", w["submittedBy"], mine["submittedBy"])
	}
	if p := pending(t, e); len(p) != 2 || by(p[0]) != agentID+" agent" {
		t.Fatalf("pending = %v", p)
	}
	// The name outlives the key.
	e.must(200, "DELETE", "/v1/keys/"+agentID, e.device, nil)
	if got := e.must(200, "GET", "/v1/writes/"+w["id"].(string), e.reader, nil); by(got) != agentID+" agent" {
		t.Fatalf("after revoking = %v", got)
	}
	list := e.must(200, "GET", "/v1/writes", e.reader, nil)["writes"].([]any)
	if len(list) != 2 || by(list[1]) != agentID+" agent" {
		t.Fatalf("list = %v", list)
	}
}

func TestMedications(t *testing.T) {
	e := newEnv(t)
	if got := e.must(200, "GET", "/v1/medications", e.reader, nil); fmt.Sprint(got["medications"]) != "[]" || got["updatedAt"] != nil || len(got) != 2 {
		t.Fatalf("never uploaded = %v", got)
	}
	med := func(id, name string) map[string]any {
		// Absent fields (nickname, a coding's version) are omitted.
		return map[string]any{"id": id, "medication": map[string]any{"displayText": name, "generalForm": "tablet",
			"relatedCodings": []any{map[string]any{"system": "http://www.nlm.nih.gov/research/umls/rxnorm", "code": "197361"}}},
			"isArchived": false, "hasSchedule": true}
	}
	if got := e.must(200, "PUT", "/v1/medications", e.device, map[string]any{"medications": []any{med("M1", "Amlodipine"), med("M2", "Vitamin D")}}); got["stored"] != 2.0 {
		t.Fatalf("put = %v", got)
	}
	got := e.must(200, "GET", "/v1/medications", e.reader, nil)
	meds := got["medications"].([]any)
	if len(meds) != 2 || meds[1].(map[string]any)["id"] != "M2" || got["updatedAt"] == nil {
		t.Fatalf("after put = %v", got)
	}
	if b, _ := json.Marshal(meds[0]); string(b) != `{"hasSchedule":true,"id":"M1","isArchived":false,"medication":{"displayText":"Amlodipine",`+
		`"generalForm":"tablet","relatedCodings":[{"code":"197361","system":"http://www.nlm.nih.gov/research/umls/rxnorm"}]}}` {
		t.Fatalf("stored verbatim? %s", b)
	}
	// Replaced wholesale.
	e.must(200, "PUT", "/v1/medications", e.device, map[string]any{"medications": []any{med("M2", "Vitamin D")}})
	if meds := e.must(200, "GET", "/v1/medications", e.reader, nil)["medications"].([]any); len(meds) != 1 {
		t.Fatalf("after replace = %v", meds)
	}
	for _, bad := range []any{map[string]any{}, map[string]any{"medications": map[string]any{}}, map[string]any{"medications": []any{42}}, []any{}} {
		e.must(400, "PUT", "/v1/medications", e.device, bad)
	}
	e.must(200, "DELETE", "/v1/data", e.device, nil)
	if got := e.must(200, "GET", "/v1/medications", e.reader, nil); fmt.Sprint(got["medications"]) != "[]" || got["updatedAt"] != nil {
		t.Fatalf("after wipe = %v", got)
	}
}
