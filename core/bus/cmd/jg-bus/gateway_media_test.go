package main

import (
	"crypto/sha256"
	"encoding/hex"
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

// media is one update from `from` in their own private chat; fields is its media part.
func media(id, from int, fields string) string {
	return fmt.Sprintf(`{"update_id":%d,"message":{"message_id":%d,%s,"from":{"id":%d,"is_bot":false},"chat":{"id":%d,"type":"private"}}}`, id, id*10, fields, from, from)
}

// The owner sends a photo, a document, a voice note, a file over the 20 MB cap, a file Telegram no
// longer has, and the photo again; a stranger sends a photo. Against a fake Bot API.
func TestGatewayMedia(t *testing.T) {
	if _, err := exec.LookPath("python3"); err != nil {
		t.Skip("jg-inbox.sh needs python3")
	}
	root, _ := filepath.Abs("../../../..")
	home, batch, fetched := t.TempDir(), "", []string{}
	content := map[string]string{"p-large": "JPEG photo bytes", "p-again": "JPEG photo bytes", "doc1": "%PDF- the report", "v1": "OggS voice"}
	bot := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch p, id := r.URL.Path, r.URL.Query().Get("file_id"); {
		case p == "/bot"+tok+"/getUpdates":
			fmt.Fprintf(w, `{"ok":true,"result":[%s]}`, batch)
		case p == "/bot"+tok+"/getFile":
			fetched = append(fetched, id)
			fmt.Fprintf(w, `{"ok":%t,"description":"Bad Request: file is gone","result":{"file_path":"files/%s"}}`, id != "gone", id)
		case strings.HasPrefix(p, "/file/bot"+tok+"/files/"):
			fmt.Fprint(w, content[strings.TrimPrefix(p, "/file/bot"+tok+"/files/")])
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
	batch = strings.Join([]string{
		media(30, 42, `"caption":"look at this","photo":[{"file_id":"p-small","file_size":9},{"file_id":"p-large","file_size":16}]`),
		media(31, 42, `"document":{"file_id":"doc1","file_name":"report.pdf","mime_type":"application/pdf","file_size":16}`),
		media(32, 42, `"voice":{"file_id":"v1","mime_type":"audio/ogg","file_size":10}`),
		media(33, 42, `"document":{"file_id":"big","file_name":"huge.zip","file_size":26214400}`),
		media(34, 42, `"document":{"file_id":"gone","file_name":"old.txt","file_size":5}`),
		media(35, 7, `"photo":[{"file_id":"stranger-photo","file_size":9}]`),
		media(36, 42, `"photo":[{"file_id":"p-again","file_size":16}]`)}, ",")
	if code := a.gateway([]string{"--once"}); code != 0 {
		t.Fatalf("gateway --once exited %d", code)
	}
	sum := sha256.Sum256([]byte(content["p-large"]))
	dir := filepath.Join(state, "captain-chat", "media", time.Now().UTC().Format("2006-01-02"))
	var notes strings.Builder
	files, _ := filepath.Glob(state + "/inbox/*.note")
	for _, f := range files {
		b, _ := os.ReadFile(f)
		notes.Write(b)
	}
	for _, want := range []string{
		"[chat telegram 42:300]\nlook at this\n[file image " + filepath.Join(dir, hex.EncodeToString(sum[:])+".jpg") + " 16 B image/jpeg]",
		"[file file " + dir + "/", ` application/pdf "report.pdf"]`, "[file audio " + dir + "/", ".ogg 10 B audio/ogg]",
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
	// Photo, document and voice once each though the photo came twice; folders 0700, files 0600.
	stored, _ := os.ReadDir(dir)
	if info, _ := os.Stat(dir); len(stored) != 3 || info.Mode().Perm() != 0o700 {
		t.Errorf("%d stored files in a %v folder, want 3 in 0700", len(stored), info.Mode().Perm())
	}
	for _, f := range stored {
		if i, _ := f.Info(); i.Mode().Perm() != 0o600 {
			t.Errorf("%s is %v, want 0600", f.Name(), i.Mode().Perm())
		}
	}
	if got := strings.Join(fetched, " "); got != "p-large doc1 v1 gone p-again" {
		t.Errorf("getFile asked for %q: the large photo size and the owner's files, never the stranger's or the oversized one", got)
	}
	filepath.Walk(home, func(p string, i os.FileInfo, _ error) error {
		if b, _ := os.ReadFile(p); p != tokenFile && strings.Contains(string(b), tok) {
			t.Errorf("the bot token was written to %s", p)
		}
		return nil
	})
}
