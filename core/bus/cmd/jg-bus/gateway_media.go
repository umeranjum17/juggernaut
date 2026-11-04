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
	"strconv"
	"strings"
	"time"
)

// MediaRef is one file an inbound message carries, before it is fetched. Kind is image, file, audio or video.
type MediaRef struct {
	Kind, ID, Name, Mime string
	Bytes                int64
}

// mediaFile is a stored file as the inbound event names it.
type mediaFile struct {
	Path   string `json:"path"`
	SHA256 string `json:"sha256"`
	Mime   string `json:"mime"`
	Bytes  int64  `json:"bytes"`
	// Transcript is the words of a voice or audio note, when the gateway could make them; older events have none.
	Transcript string `json:"transcript,omitempty"`
	kind       string // image, file, audio or video; for the round-trip record, not the event
}

type tgFile struct {
	ID   string `json:"file_id"`
	Name string `json:"file_name"`
	Mime string `json:"mime_type"`
	Size int64  `json:"file_size"`
}

type tgMedia struct {
	Photo     []tgFile `json:"photo"` // the sizes of one picture, smallest first
	Document  *tgFile  `json:"document"`
	Voice     *tgFile  `json:"voice"`
	Audio     *tgFile  `json:"audio"`
	Video     *tgFile  `json:"video"`
	VideoNote *tgFile  `json:"video_note"` // the round clip
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
	add("video", "", m.Video)
	add("video", "video/mp4", m.VideoNote)
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
	switch {
	case n >= 1<<20:
		return fmt.Sprintf("%.1f MB", float64(n)/(1<<20))
	case n >= 1<<10:
		return fmt.Sprintf("%.1f KB", float64(n)/(1<<10))
	}
	return fmt.Sprintf("%d B", n)
}

// fetchMedia stores every file of one update and returns the note's file lines and the stored
// files. A file that cannot be had still gets a line saying why, so the owner's text is never lost.
// An audio or video file is read aloud by the engine, if one is installed; early runs once before the
// first transcript starts, so the owner's reaction does not wait for the engine.
func (a *app) fetchMedia(ad Adapter, in Inbound, early func()) (lines []string, stored []mediaFile) {
	argv, engine := a.engine()
	for _, m := range in.Media {
		if m.Bytes > ad.FetchLimit() {
			lines = append(lines, fmt.Sprintf("[file too large to fetch (%s, limit %d MB)]", humanSize(m.Bytes), ad.FetchLimit()>>20))
			continue
		}
		f, err := a.storeMedia(ad, m)
		if err != nil {
			a.noteFailure("gateway media", err.Error())
			lines = append(lines, "[file could not be fetched: "+detail(err.Error())+"]")
			continue
		}
		line := fmt.Sprintf("[file %s %s %s %s", m.Kind, f.Path, humanSize(f.Bytes), f.Mime)
		if m.Name != "" {
			line += " " + toJSON(m.Name) // quoted, so a hostile name cannot add lines to the note
		}
		lines = append(lines, line+"]")
		if engine && (f.kind == "audio" || f.kind == "video") {
			early()
			var l string
			l, f.Transcript = a.transcript(f, argv)
			lines = append(lines, l)
		}
		stored = append(stored, f)
	}
	return lines, stored
}

// refuseLarge tells the owner, in the chat, about each file over the fetch limit.
func (a *app) refuseLarge(ad Adapter, in Inbound) {
	for _, m := range in.Media {
		if m.Bytes > ad.FetchLimit() {
			text := fmt.Sprintf("That file is %s. I can fetch files up to %d MB, so I did not download it.", humanSize(m.Bytes), ad.FetchLimit()>>20)
			if _, err := ad.Send(context.Background(), Outbound{Chat: in.Chat, ReplyTo: in.Message, Text: text}); err != nil {
				a.noteFailure("gateway media", err.Error())
			}
		}
	}
}

// storeMedia downloads one file to state/captain-chat/media/<day>/<sha256>.<ext> (folders 0700,
// files 0600). The hash names the file, so the same file sent again is kept once.
func (a *app) storeMedia(ad Adapter, m MediaRef) (mediaFile, error) {
	root := filepath.Join(a.state, "captain-chat", "media")
	day := filepath.Join(root, time.Now().UTC().Format("2006-01-02"))
	if err := os.MkdirAll(day, 0o700); err != nil {
		return mediaFile{}, err
	}
	tmp, err := os.CreateTemp(day, ".fetch-*")
	if err != nil {
		return mediaFile{}, err
	}
	defer os.Remove(tmp.Name())
	sum := sha256.New()
	n, err := ad.Fetch(context.Background(), m, io.MultiWriter(tmp, sum))
	if cerr := tmp.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		return mediaFile{}, err
	}
	hash := hex.EncodeToString(sum.Sum(nil))
	final := filepath.Join(day, hash+"."+mediaExt(m))
	if old, _ := filepath.Glob(filepath.Join(root, "*", hash+".*")); len(old) > 0 {
		final = old[0]
		now := time.Now()
		_ = os.Chtimes(final, now, now) // a file sent again is recent again
	} else if err := os.Rename(tmp.Name(), final); err != nil {
		return mediaFile{}, err
	}
	return mediaFile{Path: final, SHA256: hash, Mime: m.Mime, Bytes: n, kind: m.Kind}, nil
}

// mediaExt is the stored file's extension: the sender's own, else one for the type, else bin.
func mediaExt(m MediaRef) string {
	ext := strings.ToLower(strings.TrimPrefix(filepath.Ext(m.Name), "."))
	if ext == "" {
		ext = map[string]string{"image/jpeg": "jpg", "image/png": "png", "image/webp": "webp", "audio/ogg": "ogg",
			"audio/mpeg": "mp3", "video/mp4": "mp4", "application/pdf": "pdf", "text/plain": "txt"}[m.Mime]
	}
	if len(ext) > 8 || strings.Trim(ext, "abcdefghijklmnopqrstuvwxyz0123456789") != "" || ext == "" {
		return "bin"
	}
	return ext
}

// pruneMedia deletes stored files older than chat-media-days (default 30), then empty day folders.
func (a *app) pruneMedia() {
	days, _ := strconv.Atoi(a.cfgOr("chat-media-days", "30"))
	if days <= 0 {
		days = 30
	}
	cutoff, root := time.Now().AddDate(0, 0, -days), filepath.Join(a.state, "captain-chat", "media")
	dirs, _ := os.ReadDir(root)
	for _, d := range dirs {
		files, _ := os.ReadDir(filepath.Join(root, d.Name()))
		for _, f := range files {
			if info, err := f.Info(); err == nil && info.ModTime().Before(cutoff) {
				_ = os.Remove(filepath.Join(root, d.Name(), f.Name()))
			}
		}
		_ = os.Remove(filepath.Join(root, d.Name())) // fails while a file is left
	}
}
