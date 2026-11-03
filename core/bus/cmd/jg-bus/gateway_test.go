package main

import (
	"encoding/json"
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

// An answer: the owner's note, then `jg-inbox.sh reply`, is exactly one sendMessage threaded on the
// owner's message; a 429 is waited out; a long answer is split; a restart sends nothing twice.
func TestGatewayAnswers(t *testing.T) {
	if _, err := exec.LookPath("python3"); err != nil {
		t.Skip("jg-inbox.sh needs python3")
	}
	root, _ := filepath.Abs("../../../..")
	home, batch := t.TempDir(), upd(10, "private", 42, 42, false, "hello overwatch")
	var sends []map[string]any
	limited := true
	bot := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasSuffix(r.URL.Path, "/getUpdates") {
			fmt.Fprintf(w, `{"ok":true,"result":[%s]}`, batch)
			return
		}
		var m map[string]any
		json.NewDecoder(r.Body).Decode(&m)
		if limited { // the first send is rate limited once
			limited = false
			fmt.Fprint(w, `{"ok":false,"error_code":429,"parameters":{"retry_after":0}}`)
			return
		}
		sends = append(sends, m)
		fmt.Fprintf(w, `{"ok":true,"result":{"message_id":%d}}`, 900+len(sends))
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
	once() // files the note; there is no answer yet
	notes, _ := filepath.Glob(state + "/inbox/*.note")
	if len(notes) != 1 || len(sends) != 0 {
		t.Fatalf("notes %v, sends %d: want one note and no send", notes, len(sends))
	}
	id := strings.TrimSuffix(filepath.Base(notes[0]), ".note")
	if out, err := a.inbox("", "reply", id, "hi owner"); err != nil {
		t.Fatalf("reply: %v %s", err, out)
	}
	once()
	rp, _ := sends[0]["reply_parameters"].(map[string]any)
	if len(sends) != 1 || sends[0]["text"] != "hi owner" || sends[0]["chat_id"] != 42.0 || rp["message_id"] != 100.0 {
		t.Fatalf("sends = %v: want one text threaded on message 100 of chat 42", sends)
	}
	once() // a restart: the cursor and sent.jsonl keep it from sending again
	os.Remove(state + "/captain-chat/telegram.reply-cursor")
	once()
	if len(sends) != 1 {
		t.Fatalf("restart sent %d messages, want 1", len(sends))
	}
	t.Logf("note %s (message 100, chat 42) answered once: sendMessage chat_id=%v text=%q reply_to=%v; restart sent nothing more", id, sends[0]["chat_id"], sends[0]["text"], rp["message_id"])
	// A second note, answered with more than one message holds: two parts, each under the limit.
	batch = upd(11, "private", 42, 42, false, "again")
	once()
	notes, _ = filepath.Glob(state + "/inbox/*.note")
	for _, n := range notes {
		if i := strings.TrimSuffix(filepath.Base(n), ".note"); i != id {
			a.inbox(strings.Repeat(strings.Repeat("x", 99)+"\n", 50), "reply", i, "-")
		}
	}
	once()
	if len(sends) != 3 || len(sends[1]["text"].(string)) > 4096 || len(sends[2]["text"].(string)) > 4096 {
		t.Fatalf("long answer: %d sends, want 2 more", len(sends))
	}
	t.Logf("long answer: %d + %d characters, both threaded on message %v", len(sends[1]["text"].(string)), len(sends[2]["text"].(string)), sends[1]["reply_parameters"].(map[string]any)["message_id"])
}
