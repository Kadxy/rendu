// Command rendu-server runs the Rendu API.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/Kadxy/rendu/internal/cli"
	"github.com/Kadxy/rendu/internal/server"
	"github.com/Kadxy/rendu/internal/store"
)

const usage = `rendu-server — Rendu API server.

Usage:
  rendu-server serve [--addr 127.0.0.1:8787] [--db rendu.db]
  rendu-server pair CODE [--db rendu.db]   (pair the iPhone showing CODE; replaces any paired iPhone)

Environment:
  RENDU_ADDR  default for --addr
  RENDU_DB    default for --db

There are no secrets to configure. The iPhone pairs with the code it shows
and keeps its own key; API keys are created in the app.
`

func main() {
	os.Exit(run(os.Args[1:]))
}

func run(args []string) int {
	if len(args) == 0 || args[0] == "help" || args[0] == "-h" || args[0] == "--help" {
		fmt.Fprint(os.Stderr, usage)
		if len(args) == 0 {
			return 2
		}
		return 0
	}
	var err error
	switch args[0] {
	case "serve":
		err = serve(args[1:])
	case "pair":
		err = pair(args[1:])
	default:
		err = fmt.Errorf("unknown command %q", args[0])
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "rendu-server:", err)
		return 1
	}
	return 0
}

func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func dbFlag(fs *flag.FlagSet) *string {
	return fs.String("db", envOr("RENDU_DB", "rendu.db"), "SQLite database path")
}

func serve(args []string) error {
	fs := flag.NewFlagSet("serve", flag.ContinueOnError)
	addr := fs.String("addr", envOr("RENDU_ADDR", "127.0.0.1:8787"), "listen address")
	db := dbFlag(fs)
	if _, err := cli.ParseInterleaved(fs, args); err != nil {
		return err
	}
	st, err := store.Open(*db)
	if err != nil {
		return err
	}
	defer st.Close()

	api := server.New(st)
	srv := &http.Server{
		Addr:              *addr,
		Handler:           logRequests(api.Handler()),
		ReadHeaderTimeout: 10 * time.Second,
		// A first sync uploads large batches over mobile networks.
		ReadTimeout:  10 * time.Minute,
		WriteTimeout: 5 * time.Minute,
		IdleTimeout:  2 * time.Minute,
	}
	// Change-feed requests waiting for a change answer at once on shutdown.
	srv.RegisterOnShutdown(api.Close)
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	errc := make(chan error, 1)
	go func() {
		log.Printf("listening on %s (db %s)", *addr, *db)
		errc <- srv.ListenAndServe()
	}()
	select {
	case err := <-errc:
		return err
	case <-ctx.Done():
	}
	shutdown, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := srv.Shutdown(shutdown); err != nil && !errors.Is(err, http.ErrServerClosed) {
		return err
	}
	return nil
}

type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (r *statusRecorder) WriteHeader(code int) {
	r.status = code
	r.ResponseWriter.WriteHeader(code)
}

func logRequests(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(rec, r)
		log.Printf("%s %s %d %s", r.Method, r.URL.Path, rec.status, time.Since(start).Round(time.Millisecond))
	})
}

// pair accepts the code the iPhone shows, then waits for the phone (which
// polls) to complete pairing, so the operator sees the outcome.
func pair(args []string) error {
	fs := flag.NewFlagSet("pair", flag.ContinueOnError)
	db := dbFlag(fs)
	rest, err := cli.ParseInterleaved(fs, args)
	if err != nil {
		return err
	}
	if len(rest) != 1 {
		return errors.New("usage: rendu-server pair CODE")
	}
	code := strings.ReplaceAll(rest[0], " ", "")
	st, err := store.Open(*db)
	if err != nil {
		return err
	}
	defer st.Close()
	ctx := context.Background()
	started := time.Now()
	if err := st.StartPairing(ctx, code); err != nil {
		return err
	}
	fmt.Fprintf(os.Stderr, "Waiting for the iPhone showing %s (up to %d minutes)…\n", code, int(store.PairingTTL.Minutes()))
	for {
		time.Sleep(500 * time.Millisecond)
		pending, err := st.PairingPending(ctx)
		if err != nil {
			return err
		}
		if pending {
			continue
		}
		owner, err := st.Owner(ctx)
		if err == nil && owner.CreatedAt >= store.FormatTime(started.Add(-time.Second)) {
			return printJSON(os.Stdout, map[string]any{"paired": true, "id": owner.ID})
		}
		return errors.New("not paired: the code expired, or a different code was tried too often — run pair again")
	}
}

func printJSON(w io.Writer, v any) error {
	enc := json.NewEncoder(w)
	enc.SetIndent("", "  ")
	enc.SetEscapeHTML(false)
	return enc.Encode(v)
}
