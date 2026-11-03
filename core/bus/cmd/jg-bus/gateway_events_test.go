package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// chatLab is a scratch home with a fake Bot API (the owner's chat) and a fake Dapr sidecar (the bus).
type chatLab struct {
	a         *app
	sends     []map[string]any // sendMessage bodies the chat took
	published []string         // bus subjects posted
	botCodes  []int            // status codes for the next sendMessage calls, then 200
	daprDown  bool
}

func newChatLab(t *testing.T, withToken bool) *chatLab {
	l, home := &chatLab{}, t.TempDir()
	bot := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case len(l.botCodes) > 0:
			w.WriteHeader(l.botCodes[0])
			fmt.Fprintf(w, `{"ok":false,"error_code":%d,"description":"refused"}`, l.botCodes[0])
			l.botCodes = l.botCodes[1:]
		default:
			var m map[string]any
			json.NewDecoder(r.Body).Decode(&m)
			l.sends = append(l.sends, m)
			fmt.Fprintf(w, `{"ok":true,"result":{"message_id":%d}}`, 500+len(l.sends))
		}
	}))
	dapr := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if l.daprDown {
			http.Error(w, "down", http.StatusServiceUnavailable)
			return
		}
		l.published = append(l.published, r.URL.Path)
	}))
	t.Cleanup(bot.Close)
	t.Cleanup(dapr.Close)
	state, tokenFile, conf := filepath.Join(home, "state"), filepath.Join(home, "tg.token"), filepath.Join(home, "conf")
	if withToken {
		os.WriteFile(tokenFile, []byte(tok+"\n"), 0o600)
	}
	os.WriteFile(conf, []byte(fmt.Sprintf("set mode live\nset telegram-token-file %s\nset telegram-allow-user 42\nset telegram-api-url %s\nset dapr-http-url %s\nset dapr-pubsub p\nset subject-prefix jg.captain\n", tokenFile, bot.URL, dapr.URL)), 0o600)
	l.a = &app{home: home, state: state, data: filepath.Join(home, "data"), configFiles: []string{conf},
		record: state + "/rec", log: state + "/log", undelivered: state + "/undelivered.jsonl"}
	t.Cleanup(func() { // the token reaches no file the run wrote
		filepath.Walk(home, func(p string, _ os.FileInfo, _ error) error {
			if b, _ := os.ReadFile(p); p != tokenFile && strings.Contains(string(b), tok) {
				t.Errorf("the bot token was written to %s", p)
			}
			return nil
		})
	})
	return l
}

func (l *chatLab) lost() int { return countLines(l.a.undelivered) }

// Dapr refuses the publish: the event still reaches the owner's chat through the adapter, once; with
// the chat refusing too, or no chat, it is named undelivered; with the bus up the adapter is not used.
func TestGatewayFallback(t *testing.T) {
	l := newChatLab(t, true)
	l.daprDown = true
	l.a.emit("outcome", "t-1", "test outcome", "https://example.test/pr/1", nil)
	if len(l.sends) != 1 || l.sends[0]["chat_id"] != 42.0 || l.sends[0]["text"] != "test outcome\nhttps://example.test/pr/1" || l.lost() != 0 {
		t.Fatalf("sends %v, undelivered %d: want one outcome in chat 42", l.sends, l.lost())
	}
	l.a.emit("probe", "p-1", "not for the chat", "", nil)
	l.botCodes = []int{500}
	l.a.emit("alert", "a-1", "disk full", "", nil)
	if len(l.sends) != 1 || l.lost() != 2 || !strings.Contains(readFileString(l.a.undelivered), "disk full") {
		t.Fatalf("sends %d, undelivered %d: want the probe and the refused alert named undelivered", len(l.sends), l.lost())
	}
	l.daprDown = false
	l.a.emit("digest", "d-1", "table", "", nil)
	if len(l.sends) != 1 || len(l.published) != 1 || !strings.HasSuffix(l.published[0], "/jg.captain.digest") {
		t.Fatalf("bus up: sends %d, published %v: want the bus alone", len(l.sends), l.published)
	}
	none := newChatLab(t, false)
	none.daprDown = true
	none.a.emit("outcome", "t-2", "no chat here", "", nil)
	if len(none.sends) != 0 || none.lost() != 1 {
		t.Fatalf("no token file: sends %d, undelivered %d: want silent and undelivered", len(none.sends), none.lost())
	}
}

// The captain-gateway consumer sends card, outcome, alert and digest events and nothing else, sends a
// redelivery once, tries a failing send again, and names one that can never work undelivered.
func TestGatewayConsumer(t *testing.T) {
	l := newChatLab(t, true)
	ad, owner, err := l.a.chatTarget()
	if ad == nil || err != nil {
		t.Fatalf("chat target %v, %v", ad, err)
	}
	ad.sleep = func(time.Duration) {}
	p := l.a.gatewayPart(ad, owner)
	if p.name != "captain-gateway" || p.deliver != "new" || p.filter != "jg.captain.>" {
		t.Fatalf("part %s %s %s: want captain-gateway on new CAPTAIN events", p.name, p.deliver, p.filter)
	}
	ev := func(kind, key string) []byte { return []byte(l.a.eventJSON(1000, kind, key, kind+" "+key, "")) }
	for _, body := range [][]byte{ev("outcome", "o"), ev("probe", "p"), ev("inbound", "i"), ev("outcome", "o"), []byte(`{"key":"c","at":"2026-11-04T10:00:00Z","answer":"yes"}`)} {
		if err := p.handle(body); err != nil {
			t.Fatal(err)
		}
	}
	if len(l.sends) != 1 || l.sends[0]["text"] != "outcome o" {
		t.Fatalf("sends %v: want the outcome once", l.sends)
	}
	l.botCodes = []int{500, 502}
	if err := p.handle(ev("alert", "a")); err != nil || len(l.sends) != 2 || l.lost() != 0 {
		t.Fatalf("retry: err %v, sends %d, undelivered %d: want it sent on the third try", err, len(l.sends), l.lost())
	}
	l.botCodes = []int{403}
	if err := p.handle(ev("alert", "b")); err == nil || len(l.botCodes) != 0 || l.lost() != 1 {
		t.Fatalf("blocked: err %v, undelivered %d: want one try, then undelivered", err, l.lost())
	}
	l.botCodes = make([]int, 20)
	for i := range l.botCodes {
		l.botCodes[i] = 500
	}
	if err := p.handle(ev("alert", "c")); err == nil || l.lost() != 2 {
		t.Fatalf("chat down: err %v, undelivered %d: want undelivered after the window", err, l.lost())
	}
}
