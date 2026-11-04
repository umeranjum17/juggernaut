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
	"sync"
	"testing"
	"time"
)

// A fake Bot API that counts sendChatAction per chat and can refuse it.
type typingAPI struct {
	mu      sync.Mutex
	actions map[string]int
	refuse  bool
	batch   string
	sends   int
}

func (f *typingAPI) count(chat string) int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.actions[chat]
}

func (f *typingAPI) handler(t *testing.T) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var m map[string]any
		json.NewDecoder(r.Body).Decode(&m)
		f.mu.Lock()
		defer f.mu.Unlock()
		switch {
		case strings.HasSuffix(r.URL.Path, "/getUpdates"):
			fmt.Fprintf(w, `{"ok":true,"result":[%s]}`, f.batch)
		case strings.HasSuffix(r.URL.Path, "/sendChatAction"):
			if m["action"] != "typing" {
				t.Errorf("chat action = %v, want typing", m["action"])
			}
			f.actions[fmt.Sprint(m["chat_id"])]++
			if f.refuse {
				fmt.Fprint(w, `{"ok":false,"error_code":403,"description":"Forbidden: bot was blocked"}`)
				return
			}
			fmt.Fprint(w, `{"ok":true,"result":true}`)
		case strings.HasSuffix(r.URL.Path, "/setMessageReaction"):
			fmt.Fprint(w, `{"ok":true,"result":true}`)
		default:
			f.sends++
			fmt.Fprintf(w, `{"ok":true,"result":{"message_id":%d}}`, 900+f.sends)
		}
	}
}

func eventually(t *testing.T, what string, ok func() bool) {
	t.Helper()
	for end := time.Now().Add(5 * time.Second); time.Now().Before(end); time.Sleep(5 * time.Millisecond) {
		if ok() {
			return
		}
	}
	t.Fatalf("timed out waiting for %s", what)
}

// The typing indicator: it starts when the first note of a chat opens and repeats while the note
// is open; one chat shows one indicator however many notes it has; it stops at once when the last
// note is answered and when the hard cap passes; a refused action is logged once and costs nothing;
// shutdown stops it. A fake Bot API and the real Telegram adapter; the interval is shortened.
func TestGatewayTypingIndicator(t *testing.T) {
	api := &typingAPI{actions: map[string]int{}}
	bot := httptest.NewServer(api.handler(t))
	defer bot.Close()
	var logged []string
	var logMu sync.Mutex
	ad := &telegram{base: bot.URL, token: tok, wait: 0, sleep: func(time.Duration) {}}
	newT := func(cap time.Duration) *typer {
		ty := newTyper(ad, 20*time.Millisecond, cap, func(s string) { logMu.Lock(); logged = append(logged, s); logMu.Unlock() })
		go ty.run()
		return ty
	}
	steady := func(chat string) int { // the count after the indicator went quiet
		time.Sleep(120 * time.Millisecond)
		n := api.count(chat)
		time.Sleep(120 * time.Millisecond)
		if api.count(chat) != n {
			t.Fatalf("chat %s still got typing actions after the indicator should have stopped", chat)
		}
		return n
	}

	// Repeats while open, one per chat for two notes, stops once both are answered.
	ty := newT(time.Minute)
	ty.begin("42", "note-a")
	eventually(t, "the first action", func() bool { return api.count("42") >= 1 })
	ty.begin("42", "note-b")
	ty.begin("77", "note-c")
	eventually(t, "repeated actions", func() bool { return api.count("42") >= 4 && api.count("77") >= 3 })
	ty.end("note-a") // note-b still open: the chat keeps its indicator
	before := api.count("42")
	eventually(t, "42 still typing with one note open", func() bool { return api.count("42") > before+1 })
	ty.end("note-b")
	ty.end("note-c")
	steady("42")
	steady("77")
	ty.shutdown()

	// One indicator per chat, not per note: three open notes send about as many actions as one.
	api.mu.Lock()
	api.actions = map[string]int{}
	api.mu.Unlock()
	one, three := newT(time.Minute), newT(time.Minute)
	one.begin("1", "n1")
	three.begin("3", "n1")
	three.begin("3", "n2")
	three.begin("3", "n3")
	time.Sleep(300 * time.Millisecond)
	one.end("n1")
	three.end("n1")
	three.end("n2")
	three.end("n3")
	steady("1")
	steady("3")
	if a, b := api.count("1"), api.count("3"); b > a+3 {
		t.Fatalf("one note sent %d actions, three notes in one chat sent %d: want one indicator per chat", a, b)
	}
	one.shutdown()
	three.shutdown()

	// The hard cap: a note nobody answers stops by itself.
	api.mu.Lock()
	api.actions = map[string]int{}
	api.mu.Unlock()
	capped := newT(150 * time.Millisecond)
	capped.begin("5", "never-answered")
	eventually(t, "actions before the cap", func() bool { return api.count("5") >= 2 })
	n := steady("5")
	if n > 12 {
		t.Fatalf("a 150 ms cap at a 20 ms interval sent %d actions", n)
	}
	capped.shutdown()

	// Refused actions: logged once, never fatal, and the indicator keeps trying.
	api.mu.Lock()
	api.actions, api.refuse = map[string]int{}, true
	api.mu.Unlock()
	refused := newT(time.Minute)
	refused.begin("9", "n")
	eventually(t, "refused attempts", func() bool { return api.count("9") >= 4 })
	refused.end("n")
	logMu.Lock()
	if len(logged) != 1 || !strings.Contains(logged[0], "403") || strings.Contains(logged[0], tok) {
		t.Fatalf("logged = %q: want one 403 line without the token", logged)
	}
	logMu.Unlock()
	steady("9")

	// Shutdown stops a live indicator.
	api.mu.Lock()
	api.actions, api.refuse = map[string]int{}, false
	api.mu.Unlock()
	live := newT(time.Minute)
	live.begin("11", "n")
	eventually(t, "a live indicator", func() bool { return api.count("11") >= 2 })
	live.shutdown()
	time.Sleep(60 * time.Millisecond)
	steady("11")
	refused.shutdown()
}

// The whole path: the gateway files an owner note, the chat shows typing while it is open, and the
// reply made by the real `jg-inbox.sh reply` ends it; a note filed with no reply is capped. A typing
// failure never stops the note or its reply. Fake Bot API, fake Dapr sidecar, the real jg-inbox.sh.
func TestGatewayTypingUntilReply(t *testing.T) {
	if _, err := exec.LookPath("python3"); err != nil {
		t.Skip("jg-inbox.sh needs python3")
	}
	root, _ := filepath.Abs("../../../..")
	home := t.TempDir()
	api := &typingAPI{actions: map[string]int{}, refuse: true, batch: upd(10, "private", 42, 42, false, "hello overwatch")}
	bot := httptest.NewServer(api.handler(t))
	defer bot.Close()
	dapr := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	defer dapr.Close()
	tokenFile, conf, state := filepath.Join(home, "tg.token"), filepath.Join(home, "conf"), filepath.Join(home, "state")
	os.WriteFile(tokenFile, []byte(tok+"\n"), 0o600)
	os.WriteFile(conf, []byte(fmt.Sprintf("set gateway-adapters telegram\nset telegram-token-file %s\nset telegram-allow-user 42\nset telegram-api-url %s\nset dapr-http-url %s\nset dapr-pubsub p\nset subject-prefix jg.captain\nset chat-typing-cap-seconds 90\n", tokenFile, bot.URL, dapr.URL)), 0o600)
	a := &app{root: root, home: home, state: state, data: filepath.Join(home, "data"), configFiles: []string{conf}, record: state + "/rec", log: state + "/log"}
	if c := a.typerFor(&telegram{}); c.cap != 90*time.Second || c.every != 4*time.Second {
		t.Fatalf("typer cap %v every %v, want the configured 90s cap and the 4s interval", c.cap, c.every)
	}
	ad := &telegram{base: bot.URL, token: tok, wait: 0, sleep: func(time.Duration) {}}
	a.typing = newTyper(ad, 20*time.Millisecond, time.Minute, func(s string) { a.noteFailure("gateway typing", s) })
	go a.typing.run()
	defer a.typing.shutdown()

	// Filed while Telegram refuses the action: the note is filed anyway.
	if err := a.pollOnce(ad, []string{"42"}); err != nil {
		t.Fatalf("pollOnce: %v", err)
	}
	notes, _ := filepath.Glob(state + "/inbox/*.note")
	if len(notes) != 1 {
		t.Fatalf("notes %v: want the note filed while the chat action is refused", notes)
	}
	eventually(t, "refused actions", func() bool { return api.count("42") >= 3 })
	api.mu.Lock()
	api.refuse = false
	api.mu.Unlock()
	before := api.count("42")
	eventually(t, "accepted actions while the note is open", func() bool { return api.count("42") >= before+3 })

	// The reply ends it: the follower sees the answer and the indicator goes quiet.
	id := strings.TrimSuffix(filepath.Base(notes[0]), ".note")
	if out, err := a.inbox("", "reply", id, "hi owner"); err != nil {
		t.Fatalf("reply: %v %s", err, out)
	}
	if err := a.followReplies(ad); err != nil {
		t.Fatalf("followReplies: %v", err)
	}
	time.Sleep(100 * time.Millisecond) // an action already in flight
	n := api.count("42")
	time.Sleep(200 * time.Millisecond)
	api.mu.Lock()
	sends := api.sends
	api.mu.Unlock()
	if api.count("42") != n || sends != 1 {
		t.Fatalf("after the reply: actions %d then %d, answers %d: want the indicator stopped and one answer sent", n, api.count("42"), sends)
	}
	if b, _ := os.ReadFile(state + "/log"); strings.Contains(string(b), tok) || !strings.Contains(string(b), "gateway typing failed") {
		t.Fatalf("log = %q: want the refusal named and no token", b)
	}
	t.Logf("note %s: typing while open (%d actions), stopped by the reply, one answer sent; refused actions were logged and the note was filed", id, n)
}
