package main

import (
	"encoding/json"
	"fmt"
	"io"
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
		if !strings.HasPrefix(r.URL.Path, "/bot"+tok+"/") || r.URL.Query().Get("allowed_updates") != `["message","callback_query"]` {
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
	// The mirror: the owner's message shows in the wake the session reads, once, with its source;
	// the three dropped ones show nowhere.
	wakes := func() string { q, _ := os.ReadFile(state + "/.wake-queue"); return string(q) }
	if w := wakes(); strings.Count(w, "captain inbox note") != 1 || !strings.Contains(w, "[chat telegram 42:100] hello overwatch") {
		t.Fatalf("want one mirrored wake naming the source and text, got %q", w)
	}
	for _, dropped := range []string{"stranger", "group", "bot"} {
		if strings.Contains(wakes(), dropped) {
			t.Fatalf("dropped message %q was mirrored: %q", dropped, wakes())
		}
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
	if strings.Count(wakes(), "captain inbox note") != 1 {
		t.Fatalf("a replay mirrored the message again: %q", wakes())
	}
	// The KPI ledger counts the owner's note once, with the inbox note id; the replay and the
	// dropped updates added no row.
	rows := func() int {
		raw, _ := os.ReadFile(filepath.Join(home, "data", "overwatch-kpi.jsonl"))
		return strings.Count(string(raw), "\n")
	}
	if raw, _ := os.ReadFile(filepath.Join(home, "data", "overwatch-kpi.jsonl")); rows() != 1 ||
		!strings.Contains(string(raw), `"text":"hello overwatch"`) || !strings.Contains(string(raw), `"id":"`+strings.TrimSuffix(filepath.Base(notes[0]), ".note")+`"`) {
		t.Fatalf("want one ledger row for the note with its inbox id, got %q", raw)
	}
	// A second note is a second row; a home whose KPI reads off records nothing.
	batch = upd(15, "private", 42, 42, false, "second note")
	if code := once(); code != 0 || rows() != 2 {
		t.Fatalf("exit %d, %d rows: want a second row for a second note", code, rows())
	}
	os.MkdirAll(filepath.Join(home, "config"), 0o700)
	os.WriteFile(filepath.Join(home, "config", "overwatch-kpi"), []byte("off\n"), 0o600)
	batch = upd(16, "private", 42, 42, false, "third note, kpi off")
	if code := once(); code != 0 || rows() != 2 {
		t.Fatalf("exit %d, %d rows: a home with the KPI off must record nothing", code, rows())
	}
	os.Remove(filepath.Join(home, "config", "overwatch-kpi"))
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
		if strings.HasSuffix(r.URL.Path, "/setMessageReaction") { // the receipt for a filed note, not an answer
			fmt.Fprint(w, `{"ok":true,"result":true}`)
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
			// The reply answers his note, so it carries the ask block (2026-11-05): his words and
			// their date, done, not done, next, and a proof link.
			raw, _ := os.ReadFile(n)
			at := ""
			for _, line := range strings.Split(string(raw), "\n") {
				if strings.HasPrefix(line, "at=") && len(line) >= 13 {
					at = line[3:13]
				}
			}
			block := fmt.Sprintf("Your ask: \"[chat telegram 42:11] again\" (%s)\nDone: the answer is sent.\nNot done: nothing.\nNext: read it.\nProof: https://example.invalid/proof\n", at)
			a.inbox(block+strings.Repeat(strings.Repeat("x", 99)+"\n", 50), "reply", i, "-")
		}
	}
	once()
	if len(sends) != 3 || len(sends[1]["text"].(string)) > 4096 || len(sends[2]["text"].(string)) > 4096 {
		t.Fatalf("long answer: %d sends, want 2 more", len(sends))
	}
	t.Logf("long answer: %d + %d characters, both threaded on message %v", len(sends[1]["text"].(string)), len(sends[2]["text"].(string)), sends[1]["reply_parameters"].(map[string]any)["message_id"])
}

// Pairing records the first person to send the code, status asks getMe, and no token file means the
// gateway is off without a word. Fake ids only.
func TestGatewayPairAndStatus(t *testing.T) {
	home, state, batch, sent := t.TempDir(), t.TempDir(), "", ""
	bot := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case strings.HasSuffix(r.URL.Path, "/getUpdates"):
			fmt.Fprintf(w, `{"ok":true,"result":[%s]}`, batch)
		case strings.HasSuffix(r.URL.Path, "/getMe"):
			fmt.Fprint(w, `{"ok":true,"result":{"username":"fake_bot"}}`)
		default:
			b, _ := io.ReadAll(r.Body)
			sent = string(b)
			fmt.Fprint(w, `{"ok":true,"result":{"message_id":9}}`)
		}
	}))
	defer bot.Close()
	conf, tokenPath := filepath.Join(home, "config", "captain-channel"), filepath.Join(home, "config", "captain-chat", "telegram.token")
	os.MkdirAll(filepath.Dir(tokenPath), 0o700)
	os.WriteFile(conf, []byte("set telegram-api-url "+bot.URL+"\nset keep me\n"), 0o600)
	a := &app{root: ".", home: home, state: state, data: home, configFiles: []string{conf}}

	if a.gateway([]string{"enabled"}) != 1 || a.gateway([]string{"serve"}) != 0 {
		t.Fatal("with no token file enabled must say no and serve must return 0")
	}
	t.Logf("no bot token file: gateway enabled=no, serve exits 0 with no output, so no unit is installed and nothing fails")
	os.WriteFile(tokenPath, []byte(tok+"\n"), 0o644)
	os.Chmod(tokenPath, 0o644) // the mode is the test: a restrictive umask must not narrow it
	if _, _, _, err := a.readTokenFile(); err == nil || strings.Contains(err.Error(), tok) {
		t.Fatalf("a group-readable token file must be refused without naming the token: %v", err)
	}
	os.Chmod(tokenPath, 0o600)

	// A wrong text, a bot with the code, then a person with it: that person is the owner.
	pairCode = func() string { return "123456" }
	batch = strings.Join([]string{upd(20, "private", 5, 5, false, "hi"), upd(21, "private", 6, 6, true, "123456"), upd(22, "private", 77, 77, false, "123456"), upd(23, "private", 8, 8, false, "later")}, ",")
	if a.gateway([]string{"status"}) != 0 || a.gateway([]string{"pair"}) != 0 || a.gateway([]string{"enabled"}) != 0 {
		t.Fatal("status, pair and enabled must all succeed with a working bot and a token file")
	}
	off, _ := os.ReadFile(state + "/captain-chat/telegram.offset")
	if got := fileGet(conf, "telegram-allow-user"); got != "77" || fileGet(conf, "keep") != "me" || string(off) != "23\n" {
		t.Fatalf("allow-user %q offset %q: want 77 and 23 (past the code, not past what follows), other keys kept", got, off)
	}
	if !strings.Contains(sent, `"chat_id":77`) || strings.Contains(sent, tok) {
		t.Fatalf("pairing confirmation = %q", sent)
	}
	if unit, err := (&app{root: ".", home: home, state: state, runtime: home}).buildUnit("gateway"); err != nil || !strings.Contains(unit, `"gateway" "serve"`) || strings.Contains(unit, tok) {
		t.Fatalf("gateway unit = %q, %v", unit, err)
	}
}

// A push is one unprompted message to the owner's private chat, split when long and not threaded.
// A home with no token file, or a channel that is not live, sends nothing and says nothing.
func TestGatewayPush(t *testing.T) {
	home := t.TempDir()
	var sends []map[string]any
	bot := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var m map[string]any
		json.NewDecoder(r.Body).Decode(&m)
		if strings.HasSuffix(r.URL.Path, "/sendMessage") {
			sends = append(sends, m)
		}
		fmt.Fprintf(w, `{"ok":true,"result":{"message_id":%d}}`, 900+len(sends))
	}))
	defer bot.Close()
	tokenFile, conf, state := filepath.Join(home, "tg.token"), filepath.Join(home, "conf"), filepath.Join(home, "state")
	write := func(extra string) {
		os.WriteFile(conf, []byte(fmt.Sprintf("set gateway-adapters telegram\nset telegram-token-file %s\nset telegram-allow-user 42\nset telegram-api-url %s\n%s", tokenFile, bot.URL, extra)), 0o600)
	}
	write("set mode live\n")
	a := &app{root: ".", home: home, state: state, data: filepath.Join(home, "data"), configFiles: []string{conf}, record: state + "/rec", log: state + "/log"}
	push := func(args ...string) int { return a.gateway(append([]string{"push"}, args...)) }

	if code := push("NATS server: live"); code != 0 || len(sends) != 0 {
		t.Fatalf("no token file: exit %d, %d sends; want a silent no-op", code, len(sends))
	}
	os.WriteFile(tokenFile, []byte(tok+"\n"), 0o600)
	if code := push("NATS server:", "live"); code != 0 || len(sends) != 1 {
		t.Fatalf("exit %d, %d sends; want one", code, len(sends))
	}
	if sends[0]["chat_id"] != float64(42) || sends[0]["text"] != "NATS server: live" || sends[0]["reply_parameters"] != nil {
		t.Fatalf("push = %v; want owner 42, the text, no thread", sends[0])
	}
	sends = nil
	if push(strings.Repeat("row\n", 2000)) != 0 || len(sends) != 2 {
		t.Fatalf("a long push went as %d messages, want 2", len(sends))
	}
	sends = nil
	write("set mode off\n")
	if code := push("hello"); code != 0 || len(sends) != 0 {
		t.Fatalf("channel off: exit %d, %d sends; want none", code, len(sends))
	}
}
