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
)

// chatLab is a scratch home with a fake Bot API (the owner's chat), and
// a stub board route that records the answers it is given.
type chatLab struct {
	a        *app
	sends    []map[string]any // sendMessage bodies the chat took
	botCodes []int            // status codes for the next sendMessage calls, then 200
	batch    string
	routed   string
}

func newChatLab(t *testing.T, withToken bool) *chatLab {
	l, home := &chatLab{}, t.TempDir()
	bot := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case strings.HasSuffix(r.URL.Path, "/getUpdates"):
			fmt.Fprintf(w, `{"ok":true,"result":[%s]}`, l.batch)
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
	t.Cleanup(bot.Close)
	root, state, tokenFile, conf := filepath.Join(home, "root"), filepath.Join(home, "state"), filepath.Join(home, "tg.token"), filepath.Join(home, "conf")
	l.routed = filepath.Join(home, "routed")
	os.MkdirAll(filepath.Join(root, "bin"), 0o755)
	os.WriteFile(filepath.Join(root, "bin", "jg-board-answers.sh"), []byte("#!/bin/sh\necho \"$2|$4\" >> "+l.routed+"\n"), 0o755)
	if withToken {
		os.WriteFile(tokenFile, []byte(tok+"\n"), 0o600)
	}
	os.WriteFile(conf, []byte(fmt.Sprintf("set mode direct\nset telegram-token-file %s\nset telegram-allow-user 42\nset telegram-api-url %s\nset subject-prefix jg.captain\n", tokenFile, bot.URL)), 0o600)
	l.a = &app{root: root, home: home, state: state, data: filepath.Join(home, "data"), configFiles: []string{conf},
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

// An event reaches the owner's chat through the adapter, once; with the chat refusing, or no chat, or
// a kind the chat does not carry, it is named undelivered.
func TestGatewayDirectSend(t *testing.T) {
	l := newChatLab(t, true)
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
	none := newChatLab(t, false)
	none.a.emit("outcome", "t-2", "no chat here", "", nil)
	if len(none.sends) != 0 || none.lost() != 1 {
		t.Fatalf("no token file: sends %d, undelivered %d: want silent and undelivered", len(none.sends), none.lost())
	}
}

// A card reaches the chat; the owner's reply to that message is recorded as the card's answer and
// taken by the board's own route.
func TestGatewayCardReply(t *testing.T) {
	l := newChatLab(t, true)
	ad, owner, _ := l.a.chatTarget()
	if err := l.a.sendEvent(ad, owner, event{At: 1000, Kind: "card", Key: "card-7", Text: "Merge the PR?"}); err != nil || len(l.sends) != 1 ||
		!strings.HasSuffix(l.sends[0]["text"].(string), "Reply to this message to answer.") {
		t.Fatalf("card: %v, sends %v", err, l.sends)
	}
	reply := func(id int, text string) { // a reply to message 501, the card
		l.batch = fmt.Sprintf(`{"update_id":%d,"message":{"message_id":%d,"text":%q,"reply_to_message":{"message_id":501},"from":{"id":42},"chat":{"id":42,"type":"private"}}}`, id, id*10, text)
		if err := l.a.pollOnce(ad, []string{"42"}); err != nil {
			t.Fatal(err)
		}
	}
	reply(31, "yes, merge")
	rec := readFileString(l.a.record)
	if !strings.Contains(rec, `"key":"card-7"`) || !strings.Contains(rec, `"answer":"yes, merge"`) {
		t.Fatalf("record %q: want one reply event for card-7", rec)
	}
	if got := readFileString(l.routed); got != "card-7|yes, merge\n" {
		t.Fatalf("routed %q: want the board route to take the answer", got)
	}
}

// mustJSON is how sent.jsonl spells a text, so a test can look for it word for word.
func mustJSON(v any) []byte {
	b, _ := json.Marshal(v)
	return b
}
