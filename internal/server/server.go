// Package server exposes the store over the v1 HTTP API (docs/PROTOCOL.md).
package server

import (
	"compress/gzip"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/Kadxy/rendu/internal/store"
)

// maxBody caps a request body after gzip decompression.
const maxBody = 64 << 20

// touchEvery throttles last-used bookkeeping so reads stay read-only.
const touchEvery = time.Minute

// pruneEvery throttles deleting expired API activity.
const pruneEvery = time.Hour

// Version is set at build time (-ldflags "-X …/server.Version=…").
var Version = "dev"

type Server struct {
	store     *store.Store
	mux       *http.ServeMux
	now       func() time.Time
	startedAt time.Time

	mu        sync.Mutex
	lastTouch map[string]time.Time
	lastPrune time.Time
	// changed: an ingest or a wipe committed (change-feed requests wait
	// for it); submitted: a write was submitted (the open app waits for it).
	changed, submitted signal
	// stopping is closed by Close, ending those waits early.
	stopping  chan struct{}
	closeOnce sync.Once
}

// New serves st to holders of its credentials (store/credentials.go): the
// paired iPhone's owner key, and API keys the owner created.
func New(st *store.Store) *Server {
	s := &Server{store: st, mux: http.NewServeMux(), now: time.Now, startedAt: time.Now(),
		lastTouch: map[string]time.Time{}, stopping: make(chan struct{})}
	s.routes()
	return s
}

func (s *Server) Handler() http.Handler { return s.mux }

// Close answers waiting requests now, so a graceful shutdown doesn't wait
// out their timeouts (http.Server.RegisterOnShutdown).
func (s *Server) Close() { s.closeOnce.Do(func() { close(s.stopping) }) }

// signal wakes the requests waiting for something to happen.
type signal struct {
	mu sync.Mutex
	ch chan struct{}
}

// next returns a channel closed by the next notify. Take it before
// reading, so what happens in between isn't missed.
func (g *signal) next() <-chan struct{} {
	g.mu.Lock()
	defer g.mu.Unlock()
	if g.ch == nil {
		g.ch = make(chan struct{})
	}
	return g.ch
}

func (g *signal) notify() {
	g.mu.Lock()
	defer g.mu.Unlock()
	if g.ch != nil {
		close(g.ch)
		g.ch = nil
	}
}

func (s *Server) routes() {
	s.mux.HandleFunc("GET /v1/health", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
	})
	// The phone completes pairing with the code it shows (no credential yet).
	s.mux.HandleFunc("POST /v1/pair", s.pair)

	owner := func(pattern string, h http.HandlerFunc) { s.mux.Handle(pattern, s.auth(store.ScopeOwner, h)) }
	read := func(pattern string, h http.HandlerFunc) { s.mux.Handle(pattern, s.auth(store.ScopeRead, h)) }
	readWrite := func(pattern string, h http.HandlerFunc) { s.mux.Handle(pattern, s.auth(store.ScopeReadWrite, h)) }

	// The paired iPhone.
	owner("POST /v1/ingest", s.ingest)
	owner("GET /v1/latest", s.latest)
	owner("POST /v1/statistics", s.postStatistics)
	owner("POST /v1/activity-summaries", s.postActivitySummaries)
	owner("PUT /v1/characteristics", s.putCharacteristics)
	owner("GET /v1/writes/pending", s.pendingWrites)
	owner("POST /v1/writes/results", s.writeResults)
	owner("DELETE /v1/data", s.wipeData)
	owner("GET /v1/anchors", s.anchors)
	owner("PUT /v1/anchors", s.putAnchors)
	owner("GET /v1/keys", s.listKeys)
	owner("POST /v1/keys", s.createKey)
	owner("DELETE /v1/keys/{id}", s.revokeKey)
	owner("GET /v1/keys/{id}/activity", s.keyActivity)
	owner("PUT /v1/authorization", s.putAuthorization)
	owner("PUT /v1/medications", s.putMedications)
	owner("PUT /v1/catalog", s.putCatalog)

	// Reading (API keys, and the phone's Browse tab).
	read("GET /v1/status", s.status)
	read("GET /v1/types", s.types)
	read("GET /v1/samples", s.samples)
	read("GET /v1/statistics", s.getStatistics)
	read("GET /v1/activity-summaries", s.getActivitySummaries)
	read("GET /v1/characteristics", s.getCharacteristics)
	read("GET /v1/writes", s.listWrites)
	read("GET /v1/writes/{id}", s.getWrite)
	read("GET /v1/changes", s.getChanges)
	read("GET /v1/authorization", s.getAuthorization)
	read("GET /v1/medications", s.getMedications)
	read("GET /v1/schema", s.schemaOverview)
	read("GET /v1/schema/types/{type}", s.schemaType)
	read("GET /v1/schema/kinds/{kind}", s.schemaKind)
	read("GET /v1/schema/enums/{name}", s.schemaEnum)
	read("GET /v1/schema/metadata/{key}", s.schemaMetadataKey)

	// Writing to Health, through the phone.
	readWrite("POST /v1/writes", s.postWrite)

	// Unknown /v1 paths answer 404 only to a valid key, so they don't
	// reveal which endpoints exist.
	notFound := func(w http.ResponseWriter, r *http.Request) {
		writeError(w, http.StatusNotFound, "no such endpoint")
	}
	read("/v1/", notFound)
	s.mux.HandleFunc("/", notFound)
}

// Sync progress headers on an ingest batch (store/anchors.go): the type, the
// anchor the batch was read from, and the anchor it reaches.
const (
	AnchorTypeHeader = "X-Rendu-Anchor-Type"
	BaseAnchorHeader = "X-Rendu-Base-Anchor"
	AnchorHeader     = "X-Rendu-Anchor"
)

type ctxKey int

const (
	credentialKey ctxKey = iota
	activityKey
)

// credential is the request's authenticated credential.
func credential(r *http.Request) store.Credential {
	c, _ := r.Context().Value(credentialKey).(store.Credential)
	return c
}

// auth admits requests whose bearer key belongs to a credential allowed
// need: 401 for no or an unknown key, 403 for one with too little access.
// Requests by API keys, admitted or not, are recorded as their activity.
func (s *Server) auth(need store.Scope, next http.HandlerFunc) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		key, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
		var cred store.Credential
		var err error
		if ok {
			cred, err = s.store.Authenticate(r.Context(), strings.TrimSpace(key))
		}
		switch {
		case !ok || errors.Is(err, store.ErrNotFound):
			w.Header().Set("WWW-Authenticate", "Bearer")
			writeError(w, http.StatusUnauthorized, "invalid or missing key")
			return
		case err != nil:
			s.fail(w, err)
			return
		}
		ctx := context.WithValue(r.Context(), credentialKey, cred)
		if cred.Scope != store.ScopeOwner {
			at := s.now()
			act := newActivity(r)
			ctx = context.WithValue(ctx, activityKey, act)
			rec := &statusWriter{ResponseWriter: w, status: http.StatusOK}
			w = rec
			defer func() {
				act.Status = rec.status
				s.recordActivity(context.WithoutCancel(ctx), cred.ID, at, act)
			}()
		}
		r = r.WithContext(ctx)
		if !cred.Scope.Allows(need) {
			writeError(w, http.StatusForbidden, fmt.Sprintf("this key is %s; this needs %s", cred.Scope, need))
			return
		}
		s.touch(r, cred.ID)
		next(w, r)
	})
}

type statusWriter struct {
	http.ResponseWriter
	status int
}

func (w *statusWriter) WriteHeader(code int) {
	w.status = code
	w.ResponseWriter.WriteHeader(code)
}

// newActivity starts an API key request's entry: the route and the
// parameters as given; handlers add what they returned (noteActivity).
func newActivity(r *http.Request) *store.Activity {
	q := r.URL.Query()
	// The pattern without its method; the catch-all has the path itself.
	path := r.URL.Path
	if _, p, ok := strings.Cut(r.Pattern, " "); ok {
		path = p
	}
	param := func(name string) string { return clip(strings.ReplaceAll(q.Get(name), " ", "+")) }
	return &store.Activity{
		Method:   r.Method,
		Path:     clip(path),
		Type:     clip(strings.Join(typesParam(q), ",")),
		Start:    param("start"),
		End:      param("end"),
		Interval: clip(q.Get("interval")),
	}
}

// clip bounds what a client's request puts into its activity entry.
func clip(v string) string {
	if len(v) > 200 {
		return v[:200]
	}
	return v
}

// noteActivity lets a handler complete the request's activity entry (none
// for the owner).
func noteActivity(r *http.Request, note func(a *store.Activity)) {
	if a, ok := r.Context().Value(activityKey).(*store.Activity); ok {
		note(a)
	}
}

func noteCount(r *http.Request, n int) {
	noteActivity(r, func(a *store.Activity) { a.Count = &n })
}

// recordActivity stores an API key request, and expired entries go at most
// once an hour.
func (s *Server) recordActivity(ctx context.Context, id string, at time.Time, act *store.Activity) {
	if err := s.store.RecordActivity(ctx, id, at, *act); err != nil {
		log.Printf("activity %s: %v", id, err)
	}
	s.mu.Lock()
	due := at.Sub(s.lastPrune) >= pruneEvery
	if due {
		s.lastPrune = at
	}
	s.mu.Unlock()
	if due {
		if _, err := s.store.PruneActivity(ctx); err != nil {
			log.Printf("prune activity: %v", err)
		}
	}
}

// touch records a credential's last use, at most once a minute each, so
// reads stay read-only.
func (s *Server) touch(r *http.Request, id string) {
	now := s.now()
	s.mu.Lock()
	due := now.Sub(s.lastTouch[id]) >= touchEvery
	if due {
		s.lastTouch[id] = now
	}
	s.mu.Unlock()
	if due {
		if err := s.store.TouchCredential(r.Context(), id, now); err != nil {
			log.Printf("touch %s: %v", id, err)
		}
	}
}

type httpError struct {
	status int
	msg    string
}

func (e *httpError) Error() string { return e.msg }

func readBody(w http.ResponseWriter, r *http.Request) ([]byte, error) {
	var rd io.Reader = http.MaxBytesReader(w, r.Body, maxBody)
	switch enc := strings.ToLower(strings.TrimSpace(r.Header.Get("Content-Encoding"))); enc {
	case "", "identity":
	case "gzip":
		gz, err := gzip.NewReader(rd)
		if err != nil {
			return nil, &httpError{http.StatusBadRequest, "invalid gzip body"}
		}
		defer gz.Close()
		rd = gz
	default:
		return nil, &httpError{http.StatusUnsupportedMediaType, "unsupported Content-Encoding " + enc}
	}
	data, err := io.ReadAll(io.LimitReader(rd, maxBody+1))
	var tooLarge *http.MaxBytesError
	if errors.As(err, &tooLarge) || len(data) > maxBody {
		return nil, &httpError{http.StatusRequestEntityTooLarge, "request body too large"}
	}
	if err != nil {
		return nil, &httpError{http.StatusBadRequest, "reading body: " + err.Error()}
	}
	return data, nil
}

// decode reads and unmarshals the body into v; it writes the error response
// itself and reports whether the handler should continue.
func (s *Server) decode(w http.ResponseWriter, r *http.Request, v any) bool {
	data, err := readBody(w, r)
	if err != nil {
		s.fail(w, err)
		return false
	}
	if err := json.Unmarshal(data, v); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON: "+err.Error())
		return false
	}
	return true
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(v); err != nil {
		log.Printf("write response: %v", err)
	}
}

func writeError(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]string{"error": msg})
}

// statusClientClosed is logged for requests the client cancelled (nginx's
// 499).
const statusClientClosed = 499

func (s *Server) fail(w http.ResponseWriter, err error) {
	var he *httpError
	var ve *store.ValidationError
	var ue *store.UnwritableError
	switch {
	case errors.As(err, &he):
		writeError(w, he.status, he.msg)
	case errors.As(err, &ve):
		writeError(w, http.StatusBadRequest, ve.Msg)
	case errors.As(err, &ue):
		writeError(w, http.StatusUnprocessableEntity, ue.Msg)
	case errors.Is(err, store.ErrAnchorExpired):
		writeError(w, http.StatusGone, err.Error())
	case errors.Is(err, store.ErrNotFound):
		writeError(w, http.StatusNotFound, "not found")
	case errors.Is(err, context.Canceled):
		// The client went away (the app left the screen that asked); no
		// one reads the answer, and it isn't the server's error.
		w.WriteHeader(statusClientClosed)
	default:
		log.Printf("internal error: %v", err)
		writeError(w, http.StatusInternalServerError, "internal error")
	}
}
