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

func tap(id int, from, chat, msg int, data string) string {
	return fmt.Sprintf(`{"update_id":%d,"callback_query":{"id":"cb%d","data":%q,"from":{"id":%d,"is_bot":false},"message":{"message_id":%d,"chat":{"id":%d,"type":"private"}}}}`, id, id, data, from, msg, chat)
}

// Overwatch asks the owner to choose with `jg-inbox.sh reply --option`: the pictures go as an album,
// the question goes with one button per option, and the owner's tap comes back as one pick note.
// Against a fake Bot API: send, tap, a second tap, a stranger, a stale set, a replayed tap, and a
// set that allows changing.
func TestGatewayOptions(t *testing.T) {
	if _, err := exec.LookPath("python3"); err != nil {
		t.Skip("jg-inbox.sh needs python3")
	}
	root, _ := filepath.Abs("../../../..")
	home, batch := t.TempDir(), upd(10, "private", 42, 42, false, "show me options")
	type seen struct{ method, raw string }
	var calls []seen
	nextID := 900
	bot := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		method := r.URL.Path[strings.LastIndex(r.URL.Path, "/")+1:]
		if method == "getUpdates" {
			fmt.Fprintf(w, `{"ok":true,"result":[%s]}`, batch)
			return
		}
		raw, _ := io.ReadAll(r.Body)
		calls = append(calls, seen{method, string(raw)})
		nextID++
		if method == "answerCallbackQuery" || method == "setMessageReaction" || method == "editMessageText" {
			fmt.Fprint(w, `{"ok":true,"result":true}`)
			return
		}
		fmt.Fprintf(w, `{"ok":true,"result":{"message_id":%d}}`, nextID)
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
	count := func(method string) (n int) {
		for _, c := range calls {
			if c.method == method {
				n++
			}
		}
		return n
	}
	last := func(method string) (m map[string]any) {
		for _, c := range calls {
			if c.method == method {
				json.Unmarshal([]byte(c.raw), &m)
			}
		}
		return m
	}
	notes := func() (out []string) {
		files, _ := filepath.Glob(state + "/inbox/*.note")
		for _, f := range files {
			b, _ := os.ReadFile(f)
			out = append(out, string(b))
		}
		return out
	}
	pickNotes := func() (n int) {
		for _, b := range notes() {
			if strings.Contains(b, "\npick: ") {
				n++
			}
		}
		return n
	}
	// buttons is the labels and callback data of the last keyboard the bot sent.
	buttons := func() (labels, data []string) {
		kb, _ := last("sendMessage")["reply_markup"].(map[string]any)
		rows, _ := kb["inline_keyboard"].([]any)
		for _, r := range rows {
			b := r.([]any)[0].(map[string]any)
			labels, data = append(labels, b["text"].(string)), append(data, b["callback_data"].(string))
		}
		return
	}

	once() // files the owner's note
	id := strings.TrimSuffix(filepath.Base(func() string { f, _ := filepath.Glob(state + "/inbox/*.note"); return f[0] }()), ".note")
	pic := filepath.Join(t.TempDir(), "design-a.png")
	os.WriteFile(pic, pngBytes(1), 0o600)
	if out, err := a.inbox("", "reply", id, "--attach", pic, "--option", "Option A", "--option", "Option B", "Which design?"); err != nil {
		t.Fatalf("reply: %v %s", err, out)
	}
	once()
	if count("sendPhoto") != 1 || count("sendMessage") != 1 {
		t.Fatalf("calls %v: want the picture and one question with buttons", calls)
	}
	labels, data := buttons()
	if q := last("sendMessage"); q["text"] != "Which design?" || len(labels) != 2 || labels[0] != "Option A" || labels[1] != "Option B" {
		t.Fatalf("question %v, buttons %v", q["text"], labels)
	}
	for _, d := range data {
		if len(d) > 64 || strings.Contains(d, "Option") {
			t.Fatalf("callback data %q must be short and opaque", d)
		}
	}
	askMsg := nextID // the question was the last message the fake made
	if !strings.Contains(string(mustRead(state+"/captain-chat/options.jsonl")), `"Option A"`) {
		t.Fatal("the option set was not stored")
	}

	// A stranger's tap, then a tap on an unknown set, then one on another message: each is answered, none filed.
	batch = strings.Join([]string{tap(20, 7, 7, askMsg, data[0]), tap(21, 42, 42, askMsg, "o:s999:0"), tap(22, 42, 42, askMsg+5, data[0]), tap(23, 42, 42, askMsg, "junk")}, ",")
	once()
	if count("answerCallbackQuery") != 4 || pickNotes() != 0 || count("editMessageText") != 0 {
		t.Fatalf("answers %d, picks %d, edits %d: want 4 answers and nothing filed", count("answerCallbackQuery"), pickNotes(), count("editMessageText"))
	}

	// The owner taps Option B: answered, marked, filed once. A second tap on A is answered and not filed.
	batch = tap(30, 42, 42, askMsg, data[1])
	once()
	set := strings.Split(data[1], ":")[1]
	var pick string
	for _, b := range notes() {
		if strings.Contains(b, "\npick: ") {
			pick = b[strings.Index(b, "\n--\n")+4:]
		}
	}
	if want := fmt.Sprintf("[chat telegram 42:%d]\npick: Option B (%s)\n", askMsg, set); pick != want || pickNotes() != 1 {
		t.Fatalf("pick note %q (%d), want %q", pick, pickNotes(), want)
	}
	if e := last("editMessageText"); count("editMessageText") != 1 || !strings.Contains(fmt.Sprint(e["text"]), "Picked: Option B") || fmt.Sprint(e["reply_markup"]) != "map[inline_keyboard:[]]" {
		t.Fatalf("edit = %v: want the pick shown and the buttons removed", e)
	}
	if got := last("answerCallbackQuery")["text"]; got != "Picked: Option B" {
		t.Fatalf("answer = %v", got)
	}
	batch = tap(31, 42, 42, askMsg, data[0])
	once()
	if got := last("answerCallbackQuery")["text"]; pickNotes() != 1 || got != "Already picked: Option B" {
		t.Fatalf("second tap: %d picks, answer %v", pickNotes(), got)
	}
	// A crash before the offset commit replays the first tap: the same note, no second one.
	os.Remove(state + "/captain-chat/telegram.offset")
	batch = tap(30, 42, 42, askMsg, data[1])
	once()
	if pickNotes() != 1 {
		t.Fatalf("a replayed tap filed %d picks", pickNotes())
	}
	// The pick answers like any chat message: a reply to the pick note goes to the options message.
	for _, f := range func() []string { g, _ := filepath.Glob(state + "/inbox/*.note"); return g }() {
		if b, _ := os.ReadFile(f); strings.Contains(string(b), "\npick: ") {
			if out, err := a.inbox("", "reply", strings.TrimSuffix(filepath.Base(f), ".note"), "going with B"); err != nil {
				t.Fatalf("reply to the pick: %v %s", err, out)
			}
		}
	}
	once()
	if rp, _ := last("sendMessage")["reply_parameters"].(map[string]any); last("sendMessage")["text"] != "going with B" || rp["message_id"] != float64(askMsg) {
		t.Fatalf("reply to the pick = %v", last("sendMessage"))
	}

	// A set that allows changing: A, then B (a second note), then B again (nothing).
	batch = upd(40, "private", 42, 42, false, "pick a colour")
	once()
	for _, f := range func() []string { g, _ := filepath.Glob(state + "/inbox/*.note"); return g }() {
		if b, _ := os.ReadFile(f); strings.Contains(string(b), "pick a colour") {
			if out, err := a.inbox("", "reply", strings.TrimSuffix(filepath.Base(f), ".note"), "--option", "Red", "--option", "Blue", "--allow-change", "Colour?"); err != nil {
				t.Fatalf("reply: %v %s", err, out)
			}
		}
	}
	once()
	askMsg = nextID
	_, data = buttons()
	for i, d := range []string{data[0], data[1], data[1]} {
		batch = tap(50+i, 42, 42, askMsg, d)
		once()
	}
	e := last("editMessageText")
	if pickNotes() != 3 || count("editMessageText") != 3 || !strings.Contains(fmt.Sprint(e["reply_markup"]), "✅ Blue") {
		t.Fatalf("changeable set: %d picks (want 3 in all), %d edits, last edit %v", pickNotes(), count("editMessageText"), e)
	}
	filepath.Walk(home, func(p string, i os.FileInfo, _ error) error {
		if b, _ := os.ReadFile(p); p != tokenFile && strings.Contains(string(b), tok) {
			t.Errorf("the bot token was written to %s", p)
		}
		return nil
	})
	t.Logf("options: question sent with %d buttons, owner tap filed one pick note, a second tap, a stranger, a stale set and a replay filed none; a changeable set filed a second pick on change", len(labels))
}
