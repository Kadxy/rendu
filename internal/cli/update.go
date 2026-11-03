package cli

import (
	"archive/tar"
	"archive/zip"
	"bytes"
	"compress/gzip"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"strings"
)

// releasesURL is where releases are (GitHub's API and downloads).
var releasesURL = "https://api.github.com/repos/Kadxy/rendu/releases"

// update replaces this binary with the latest release (or --version's),
// as install.sh would: the archive for this OS and architecture, checked
// against the release's checksums.
func (a *app) update(args []string) error {
	fs := newFlags("update")
	want := fs.String("version", "", "a release tag such as v0.2.0 (default: latest)")
	check := fs.Bool("check", false, "only say whether there's a newer release")
	if _, err := parse(fs, args, 0); err != nil {
		return err
	}
	current := version()

	path := "/latest"
	if *want != "" {
		path = "/tags/v" + strings.TrimPrefix(*want, "v")
	}
	var release struct {
		Tag    string `json:"tag_name"`
		Assets []struct {
			Name string `json:"name"`
			URL  string `json:"browser_download_url"`
		} `json:"assets"`
	}
	body, err := a.download(releasesURL + path)
	if err != nil {
		return fmt.Errorf("finding the release: %w", err)
	}
	if err := json.Unmarshal(body, &release); err != nil || release.Tag == "" {
		return fmt.Errorf("finding the release: unexpected answer from GitHub")
	}
	latest := strings.TrimPrefix(release.Tag, "v")
	if *want == "" && latest == current {
		fmt.Fprintf(a.stdout, "rendu %s is the latest version\n", current)
		return nil
	}
	if *check {
		fmt.Fprintf(a.stdout, "rendu %s is available (you have %s); run 'rendu update'\n", latest, current)
		return nil
	}

	name := fmt.Sprintf("rendu_%s_%s.tar.gz", runtime.GOOS, runtime.GOARCH)
	if runtime.GOOS == "windows" {
		name = fmt.Sprintf("rendu_%s_%s.zip", runtime.GOOS, runtime.GOARCH)
	}
	urls := map[string]string{}
	for _, asset := range release.Assets {
		urls[asset.Name] = asset.URL
	}
	if urls[name] == "" || urls["checksums.txt"] == "" {
		return fmt.Errorf("release %s has no %s", release.Tag, name)
	}
	archive, err := a.download(urls[name])
	if err != nil {
		return fmt.Errorf("downloading %s: %w", name, err)
	}
	sums, err := a.download(urls["checksums.txt"])
	if err != nil {
		return fmt.Errorf("downloading checksums: %w", err)
	}
	if err := verify(archive, name, sums); err != nil {
		return err
	}
	binary, err := extract(archive, name)
	if err != nil {
		return err
	}
	exe, err := os.Executable()
	if err != nil {
		return err
	}
	if exe, err = filepath.EvalSymlinks(exe); err != nil {
		return err
	}
	if err := replace(exe, binary); err != nil {
		return fmt.Errorf("replacing %s: %w (install.sh can install it instead)", exe, err)
	}
	fmt.Fprintf(a.stdout, "Updated rendu %s → %s\n", current, latest)
	return nil
}

func (a *app) download(url string) ([]byte, error) {
	resp, err := a.http.Get(url)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("%s: HTTP %d", url, resp.StatusCode)
	}
	return io.ReadAll(io.LimitReader(resp.Body, 200<<20))
}

// verify checks archive against its line in checksums.txt.
func verify(archive []byte, name string, sums []byte) error {
	sum := sha256.Sum256(archive)
	for line := range strings.Lines(string(sums)) {
		if f := strings.Fields(line); len(f) == 2 && f[1] == name {
			if f[0] != hex.EncodeToString(sum[:]) {
				return fmt.Errorf("checksum mismatch for %s; not updated", name)
			}
			return nil
		}
	}
	return fmt.Errorf("checksums.txt has no %s; not updated", name)
}

// extract takes the rendu binary out of the release archive.
func extract(archive []byte, name string) ([]byte, error) {
	if strings.HasSuffix(name, ".zip") {
		r, err := zip.NewReader(bytes.NewReader(archive), int64(len(archive)))
		if err != nil {
			return nil, err
		}
		for _, f := range r.File {
			if filepath.Base(f.Name) == "rendu.exe" {
				rc, err := f.Open()
				if err != nil {
					return nil, err
				}
				defer rc.Close()
				return io.ReadAll(rc)
			}
		}
		return nil, fmt.Errorf("%s has no rendu.exe", name)
	}
	gz, err := gzip.NewReader(bytes.NewReader(archive))
	if err != nil {
		return nil, err
	}
	tr := tar.NewReader(gz)
	for {
		h, err := tr.Next()
		if err == io.EOF {
			return nil, fmt.Errorf("%s has no rendu", name)
		}
		if err != nil {
			return nil, err
		}
		if filepath.Base(h.Name) == "rendu" && h.Typeflag == tar.TypeReg {
			return io.ReadAll(tr)
		}
	}
}

// replace swaps exe for binary: written next to it, then renamed over it,
// so a failure leaves the old one. (Windows can't replace a running .exe,
// but it can rename it out of the way.)
func replace(exe string, binary []byte) error {
	tmp := exe + ".new"
	if err := os.WriteFile(tmp, binary, 0o755); err != nil {
		return err
	}
	if runtime.GOOS == "windows" {
		old := exe + ".old"
		_ = os.Remove(old)
		if err := os.Rename(exe, old); err != nil {
			_ = os.Remove(tmp)
			return err
		}
	}
	if err := os.Rename(tmp, exe); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	return nil
}
