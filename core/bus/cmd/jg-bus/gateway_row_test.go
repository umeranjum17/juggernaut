package main

import (
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// The migration card's chat row, from nothing to live: no token, a service that is not running, a
// bot that does not answer, then the six legs one at a time (text, picture and file in; text,
// picture and file out) against a fake Bot API, and the ways a live row goes back to pending.
func TestGatewayChatRow(t *testing.T) {
	if _, err := exec.LookPath("python3"); err != nil {
		t.Skip("jg-inbox.sh needs python3")
	}
	root, _ := filepath.Abs("../../../..")
	home := t.TempDir()
	var batch string
	var botDown bool
	var n int
	var methods []string
	bot := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		base, method := "/bot"+tok+"/", r.URL.Path[strings.LastIndex(r.URL.Path, "/")+1:]
		switch p := r.URL.Path; {
		case botDown:
			http.Error(w, `{"ok":false}`, 502)
		case p == base+"getMe":
			fmt.Fprint(w, `{"ok":true,"result":{"username":"rowbot"}}`)
		case p == base+"getUpdates":
			fmt.Fprintf(w, `{"ok":true,"result":[%s]}`, batch)
		case p == base+"getFile":
			fmt.Fprintf(w, `{"ok":true,"result":{"file_path":"files/%s"}}`, r.URL.Query().Get("file_id"))
		case strings.HasPrefix(p, "/file/bot"+tok+"/files/"):
			fmt.Fprint(w, "bytes of "+strings.TrimPrefix(p, "/file/bot"+tok+"/files/"))
		case strings.HasPrefix(p, base+"send"):
			io.Copy(io.Discard, r.Body)
			methods = append(methods, method)
			n++
			fmt.Fprintf(w, `{"ok":true,"result":{"message_id":%d}}`, 700+n)
		default:
			http.Error(w, `{"ok":false}`, 404)
		}
	}))
	defer bot.Close()
	dapr := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	defer dapr.Close()
	tokenFile, conf, state, data := filepath.Join(home, "tg.token"), filepath.Join(home, "conf"), filepath.Join(home, "state"), filepath.Join(home, "data")
	os.WriteFile(conf, []byte(fmt.Sprintf("set gateway-adapters telegram\nset telegram-token-file %s\nset telegram-allow-user 42\nset telegram-api-url %s\nset dapr-http-url %s\nset dapr-pubsub p\nset subject-prefix jg.captain\n", tokenFile, bot.URL, dapr.URL)), 0o600)
	os.MkdirAll(data, 0o700)
	a := &app{root: root, home: home, state: state, data: data, configFiles: []string{conf}, record: state + "/rec", log: state + "/log"}
	row := func() string {
		old := os.Stdout
		rd, wr, _ := os.Pipe()
		os.Stdout = wr
		code := a.gateway([]string{"status", "--row"})
		wr.Close()
		os.Stdout = old
		out, _ := io.ReadAll(rd)
		if code != 0 {
			t.Fatalf("status --row exited %d: the row always exits 0", code)
		}
		return strings.TrimSpace(string(out))
	}
	once := func() {
		if code := a.gateway([]string{"--once"}); code != 0 {
			t.Fatalf("gateway --once exited %d", code)
		}
	}
	want := func(step, got, prefix string) {
		t.Helper()
		if !strings.HasPrefix(got, prefix) {
			t.Errorf("%s: row is %q, want it to start %q", step, got, prefix)
		}
	}

	want("no token file", row(), "absent\toff: no bot token")
	os.WriteFile(tokenFile, []byte(tok+"\n"), 0o600)
	want("token but no service", row(), "pending\tthe gateway service is not running")
	alive := filepath.Join(state, "captain-chat", "telegram.alive")
	os.MkdirAll(filepath.Dir(alive), 0o700)
	a.beat(&telegram{})
	botDown = true
	want("bot down", row(), "pending\tthe bot did not answer getMe")
	botDown = false
	want("nothing exchanged", row(), "pending\tin: none - out: none - missing in text image file, out text image file")

	// The owner sends text, a picture and a file; each is filed as a note.
	batch = strings.Join([]string{upd(10, "private", 42, 42, false, "hello"),
		media(11, 42, `"photo":[{"file_id":"pic1","file_size":10}]`),
		media(12, 42, `"document":{"file_id":"doc1","file_name":"r.pdf","mime_type":"application/pdf","file_size":10}`),
		media(13, 42, `"voice":{"file_id":"v1","mime_type":"audio/ogg","file_size":10}`)}, ",")
	once()
	batch = ""
	want("inbound legs", row(), "pending\tin: text image file - out: none - missing out text image file")

	// Overwatch answers each with text, a picture and a file; the gateway sends them.
	notes := map[string]string{}
	readLines(state+"/captain-chat/inbound.jsonl", func(v map[string]string) { notes[v["message"]] = v["note"] })
	shot, report := filepath.Join(data, "shot.png"), filepath.Join(data, "report.pdf")
	os.WriteFile(shot, pngBytes(1), 0o600)
	os.WriteFile(report, []byte("%PDF- the report"), 0o600)
	for _, r := range [][]string{{"100", "--", "hi"}, {"110", "--attach", shot}, {"120", "--attach", report}} {
		if out, err := a.inbox("", append([]string{"reply", notes[r[0]]}, r[1:]...)...); err != nil {
			t.Fatalf("reply to %s: %v %s", r[0], err, out)
		}
	}
	once()
	if got := strings.Join(methods, " "); got != "sendMessage sendPhoto sendDocument" {
		t.Fatalf("the gateway sent %q", got)
	}
	day := time.Now().UTC().Format("2006-01-02")
	want("all six legs", row(), "live\t6 of 6 legs, last "+day+", 3 notes, 3 replies")
	once() // a second pass sends and counts nothing again
	want("a replay", row(), "live\t6 of 6 legs, last "+day+", 3 notes, 3 replies")

	// A leg older than seven days no longer counts; a stopped service and a silent bot are pending.
	rt := state + "/captain-chat/roundtrip.tsv"
	raw, _ := os.ReadFile(rt)
	var aged []string
	for _, l := range strings.Split(strings.TrimSpace(string(raw)), "\n") {
		if strings.Contains(l, "\tout-file\t") {
			l = fmt.Sprintf("%d%s", time.Now().Add(-8*24*time.Hour).Unix(), l[strings.Index(l, "\t"):])
		}
		aged = append(aged, l)
	}
	os.WriteFile(rt, []byte(strings.Join(aged, "\n")+"\n"), 0o600)
	want("an old leg", row(), "pending\tin: text image file - out: text image - missing out file")
	os.WriteFile(rt, raw, 0o600)
	want("legs fresh again", row(), "live\t")
	old := time.Now().Add(-10 * time.Minute)
	os.Chtimes(alive, old, old)
	want("a stopped service", row(), "pending\tthe gateway service is not running")
	a.beat(&telegram{})
	botDown = true
	want("a silent bot", row(), "pending\tthe bot did not answer getMe")
	botDown = false
	// Off by choice: the adapter list names no telegram.
	other := filepath.Join(home, "other")
	os.WriteFile(other, []byte("set gateway-adapters signal\n"), 0o600)
	a.configFiles = []string{other, conf}
	want("adapter off", row(), "absent\toff: no bot token")
	a.configFiles = []string{conf}

	filepath.Walk(home, func(p string, i os.FileInfo, _ error) error {
		if b, _ := os.ReadFile(p); p != tokenFile && strings.Contains(string(b), tok) {
			t.Errorf("the bot token was written to %s", p)
		}
		return nil
	})
	t.Logf("the chat row went absent -> pending (service, bot, each missing leg) -> live at 6 of 6 legs, and back to pending for an old leg, a stopped service and a silent bot; the final row is %q", row())
}
