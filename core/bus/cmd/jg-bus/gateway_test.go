package main

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

const tok = "123456:SECRET-token-AbC"

func upd(id int, kind string, from, chat int, bot bool, text string) string {
	return fmt.Sprintf(`{"update_id":%d,"message":{"message_id":%d,"text":%q,"from":{"id":%d,"is_bot":%t},"chat":{"id":%d,"type":%q}}}`, id, id*10, text, from, bot, chat, kind)
}

// A fake Bot API and a fake Dapr sidecar, the real bin/jg-inbox.sh, a scratch home.
func TestGatewayIngress(t *testing.T) {
	if _, err := exec.LookPath("python3"); err != nil {
		t.Skip("jg-inbox.sh needs python3")
	}
	root, _ := filepath.Abs("../../../..")
	home, batch, events := t.TempDir(), "", []string{}
	bot := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !strings.HasPrefix(r.URL.Path, "/bot"+tok+"/") || r.URL.Query().Get("allowed_updates") != `["message"]` {
			http.Error(w, `{"ok":false}`, 404)
			return
		}
		fmt.Fprintf(w, `{"ok":true,"result":[%s]}`, batch)
	}))
	defer bot.Close()
	dapr := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { events = append(events, r.URL.Path) }))
	defer dapr.Close()
	tokenFile, conf, state := filepath.Join(home, "tg.token"), filepath.Join(home, "conf"), filepath.Join(home, "state")
	os.WriteFile(tokenFile, []byte(tok+"\n"), 0o600)
	os.WriteFile(conf, []byte(fmt.Sprintf("set gateway-adapters telegram\nset telegram-token-file %s\nset telegram-allow-user 42\nset telegram-api-url %s\nset dapr-http-url %s\nset dapr-pubsub p\nset subject-prefix jg.captain\n", tokenFile, bot.URL, dapr.URL)), 0o600)
	a := &app{root: root, home: home, state: state, data: filepath.Join(home, "data"), configFiles: []string{conf}, record: state + "/rec", log: state + "/log"}
	once := func() int { return a.gateway([]string{"--once"}) }

	// The owner's text, then a stranger, the owner's id in a group, and a bot: one note, three drops.
	batch = strings.Join([]string{upd(10, "private", 42, 42, false, "hello overwatch"), upd(11, "private", 7, 7, false, "stranger"),
		upd(12, "supergroup", 42, -9, false, "group"), upd(13, "private", 42, 42, true, "bot")}, ",")
	if code := once(); code != 0 || len(events) != 1 || !strings.HasSuffix(events[0], "/jg.captain.inbound") {
		t.Fatalf("exit %d, events %v: want one inbound event", code, events)
	}
	if off, _ := os.ReadFile(state + "/captain-chat/telegram.offset"); string(off) != "14\n" {
		t.Fatalf("offset = %q, want 14", off)
	}
	if d, _ := os.ReadFile(state + "/captain-chat/dropped.tsv"); strings.Count(string(d), "\n") != 3 || strings.ContainsAny(string(d), "sgb") {
		t.Fatalf("dropped.tsv should count 3 and hold no text: %q", d)
	}
	// The same update after a crash before the offset commit: a replay, no second note or event.
	os.Remove(state + "/captain-chat/telegram.offset")
	batch = upd(10, "private", 42, 42, false, "hello overwatch")
	notes, _ := filepath.Glob(state + "/inbox/*.note")
	if body, _ := os.ReadFile(notes[0]); once() != 0 || len(events) != 1 || len(notes) != 1 || !strings.Contains(string(body), "[chat telegram 42:100]\nhello overwatch") {
		t.Fatalf("replay: events %v, notes %v, body %q", events, notes, body)
	}
	// A group-readable token file is refused; a dead API's error names the token-bearing URL.
	os.Chmod(tokenFile, 0o640)
	failGroup := once()
	os.Chmod(tokenFile, 0o600)
	bot.Close()
	if failGroup == 0 || once() == 0 {
		t.Fatal("a loose token file or a dead API was not an error")
	}
	filepath.Walk(home, func(p string, i os.FileInfo, _ error) error {
		if b, _ := os.ReadFile(p); p != tokenFile && strings.Contains(string(b), tok) {
			t.Errorf("the bot token was written to %s", p)
		}
		return nil
	})
}
