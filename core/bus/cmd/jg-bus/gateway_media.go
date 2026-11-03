package main

// Inbound media: the owner's file is downloaded, stored under its content hash and named in the note.

import (
	"cmp"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// MediaRef is one file an inbound message carries, before it is fetched. Kind is image, file or audio.
type MediaRef struct {
	Kind, ID, Name, Mime string
	Bytes                int64
}

type tgFile struct {
	ID   string `json:"file_id"`
	Name string `json:"file_name"`
	Mime string `json:"mime_type"`
	Size int64  `json:"file_size"`
}

type tgMedia struct {
	Photo    []tgFile `json:"photo"` // the sizes of one picture, smallest first
	Document *tgFile  `json:"document"`
	Voice    *tgFile  `json:"voice"`
	Audio    *tgFile  `json:"audio"`
}

func (m tgMedia) refs() (out []MediaRef) {
	add := func(kind, mime string, f *tgFile) {
		if f != nil && f.ID != "" {
			out = append(out, MediaRef{kind, f.ID, f.Name, cmp.Or(f.Mime, mime), f.Size})
		}
	}
	if n := len(m.Photo); n > 0 {
		add("image", "image/jpeg", &m.Photo[n-1])
	}
	add("file", "", m.Document)
	add("audio", "audio/ogg", m.Voice)
	add("audio", "", m.Audio)
	return out
}

func (t *telegram) FetchLimit() int64 { return 20 << 20 }

// Fetch is getFile, then the download of the path it names, copied to w. The token is in both
// URLs, so every error is redacted before it leaves.
func (t *telegram) Fetch(ctx context.Context, m MediaRef, w io.Writer) (int64, error) {
	get := func(path string) (*http.Response, error) {
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, t.base+path, nil)
		var resp *http.Response
		if err == nil {
			resp, err = (&http.Client{Timeout: 5 * time.Minute}).Do(req)
		}
		if err != nil {
			return nil, errors.New(redact(err.Error(), t.token))
		}
		return resp, nil
	}
	resp, err := get("/bot" + t.token + "/getFile?file_id=" + url.QueryEscape(m.ID))
	if err != nil {
		return 0, err
	}
	var info struct {
		OK          bool   `json:"ok"`
		Description string `json:"description"`
		Result      struct {
			Path string `json:"file_path"`
		} `json:"result"`
	}
	err = json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(&info)
	resp.Body.Close()
	if err != nil || !info.OK || info.Result.Path == "" {
		return 0, fmt.Errorf("getFile answered HTTP %d: %s", resp.StatusCode, redact(info.Description, t.token))
	}
	if resp, err = get("/file/bot" + t.token + "/" + info.Result.Path); err != nil {
		return 0, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return 0, fmt.Errorf("download answered HTTP %d", resp.StatusCode)
	}
	n, err := io.Copy(w, io.LimitReader(resp.Body, t.FetchLimit()+1))
	if err == nil && n > t.FetchLimit() {
		err = errors.New("the file is larger than the limit")
	}
	return n, err
}

func humanSize(n int64) string {
	if n < 1<<10 {
		return fmt.Sprintf("%d B", n)
	} else if n < 1<<20 {
		return fmt.Sprintf("%.1f KB", float64(n)/(1<<10))
	}
	return fmt.Sprintf("%.1f MB", float64(n)/(1<<20))
}

// fetchMedia stores every file of one update and returns the note's file lines. A file that
// cannot be had still gets a line saying why, so the owner's text is never lost.
func (a *app) fetchMedia(ad Adapter, in Inbound) (lines []string) {
	for _, m := range in.Media {
		if m.Bytes > ad.FetchLimit() {
			lines = append(lines, fmt.Sprintf("[file too large to fetch (%s, limit %d MB)]", humanSize(m.Bytes), ad.FetchLimit()>>20))
			continue
		}
		path, n, err := a.storeMedia(ad, m)
		if err != nil {
			a.noteFailure("gateway media", err.Error())
			lines = append(lines, "[file could not be fetched: "+detail(err.Error())+"]")
			continue
		}
		line := fmt.Sprintf("[file %s %s %s %s", m.Kind, path, humanSize(n), m.Mime)
		if m.Name != "" {
			line += " " + toJSON(m.Name) // quoted, so a hostile name cannot add lines to the note
		}
		lines = append(lines, line+"]")
	}
	return lines
}

// storeMedia downloads one file to state/captain-chat/media/<day>/<sha256>.<ext> (folders 0700,
// files 0600). The hash names the file, so the same file sent again is kept once.
func (a *app) storeMedia(ad Adapter, m MediaRef) (string, int64, error) {
	root := filepath.Join(a.state, "captain-chat", "media")
	day := filepath.Join(root, time.Now().UTC().Format("2006-01-02"))
	if err := os.MkdirAll(day, 0o700); err != nil {
		return "", 0, err
	}
	tmp, err := os.CreateTemp(day, ".fetch-*")
	if err != nil {
		return "", 0, err
	}
	defer os.Remove(tmp.Name())
	sum := sha256.New()
	n, err := ad.Fetch(context.Background(), m, io.MultiWriter(tmp, sum))
	if cerr := tmp.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		return "", 0, err
	}
	hash := hex.EncodeToString(sum.Sum(nil))
	final := filepath.Join(day, hash+"."+mediaExt(m))
	if old, _ := filepath.Glob(filepath.Join(root, "*", hash+".*")); len(old) > 0 {
		return old[0], n, nil
	}
	return final, n, os.Rename(tmp.Name(), final)
}

// mediaExt is the stored file's extension: the sender's own, else one for the type, else bin.
func mediaExt(m MediaRef) string {
	ext := strings.ToLower(strings.TrimPrefix(filepath.Ext(m.Name), "."))
	if ext == "" {
		ext = map[string]string{"image/jpeg": "jpg", "audio/ogg": "ogg", "application/pdf": "pdf"}[m.Mime]
	}
	if ext == "" || len(ext) > 8 || strings.Trim(ext, "abcdefghijklmnopqrstuvwxyz0123456789") != "" {
		return "bin"
	}
	return ext
}
