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

// The owner's note is marked received with a reaction, and a refused reaction never costs the note.
// `/status` is answered by the gateway alone: no note, no event, no reaction, no wake. A stranger's
// `/status` gets nothing. Fake Bot API, fake Dapr sidecar, the real bin/jg-inbox.sh, fake ids.
func TestGatewayReceipt(t *testing.T) {
	if _, err := exec.LookPath("python3"); err != nil {
		t.Skip("jg-inbox.sh needs python3")
	}
	root, _ := filepath.Abs("../../../..")
	home, batch, events := t.TempDir(), "", []string{}
	var reactions, sends []map[string]any
	refuseReactions := false
	bot := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var m map[string]any
		json.NewDecoder(r.Body).Decode(&m)
		switch {
		case strings.HasSuffix(r.URL.Path, "/getUpdates"):
			fmt.Fprintf(w, `{"ok":true,"result":[%s]}`, batch)
		case strings.HasSuffix(r.URL.Path, "/setMessageReaction"):
			reactions = append(reactions, m)
			if refuseReactions {
				fmt.Fprint(w, `{"ok":false,"error_code":400,"description":"REACTION_INVALID"}`)
				return
			}
			fmt.Fprint(w, `{"ok":true,"result":true}`)
		default:
			sends = append(sends, m)
			fmt.Fprintf(w, `{"ok":true,"result":{"message_id":%d}}`, 900+len(sends))
		}
	}))
	defer bot.Close()
	dapr := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { events = append(events, r.URL.Path) }))
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
	notes := func() int { n, _ := filepath.Glob(state + "/inbox/*.note"); return len(n) }

	// A note is filed, then marked: one reaction on the owner's own message, and one event.
	batch = upd(10, "private", 42, 42, false, "hello overwatch")
	once()
	if notes() != 1 || len(events) != 1 || len(reactions) != 1 || reactions[0]["chat_id"] != 42.0 || reactions[0]["message_id"] != 100.0 {
		t.Fatalf("notes %d, events %v, reactions %v: want one note, one event, one reaction on message 100 of chat 42", notes(), events, reactions)
	}
	if r, _ := reactions[0]["reaction"].([]any); len(r) != 1 || r[0].(map[string]any)["type"] != "emoji" || r[0].(map[string]any)["emoji"] == "" {
		t.Fatalf("reaction = %v, want one emoji", reactions[0]["reaction"])
	}

	// Telegram refuses the reaction: the note is still filed and its event still goes out.
	refuseReactions, batch = true, upd(11, "private", 42, 42, false, "second note")
	once()
	if notes() != 2 || len(events) != 2 || len(reactions) != 2 {
		t.Fatalf("refused reaction: notes %d, events %v, reactions %d: want 2, 2, 2", notes(), events, len(reactions))
	}

	// /status, plain and from a menu with the bot's name: two answers threaded on the owner's
	// messages, and not one more note, event or reaction. A stranger's /status gets no answer.
	batch = strings.Join([]string{upd(12, "private", 42, 42, false, "/status"), upd(13, "private", 7, 7, false, "/status"), upd(14, "private", 42, 42, false, "/status@fake_bot")}, ",")
	once()
	if notes() != 2 || len(events) != 2 || len(reactions) != 2 || len(sends) != 2 {
		t.Fatalf("/status: notes %d, events %v, reactions %d, sends %d: want 2, 2, 2, 2", notes(), events, len(reactions), len(sends))
	}
	text, _ := sends[0]["text"].(string)
	rp, _ := sends[0]["reply_parameters"].(map[string]any)
	if sends[0]["chat_id"] != 42.0 || rp["message_id"] != 120.0 || !strings.Contains(text, "gateway: telegram") || !strings.Contains(text, "owner paired") || strings.Contains(text, tok) || strings.Contains(text, home) {
		t.Fatalf("/status answer = %v: want owner 42, threaded on 120, the gateway line, no token and no path", sends[0])
	}
	if d, _ := os.ReadFile(state + "/captain-chat/dropped.tsv"); strings.Count(string(d), "\n") != 1 {
		t.Fatalf("the stranger's /status should be counted as dropped once: %q", d)
	}
	filepath.Walk(home, func(p string, i os.FileInfo, _ error) error {
		if b, _ := os.ReadFile(p); p != tokenFile && strings.Contains(string(b), tok) {
			t.Errorf("the bot token was written to %s", p)
		}
		return nil
	})
	t.Logf("note: 1 reaction on message 100 of chat 42; refused reaction: note and event still filed; /status: 2 answers (%q), no note, event or reaction", text)
}
