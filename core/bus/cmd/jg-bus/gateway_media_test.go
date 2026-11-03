package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// media builds one update from `from` in their own private chat; `fields` is the media part.
func media(id, from int, fields string) string {
	return fmt.Sprintf(`{"update_id":%d,"message":{"message_id":%d,%s,"from":{"id":%d,"is_bot":false},"chat":{"id":%d,"type":"private"}}}`, id, id*10, fields, from, from)
}

// The owner sends a photo, a document, a voice note, a file over the 20 MB cap, a file Telegram
// no longer has, and the photo again; a stranger sends a photo. Against a fake Bot API.
func TestGatewayMedia(t *testing.T) {
	if _, err := exec.LookPath("python3"); err != nil {
		t.Skip("jg-inbox.sh needs python3")
	}
	root, _ := filepath.Abs("../../../..")
	home := t.TempDir()
	content := map[string]string{"p-large": "JPEG photo bytes", "p-again": "JPEG photo bytes", "doc1": "%PDF- the report", "v1": "OggS voice"}
	var batch string
	var fetched, sends []string
	bot := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		base := "/bot" + tok + "/"
		switch p := r.URL.Path; {
		case p == base+"getUpdates":
			fmt.Fprintf(w, `{"ok":true,"result":[%s]}`, batch)
		case p == base+"getFile":
			id := r.URL.Query().Get("file_id")
			fetched = append(fetched, id)
			if id == "gone" {
				fmt.Fprint(w, `{"ok":false,"description":"Bad Request: file is gone"}`)
				return
			}
			fmt.Fprintf(w, `{"ok":true,"result":{"file_path":"files/%s"}}`, id)
		case strings.HasPrefix(p, "/file/bot"+tok+"/files/"):
			fmt.Fprint(w, content[strings.TrimPrefix(p, "/file/bot"+tok+"/files/")])
		case p == base+"sendMessage":
			var m struct {
				Text  string
				Reply struct {
					MessageID int64 `json:"message_id"`
				} `json:"reply_parameters"`
			}
			json.NewDecoder(r.Body).Decode(&m)
			sends = append(sends, fmt.Sprintf("%d|%s", m.Reply.MessageID, m.Text))
			fmt.Fprint(w, `{"ok":true,"result":{"message_id":9}}`)
		default:
			http.Error(w, `{"ok":false}`, 404)
		}
	}))
	defer bot.Close()
	dapr := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	defer dapr.Close()
	tokenFile, conf, state := filepath.Join(home, "tg.token"), filepath.Join(home, "conf"), filepath.Join(home, "state")
	os.WriteFile(tokenFile, []byte(tok+"\n"), 0o600)
	os.WriteFile(conf, []byte(fmt.Sprintf("set gateway-adapters telegram\nset telegram-token-file %s\nset telegram-allow-user 42\nset telegram-api-url %s\nset dapr-http-url %s\nset dapr-pubsub p\nset subject-prefix jg.captain\n", tokenFile, bot.URL, dapr.URL)), 0o600)
	a := &app{root: root, home: home, state: state, data: filepath.Join(home, "data"), configFiles: []string{conf}, record: state + "/rec", log: state + "/log"}
	once := func() {
		if code := a.gateway([]string{"--once"}); code != 0 {
			t.Fatalf("gateway --once exited %d", code)
		}
	}
	batch = strings.Join([]string{
		media(30, 42, `"caption":"look at this","photo":[{"file_id":"p-small","file_size":9},{"file_id":"p-large","file_size":16}]`),
		media(31, 42, `"document":{"file_id":"doc1","file_name":"report.pdf","mime_type":"application/pdf","file_size":16}`),
		media(32, 42, `"voice":{"file_id":"v1","mime_type":"audio/ogg","file_size":10}`),
		media(33, 42, `"document":{"file_id":"big","file_name":"huge.zip","file_size":26214400}`),
		media(34, 42, `"document":{"file_id":"gone","file_name":"old.txt","file_size":5}`),
		media(35, 7, `"photo":[{"file_id":"stranger-photo","file_size":9}]`),
		media(36, 42, `"photo":[{"file_id":"p-again","file_size":16}]`)}, ",")
	once()

	sum := sha256.Sum256([]byte(content["p-large"]))
	hash, day := hex.EncodeToString(sum[:]), time.Now().UTC().Format("2006-01-02")
	dir := filepath.Join(state, "captain-chat", "media", day)
	var notes strings.Builder
	files, _ := filepath.Glob(state + "/inbox/*.note")
	for _, f := range files {
		b, _ := os.ReadFile(f)
		notes.Write(b)
	}
	for _, want := range []string{
		"[chat telegram 42:300]\nlook at this\n[file image " + filepath.Join(dir, hash+".jpg") + " 16 B image/jpeg]",
		`[file file ` + dir + `/`, ` application/pdf "report.pdf"]`,
		"[file audio " + dir + "/", ".ogg 10 B audio/ogg]",
		"[file too large to fetch (25.0 MB, limit 20 MB)]",
		"[file could not be fetched: getFile answered HTTP 200: Bad Request: file is gone]",
	} {
		if !strings.Contains(notes.String(), want) {
			t.Errorf("no note holds %q:\n%s", want, notes.String())
		}
	}
	if len(files) != 6 || strings.Contains(notes.String(), "stranger") {
		t.Errorf("%d notes, want the owner's 6 and none from the stranger", len(files))
	}
	// Photo, document and voice once each, though the photo came twice; folders 0700, files 0600.
	stored, _ := os.ReadDir(dir)
	info, _ := os.Stat(dir)
	if len(stored) != 3 || info.Mode().Perm() != 0o700 {
		t.Errorf("%d stored files in a %v folder, want 3 in 0700", len(stored), info.Mode().Perm())
	}
	for _, f := range stored {
		if i, _ := f.Info(); i.Mode().Perm() != 0o600 {
			t.Errorf("%s is %v, want 0600", f.Name(), i.Mode().Perm())
		}
	}
	if got := strings.Join(fetched, " "); got != "p-large doc1 v1 gone p-again" {
		t.Errorf("getFile asked for %q: the large photo size, the owner's files, never the stranger's or the oversized one", got)
	}
	if len(sends) != 1 || !strings.HasPrefix(sends[0], "330|") || !strings.Contains(sends[0], "25.0 MB") || !strings.Contains(sends[0], "20 MB") {
		t.Errorf("sends = %q: want one text threaded on message 330 refusing the large file", sends)
	}
	// The event names the stored files; text events and old events have no media key.
	rec, _ := os.ReadFile(state + "/rec")
	if n := strings.Count(string(rec), `"media":[{"path":`); n != 4 || strings.Count(string(rec), "\n") != 6 {
		t.Errorf("record holds %d media events in %d lines, want 4 in 6:\n%s", n, strings.Count(string(rec), "\n"), rec)
	}
	if !strings.Contains(string(rec), fmt.Sprintf(`"sha256":"%s","mime":"image/jpeg","bytes":16}`, hash)) {
		t.Errorf("no event names the photo by hash %s:\n%s", hash, rec)
	}
	// A replay after a crash sends and publishes nothing twice.
	os.Remove(state + "/captain-chat/telegram.offset")
	once()
	if after, _ := os.ReadFile(state + "/rec"); string(after) != string(rec) || len(sends) != 1 {
		t.Errorf("replay changed the record or sent again: %d sends", len(sends))
	}
	// Parity: an event written before slice 4 still rebuilds byte for byte, and the record that
	// now also holds media events has no difference.
	old := `{"at":1700000000,"kind":"card","key":"k1","subject":"jg.captain.card","text":"A decision waits.","link":"https://example.test/c"}`
	if got := a.eventJSON(1700000000, "card", "k1", "A decision waits.", "https://example.test/c"); got != old {
		t.Errorf("an old event rebuilds as %s", got)
	}
	both := filepath.Join(home, "parity.jsonl")
	os.WriteFile(both, append([]byte(old+"\n"), rec...), 0o600)
	if code := a.parity([]string{"--record", both}); code != 0 {
		t.Errorf("parity over old and media events found a difference (exit %d)", code)
	}
	// Retention: a file older than chat-media-days goes; the rest stay.
	voice, _ := filepath.Glob(dir + "/*.ogg")
	long := time.Now().AddDate(0, 0, -40)
	os.Chtimes(voice[0], long, long)
	batch = ""
	once()
	if left, _ := os.ReadDir(dir); len(left) != 2 {
		t.Errorf("%d files left after the prune, want 2", len(left))
	}
	filepath.Walk(home, func(p string, i os.FileInfo, _ error) error {
		if b, _ := os.ReadFile(p); p != tokenFile && strings.Contains(string(b), tok) {
			t.Errorf("the bot token was written to %s", p)
		}
		return nil
	})
	t.Logf("owner sent 6 files and a stranger 1: %d getFile calls, 3 files stored once each, 1 over-limit file refused in chat (%s), the prune removed the 40-day-old voice file", len(fetched), sends[0])
}
