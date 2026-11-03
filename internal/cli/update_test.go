package cli

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func tarball(t *testing.T, binary string) []byte {
	var buf bytes.Buffer
	gz := gzip.NewWriter(&buf)
	tw := tar.NewWriter(gz)
	_ = tw.WriteHeader(&tar.Header{Name: "rendu", Mode: 0o755, Size: int64(len(binary)), Typeflag: tar.TypeReg})
	_, _ = tw.Write([]byte(binary))
	_ = tw.Close()
	_ = gz.Close()
	return buf.Bytes()
}

func TestUpdateReplacesTheBinary(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("archives are tarballs here")
	}
	name := fmt.Sprintf("rendu_%s_%s.tar.gz", runtime.GOOS, runtime.GOARCH)
	archive := tarball(t, "new binary")
	sum := sha256.Sum256(archive)
	sums := hex.EncodeToString(sum[:]) + "  " + name + "\n"
	var srv *httptest.Server
	srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/latest", "/tags/v0.2.0":
			fmt.Fprintf(w, `{"tag_name":"v0.2.0","assets":[{"name":%q,"browser_download_url":"%s/a"},{"name":"checksums.txt","browser_download_url":"%s/sums"}]}`,
				name, srv.URL, srv.URL)
		case "/a":
			_, _ = w.Write(archive)
		case "/sums":
			fmt.Fprint(w, sums)
		default:
			http.NotFound(w, r)
		}
	}))
	defer srv.Close()
	releasesURL = srv.URL
	Version = "0.1.0"
	defer func() { Version = "dev" }()

	a := &app{http: srv.Client()}
	var out bytes.Buffer
	a.stdout = &out
	if err := a.update([]string{"--check"}); err != nil || !strings.Contains(out.String(), "rendu 0.2.0 is available") {
		t.Fatalf("check: %v %q", err, out.String())
	}

	// The pieces update uses, on a stand-in for the running binary.
	exe := filepath.Join(t.TempDir(), "rendu")
	_ = os.WriteFile(exe, []byte("old binary"), 0o755)
	if err := verify(archive, name, []byte(sums)); err != nil {
		t.Fatal(err)
	}
	binary, err := extract(archive, name)
	if err != nil || string(binary) != "new binary" {
		t.Fatalf("extract: %v %q", err, binary)
	}
	if err := replace(exe, binary); err != nil {
		t.Fatal(err)
	}
	if got, _ := os.ReadFile(exe); string(got) != "new binary" {
		t.Fatalf("replaced with %q", got)
	}
	if info, _ := os.Stat(exe); info.Mode().Perm()&0o100 == 0 {
		t.Fatalf("not executable: %v", info.Mode())
	}

	// A tampered archive isn't installed.
	if err := verify(append(archive, 0), name, []byte(sums)); err == nil || !strings.Contains(err.Error(), "checksum mismatch") {
		t.Fatalf("tampered: %v", err)
	}

	// Already the latest.
	Version = "0.2.0"
	out.Reset()
	if err := a.update(nil); err != nil || !strings.Contains(out.String(), "is the latest version") {
		t.Fatalf("latest: %v %q", err, out.String())
	}
}
