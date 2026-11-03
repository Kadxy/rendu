package server

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"

	sdk "github.com/Kadxy/rendu/internal/schema"
	"github.com/Kadxy/rendu/internal/store"
)

// --- device ---

func (s *Server) ingest(w http.ResponseWriter, r *http.Request) {
	start := time.Now()
	var elements []json.RawMessage
	if !s.decode(w, r, &elements) {
		return
	}
	received := time.Now()
	var anchor *store.AnchorUpdate
	if newAnchor := r.Header.Get(AnchorHeader); newAnchor != "" {
		typ := r.Header.Get(AnchorTypeHeader)
		if typ == "" {
			writeError(w, http.StatusBadRequest, AnchorHeader+" needs "+AnchorTypeHeader)
			return
		}
		anchor = &store.AnchorUpdate{Type: typ, Base: r.Header.Get(BaseAnchorHeader), New: newAnchor}
	}
	res, err := s.store.Ingest(r.Context(), elements, anchor)
	if err != nil {
		s.fail(w, err)
		return
	}
	s.changed.notify()
	// Splits the request time between receiving the body (network) and
	// storing it, which is what tuning the app's batch size needs.
	note := ""
	if res.Anchor == store.AnchorStale {
		note = ", stale anchor"
	}
	log.Printf("ingest %d elements (%d new, %d deleted, %d rejected%s): receive %s, store %s",
		res.Received, res.New, res.Deleted, res.Rejected, note,
		received.Sub(start).Round(time.Millisecond), time.Since(received).Round(time.Millisecond))
	writeJSON(w, http.StatusOK, res)
}

// anchors returns the paired iPhone's sync progress (store/anchors.go).
func (s *Server) anchors(w http.ResponseWriter, r *http.Request) {
	anchors, err := s.store.Anchors(r.Context())
	if err != nil {
		s.fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"anchors": anchors})
}

// putAnchors replaces the sync progress (empty to start over).
func (s *Server) putAnchors(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Anchors map[string]string `json:"anchors"`
	}
	if !s.decode(w, r, &body) {
		return
	}
	if err := s.store.ReplaceAnchors(r.Context(), body.Anchors); err != nil {
		s.fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]int{"anchors": len(body.Anchors)})
}

func (s *Server) latest(w http.ResponseWriter, r *http.Request) {
	latest, err := s.store.Latest(r.Context())
	if err != nil {
		s.fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, latest)
}

func (s *Server) postStatistics(w http.ResponseWriter, r *http.Request) {
	var up store.StatisticsUpload
	if !s.decode(w, r, &up) {
		return
	}
	n, err := s.store.StoreStatistics(r.Context(), up)
	if err != nil {
		s.fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]int{"stored": n})
}

func (s *Server) postActivitySummaries(w http.ResponseWriter, r *http.Request) {
	var items []json.RawMessage
	if !s.decode(w, r, &items) {
		return
	}
	n, err := s.store.StoreActivitySummaries(r.Context(), items)
	if err != nil {
		s.fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]int{"stored": n})
}

func (s *Server) putCharacteristics(w http.ResponseWriter, r *http.Request) {
	var raw json.RawMessage
	if !s.decode(w, r, &raw) {
		return
	}
	if err := s.store.PutCharacteristics(r.Context(), raw); err != nil {
		s.fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

// putAuthorization replaces the phone's write authorization per type
// (store/authorization.go).
func (s *Server) putAuthorization(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Share *map[string]string `json:"share"`
	}
	if !s.decode(w, r, &body) {
		return
	}
	if body.Share == nil {
		writeError(w, http.StatusBadRequest, "share must be an object")
		return
	}
	if err := s.store.PutAuthorization(r.Context(), *body.Share); err != nil {
		s.fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]int{"stored": len(*body.Share)})
}

// putMedications replaces the medication list (store/medications.go).
func (s *Server) putMedications(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Medications []json.RawMessage `json:"medications"`
	}
	if !s.decode(w, r, &body) {
		return
	}
	n, err := s.store.PutMedications(r.Context(), body.Medications)
	if err != nil {
		s.fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]int{"stored": n})
}

// pendingWrites is the iPhone's write queue. With anchor and wait, a
// request whose anchor is still the newest write's waits for the next one
// to be submitted: the open app runs writes as they arrive.
func (s *Server) pendingWrites(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	wait, err := rangeParam(q, "wait", 0, 0, int(maxWait/time.Second))
	if err != nil {
		s.fail(w, err)
		return
	}
	anchor, ok, err := s.awaitWrite(r.Context(), q.Get("anchor"), time.Duration(wait)*time.Second)
	if err != nil {
		s.fail(w, err)
		return
	}
	if !ok {
		return
	}
	writes, err := s.store.PendingWrites(r.Context())
	if err != nil {
		s.fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"writes": writes, "anchor": anchor})
}

// awaitWrite returns the writes anchor: at once when it isn't since (or
// without since), otherwise when a write is submitted or wait runs out. ok
// is false when the client went away.
func (s *Server) awaitWrite(ctx context.Context, since string, wait time.Duration) (anchor string, ok bool, err error) {
	timeout := time.NewTimer(wait)
	defer timeout.Stop()
	for {
		submitted := s.submitted.next()
		anchor, err := s.store.WritesAnchor(ctx)
		if err != nil || since == "" || anchor != since || wait == 0 {
			return anchor, true, err
		}
		select {
		case <-submitted:
		case <-timeout.C:
			return anchor, true, nil
		case <-s.stopping:
			return anchor, true, nil
		case <-ctx.Done():
			return "", false, nil
		}
	}
}

func (s *Server) writeResults(w http.ResponseWriter, r *http.Request) {
	var results []store.WriteResult
	if !s.decode(w, r, &results) {
		return
	}
	n, err := s.store.RecordResults(r.Context(), results)
	if err != nil {
		s.fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]int{"updated": n})
}

// --- agent ---

func (s *Server) status(w http.ResponseWriter, r *http.Request) {
	st, err := s.store.Status(r.Context())
	if err != nil {
		s.fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, struct {
		store.Status
		Version   string `json:"version"`
		StartedAt string `json:"startedAt"`
	}{st, Version, store.FormatTime(s.startedAt)})
}

// wipeData empties the server's health data at the phone's request; the
// phone resets its own sync state alongside.
func (s *Server) wipeData(w http.ResponseWriter, r *http.Request) {
	if err := s.store.WipeData(r.Context()); err != nil {
		s.fail(w, err)
		return
	}
	// Waiting change-feed requests learn their anchor expired.
	s.changed.notify()
	log.Printf("all health data wiped at the device's request")
	writeJSON(w, http.StatusOK, map[string]bool{"wiped": true})
}

// --- pairing and keys ---

// pair completes pairing: the phone presents the code it shows and the key
// it generated; it polls until the code has been entered on the server.
func (s *Server) pair(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Code string `json:"code"`
		Key  string `json:"key"`
	}
	if !s.decode(w, r, &body) {
		return
	}
	cred, err := s.store.CompletePairing(r.Context(), body.Code, body.Key)
	switch {
	case errors.Is(err, store.ErrNoPairing):
		writeError(w, http.StatusNotFound, "no pairing code entered on the server (rendu-server pair CODE)")
	case errors.Is(err, store.ErrWrongCode):
		writeError(w, http.StatusForbidden, "the code entered on the server is a different one")
	case err != nil:
		s.fail(w, err)
	default:
		log.Printf("paired a new iPhone (%s); the previous one, if any, is unpaired", cred.ID)
		writeJSON(w, http.StatusOK, map[string]any{"paired": true, "id": cred.ID})
	}
}

func (s *Server) listKeys(w http.ResponseWriter, r *http.Request) {
	creds, err := s.store.Credentials(r.Context())
	if err != nil {
		s.fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"keys": creds})
}

func (s *Server) createKey(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Name  string      `json:"name"`
		Scope store.Scope `json:"scope"`
	}
	if !s.decode(w, r, &body) {
		return
	}
	cred, key, err := s.store.CreateAPIKey(r.Context(), body.Name, body.Scope)
	if err != nil {
		s.fail(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, struct {
		store.Credential
		Key string `json:"key"`
	}{cred, key})
}

func (s *Server) revokeKey(w http.ResponseWriter, r *http.Request) {
	if err := s.store.RevokeAPIKey(r.Context(), r.PathValue("id")); err != nil {
		s.fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]bool{"revoked": true})
}

// keyActivity lists an API key's requests, newest first (store/activity.go).
func (s *Server) keyActivity(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	limit, err := intParam(q, "limit", 100, 500)
	if err != nil {
		s.fail(w, err)
		return
	}
	var before *store.ActivityCursor
	if v := q.Get("before"); v != "" {
		c, err := store.DecodeActivityCursor(v)
		if err != nil {
			s.fail(w, err)
			return
		}
		before = &c
	}
	entries, next, err := s.store.KeyActivity(r.Context(), r.PathValue("id"), limit, before)
	if err != nil {
		s.fail(w, err)
		return
	}
	resp := struct {
		Activity []json.RawMessage `json:"activity"`
		Next     *string           `json:"next"`
	}{Activity: entries}
	if next != nil {
		c := next.Encode()
		resp.Next = &c
	}
	writeJSON(w, http.StatusOK, resp)
}

func (s *Server) types(w http.ResponseWriter, r *http.Request) {
	types, err := s.store.Types(r.Context())
	if err != nil {
		s.fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"types": types})
}

func (s *Server) samples(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	sq := store.SampleQuery{Type: q.Get("type"), Source: q.Get("source"), Desc: q.Get("order") == "desc"}
	if sq.Type == "" {
		writeError(w, http.StatusBadRequest, "type is required")
		return
	}
	var err error
	if sq.Type, err = s.resolveType(r.Context(), sq.Type); err != nil {
		s.fail(w, err)
		return
	}
	if sq.Start, sq.End, err = timeRange(q); err != nil {
		s.fail(w, err)
		return
	}
	if sq.Limit, err = intParam(q, "limit", 1000, 10000); err != nil {
		s.fail(w, err)
		return
	}
	if v := q.Get("cursor"); v != "" {
		c, err := store.DecodeCursor(v)
		if err != nil {
			s.fail(w, err)
			return
		}
		sq.After = &c
	}
	samples, next, err := s.store.QuerySamples(r.Context(), sq)
	if err != nil {
		s.fail(w, err)
		return
	}
	noteCount(r, len(samples))
	resp := struct {
		Samples    []json.RawMessage `json:"samples"`
		NextCursor string            `json:"nextCursor,omitempty"`
	}{Samples: samples}
	if next != nil {
		resp.NextCursor = next.Encode()
	}
	writeJSON(w, http.StatusOK, resp)
}

func (s *Server) getStatistics(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	typ, interval := q.Get("type"), q.Get("interval")
	if typ == "" {
		writeError(w, http.StatusBadRequest, "type is required")
		return
	}
	typ, err := s.resolveType(r.Context(), typ)
	if err != nil {
		s.fail(w, err)
		return
	}
	if interval == "" {
		interval = "day"
	}
	if !store.ValidInterval(interval) {
		writeError(w, http.StatusBadRequest, "interval must be \"hour\" or \"day\"")
		return
	}
	start, end, err := timeRange(q)
	if err != nil {
		s.fail(w, err)
		return
	}
	res, err := s.store.QueryStatistics(r.Context(), typ, interval, start, end)
	if err != nil {
		s.fail(w, err)
		return
	}
	noteCount(r, len(res.Statistics))
	writeJSON(w, http.StatusOK, res)
}

func (s *Server) getActivitySummaries(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	start, end := q.Get("start"), q.Get("end")
	for name, v := range map[string]string{"start": start, "end": end} {
		if v != "" && !store.ValidDate(v) {
			writeError(w, http.StatusBadRequest, name+" must be YYYY-MM-DD")
			return
		}
	}
	items, err := s.store.QueryActivitySummaries(r.Context(), start, end)
	if err != nil {
		s.fail(w, err)
		return
	}
	noteCount(r, len(items))
	writeJSON(w, http.StatusOK, map[string]any{"activitySummaries": items})
}

func (s *Server) getCharacteristics(w http.ResponseWriter, r *http.Request) {
	body, err := s.store.GetCharacteristics(r.Context())
	if err != nil {
		s.fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, body)
}

func (s *Server) getAuthorization(w http.ResponseWriter, r *http.Request) {
	auth, err := s.store.Authorization(r.Context())
	if err != nil {
		s.fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, auth)
}

func (s *Server) getMedications(w http.ResponseWriter, r *http.Request) {
	meds, err := s.store.Medications(r.Context())
	if err != nil {
		s.fail(w, err)
		return
	}
	noteCount(r, len(meds.Medications))
	writeJSON(w, http.StatusOK, meds)
}

// maxWait bounds how long a change-feed request waits for a change.
const maxWait = 60 * time.Second

// getChanges is the change feed (store/changes.go). With wait, a request
// that finds nothing new waits for an ingest that brings a matching change
// — HKObserverQuery for agents — instead of the agent polling.
func (s *Server) getChanges(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	anchor, types := q.Get("anchor"), typesParam(q)
	for i, typ := range types {
		var err error
		if types[i], err = s.resolveType(r.Context(), typ); err != nil {
			s.fail(w, err)
			return
		}
	}
	limit, err := rangeParam(q, "limit", 500, 0, 5000)
	if err != nil {
		s.fail(w, err)
		return
	}
	wait, err := rangeParam(q, "wait", 0, 0, int(maxWait/time.Second))
	if err != nil {
		s.fail(w, err)
		return
	}
	timeout := time.NewTimer(time.Duration(wait) * time.Second)
	defer timeout.Stop()
	for {
		changed := s.changed.next()
		res, err := s.store.Changes(r.Context(), anchor, types, limit)
		if err != nil {
			s.fail(w, err)
			return
		}
		if !res.Empty() || limit == 0 || wait == 0 {
			noteCount(r, len(res.Samples)+len(res.Deleted))
			writeJSON(w, http.StatusOK, res)
			return
		}
		// Nothing yet: continue from the newest change once there is one.
		anchor = res.Anchor
		select {
		case <-changed:
			continue
		case <-timeout.C:
		case <-s.stopping:
		case <-r.Context().Done():
			return
		}
		noteCount(r, 0)
		writeJSON(w, http.StatusOK, res)
		return
	}
}

func (s *Server) postWrite(w http.ResponseWriter, r *http.Request) {
	var req store.WriteRequest
	if !s.decode(w, r, &req) {
		return
	}
	var head struct {
		Type string `json:"type"`
	}
	_ = json.Unmarshal(req.Object, &head)
	noteActivity(r, func(a *store.Activity) { a.Type = clip(head.Type) })
	cred := credential(r)
	wr, err := s.store.SubmitWrite(r.Context(), req, store.Submitter{ID: cred.ID, Name: cred.Name})
	if err != nil {
		s.fail(w, err)
		return
	}
	s.submitted.notify()
	noteActivity(r, func(a *store.Activity) {
		one := 1
		a.Count, a.WriteID = &one, wr.ID
	})
	writeJSON(w, http.StatusCreated, wr)
}

func (s *Server) listWrites(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	status := q.Get("status")
	if status != "" && !store.ValidStatus(status) {
		writeError(w, http.StatusBadRequest, "status must be pending, written, failed or conflict")
		return
	}
	limit, err := intParam(q, "limit", 100, 1000)
	if err != nil {
		s.fail(w, err)
		return
	}
	writes, err := s.store.ListWrites(r.Context(), status, q.Get("syncIdentifier"), limit)
	if err != nil {
		s.fail(w, err)
		return
	}
	noteCount(r, len(writes))
	writeJSON(w, http.StatusOK, map[string]any{"writes": writes})
}

func (s *Server) getWrite(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	noteActivity(r, func(a *store.Activity) { a.WriteID = clip(id) })
	wr, err := s.store.GetWrite(r.Context(), id)
	if err != nil {
		s.fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, wr)
}

// --- params ---

func timeRange(q url.Values) (start, end *time.Time, err error) {
	parse := func(name string) (*time.Time, error) {
		v := q.Get(name)
		if v == "" {
			return nil, nil
		}
		// An unencoded "+08:00" offset arrives as a space; accept it so
		// hand-written curl calls work.
		t, err := store.ParseTimestamp(strings.ReplaceAll(v, " ", "+"))
		if err != nil {
			return nil, &httpError{http.StatusBadRequest, name + " must be an RFC 3339 timestamp"}
		}
		return &t, nil
	}
	if start, err = parse("start"); err != nil {
		return nil, nil, err
	}
	if end, err = parse("end"); err != nil {
		return nil, nil, err
	}
	return start, end, nil
}

func intParam(q url.Values, name string, def, max int) (int, error) {
	return rangeParam(q, name, def, 1, max)
}

func rangeParam(q url.Values, name string, def, min, max int) (int, error) {
	v := q.Get(name)
	if v == "" {
		return def, nil
	}
	n, err := strconv.Atoi(v)
	if err != nil || n < min || n > max {
		return 0, &httpError{http.StatusBadRequest, name + " must be between " + strconv.Itoa(min) + " and " + strconv.Itoa(max)}
	}
	return n, nil
}

// resolveType checks a type a client names: an SDK type (by identifier or
// constant name; the identifier comes back), or one the server holds data
// of — a type newer than the SDK snapshot. Anything else is a 400 naming
// the closest types, so a typo doesn't read as "no data".
func (s *Server) resolveType(ctx context.Context, typ string) (string, error) {
	if id, _, ok := sdk.LookupType(typ); ok {
		return id, nil
	}
	has, err := s.store.HasType(ctx, typ)
	if err != nil || has {
		return typ, err
	}
	msg := fmt.Sprintf("unknown type %q", typ)
	if close := sdk.SuggestTypes(typ); len(close) > 0 {
		msg += "; did you mean " + strings.Join(close, ", ") + "?"
	} else {
		msg += "; GET /v1/schema lists every type"
	}
	return "", &httpError{http.StatusBadRequest, msg}
}

// typesParam reads type filters given repeatedly and/or comma-separated.
func typesParam(q url.Values) []string {
	var out []string
	seen := map[string]bool{}
	for _, v := range q["type"] {
		for _, t := range strings.Split(v, ",") {
			if t = strings.TrimSpace(t); t != "" && !seen[t] {
				seen[t] = true
				out = append(out, t)
			}
		}
	}
	return out
}
