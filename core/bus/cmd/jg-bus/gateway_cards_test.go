package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

// A decision card reaches the owner with one button per option and stays in step with the board:
// a tap answers the card and edits the message; a board answer, a text reply, a withdrawn card and a
// changed card edit it too; a late tap, a stranger's tap and a forged one answer nothing; an edit
// that fails is tried again; and a restarted gateway still knows the message. Against a fake Bot API.
func TestGatewayCardButtons(t *testing.T) {
	type seen struct{ method, raw string }
	var calls []seen
	failEdits, batch := 0, ""
	bot := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		method := r.URL.Path[strings.LastIndex(r.URL.Path, "/")+1:]
		if method == "getUpdates" {
			fmt.Fprintf(w, `{"ok":true,"result":[%s]}`, batch)
			return
		}
		raw, _ := io.ReadAll(r.Body)
		calls = append(calls, seen{method, string(raw)})
		switch {
		case method == "editMessageText" && failEdits > 0:
			failEdits--
			w.WriteHeader(http.StatusBadGateway)
			fmt.Fprint(w, `{"ok":false,"error_code":502,"description":"bad gateway"}`)
		case method == "sendMessage":
			fmt.Fprintf(w, `{"ok":true,"result":{"message_id":%d}}`, 700+len(calls))
		default:
			fmt.Fprint(w, `{"ok":true,"result":true}`)
		}
	}))
	defer bot.Close()
	var published []string
	dapr := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		published = append(published, string(b))
	}))
	defer dapr.Close()
	home := t.TempDir()
	tokenFile, conf := filepath.Join(home, "tg.token"), filepath.Join(home, "conf")
	os.WriteFile(tokenFile, []byte(tok+"\n"), 0o600)
	os.WriteFile(conf, []byte(fmt.Sprintf("set mode live\nset telegram-token-file %s\nset telegram-allow-user 42\nset telegram-api-url %s\nset dapr-http-url %s\nset dapr-pubsub p\nset subject-prefix jg.captain\n", tokenFile, bot.URL, dapr.URL)), 0o600)
	newApp := func() *app { // a restart: the same state on disk, nothing in memory
		state := filepath.Join(home, "state")
		return &app{root: filepath.Join(home, "root"), home: home, state: state, data: filepath.Join(home, "data"), configFiles: []string{conf},
			record: state + "/rec", log: state + "/log", undelivered: state + "/undelivered.jsonl"}
	}
	a := newApp()
	ad, owner, err := a.chatTarget()
	if ad == nil || err != nil {
		t.Fatalf("chat target %v, %v", ad, err)
	}
	ad.sleep = func(d time.Duration) {}
	last := func(method string) (m map[string]any) {
		for _, c := range calls {
			if c.method == method {
				m = nil
				json.Unmarshal([]byte(c.raw), &m)
			}
		}
		return m
	}
	count := func(method string) (n int) {
		for _, c := range calls {
			if c.method == method {
				n++
			}
		}
		return n
	}
	buttons := func(m map[string]any) (labels, data []string) {
		kb, _ := m["reply_markup"].(map[string]any)
		rows, _ := kb["inline_keyboard"].([]any)
		for _, r := range rows {
			b := r.([]any)[0].(map[string]any)
			labels, data = append(labels, b["text"].(string)), append(data, b["callback_data"].(string))
		}
		return
	}
	ingest := func(update string) {
		t.Helper()
		batch = update
		if err := a.pollOnce(ad, []string{"42"}); err != nil {
			t.Fatal(err)
		}
	}
	card := func(key string, at int64, text string, opts ...cardOption) event {
		return event{At: at, Kind: "card", Key: key, Text: text, Options: opts}
	}
	yes, no := cardOption{"yes", "Yes"}, cardOption{"no", "No"}

	// The card goes out with a button per option; the data is short and names no card or option.
	if err := a.sendEvent(ad, owner, card("merge-pr", 1000, "Merge the PR?", yes, no)); err != nil {
		t.Fatal(err)
	}
	sent := last("sendMessage")
	labels, data := buttons(sent)
	if len(labels) != 2 || labels[0] != "Yes" || labels[1] != "No" || !strings.Contains(sent["text"].(string), "Merge the PR?") {
		t.Fatalf("card message %v: want two buttons under the question", sent)
	}
	for _, d := range data {
		if len(d) >= 64 || strings.Contains(d, "merge-pr") {
			t.Fatalf("callback data %q: want under 64 bytes and not the card id", d)
		}
	}
	a.sendEvent(ad, owner, card("merge-pr", 1000, "Merge the PR?", yes, no)) // a redelivery
	if count("sendMessage") != 1 {
		t.Fatalf("%d sends: want a redelivery to send nothing", count("sendMessage"))
	}
	msg := int(700 + 1) // the id the fake gave the first send

	// A stranger's tap, a tap on another message and a forged one answer nothing.
	ingest(tap(1, 7, 7, msg, data[0]))
	ingest(tap(2, 42, 42, msg+5, data[0]))
	ingest(tap(3, 42, 42, msg, "c:deadbeef0000:0"))
	ingest(tap(4, 42, 42, msg, strings.Replace(data[0], ":0", ":9", 1)))
	if len(published) != 0 || count("editMessageText") != 0 {
		t.Fatalf("published %v, edits %d: want no answer from a stranger or a forged tap", published, count("editMessageText"))
	}

	// The owner taps Yes: the answer goes out as a reply event, the tap is acknowledged, the message
	// shows the answer and has no buttons.
	ingest(tap(5, 42, 42, msg, data[0]))
	if len(published) != 1 || !strings.Contains(published[0], `"key":"merge-pr"`) || !strings.Contains(published[0], `"answer":"yes"`) || !strings.Contains(published[0], `"label":"Yes"`) {
		t.Fatalf("published %v: want one reply event answering yes", published)
	}
	edit := last("editMessageText")
	kb, _ := edit["reply_markup"].(map[string]any)
	if rows, _ := kb["inline_keyboard"].([]any); len(rows) != 0 || !strings.Contains(edit["text"].(string), "Answered: Yes") {
		t.Fatalf("edit %v: want the answer shown and no buttons", edit)
	}
	if got := last("answerCallbackQuery")["text"]; got != "Answered: Yes" {
		t.Fatalf("toast %v: want the answer", got)
	}

	// A late tap, from this restarted gateway, is refused and answers nothing again.
	a = newApp()
	ingest(tap(6, 42, 42, msg, data[1]))
	if got := last("answerCallbackQuery")["text"]; got != "Already answered." || len(published) != 1 {
		t.Fatalf("late tap: toast %v, published %d: want Already answered and no second answer", got, len(published))
	}

	// The board answers a card: the message is edited, and a tap after that is late.
	a.sendEvent(ad, owner, card("pick-day", 2000, "Which day?", cardOption{"a", "A: Today"}, cardOption{"b", "B: Friday"}))
	dayMsg := a.cards()["pick-day"].Message
	if err := a.sendEvent(ad, owner, event{At: 2100, Kind: "card-close", Key: "pick-day", Answer: "B: Friday"}); err != nil {
		t.Fatal(err)
	}
	edit = last("editMessageText")
	if !strings.Contains(edit["text"].(string), "Answered on the board: B: Friday") || fmt.Sprint(edit["message_id"]) != dayMsg {
		t.Fatalf("edit %v: want the board's answer on message %s", edit, dayMsg)
	}
	n := count("editMessageText")
	a.sendEvent(ad, owner, event{At: 2200, Kind: "card-close", Key: "pick-day", Answer: "B: Friday"}) // a repeat
	if count("editMessageText") != n {
		t.Fatal("a repeated close edited the message again")
	}

	// A text reply answers the card and removes the buttons.
	a.sendEvent(ad, owner, card("reply-card", 3000, "Ship it?", yes, no))
	replyMsg := a.cards()["reply-card"].Message
	ingest(fmt.Sprintf(`{"update_id":50,"message":{"message_id":51,"text":"yes, ship","reply_to_message":{"message_id":%s},"from":{"id":42},"chat":{"id":42,"type":"private"}}}`, replyMsg))
	if c := a.cards()["reply-card"]; c.State != "answered" || !strings.Contains(last("editMessageText")["text"].(string), "Answered: yes, ship") {
		t.Fatalf("card %+v: want the text reply to close it", c)
	}

	// A changed card edits its message in place; a card closed without an answer says so.
	a.sendEvent(ad, owner, card("change-me", 4000, "Which one?", yes, no))
	changeMsg := a.cards()["change-me"].Message
	sends := count("sendMessage")
	a.sendEvent(ad, owner, card("change-me", 4100, "Which one, A or B?", cardOption{"a", "A"}, cardOption{"b", "B"}, cardOption{"c", "C"}))
	edit = last("editMessageText")
	labels, data = buttons(edit)
	if count("sendMessage") != sends || fmt.Sprint(edit["message_id"]) != changeMsg || len(labels) != 3 || !strings.Contains(edit["text"].(string), "A or B?") {
		t.Fatalf("edit %v, sends %d: want the same message with three buttons", edit, count("sendMessage"))
	}
	ingest(tap(8, 42, 42, atoi(changeMsg), data[2]))
	if !strings.Contains(published[len(published)-1], `"answer":"c"`) {
		t.Fatalf("published %v: want the new option answered", published)
	}
	a.sendEvent(ad, owner, card("drop-me", 5000, "Rename it?", yes, no))
	dropMsg := a.cards()["drop-me"].Message
	a.sendEvent(ad, owner, event{At: 5100, Kind: "card-close", Key: "drop-me", Text: "No longer needed."})
	if !strings.Contains(last("editMessageText")["text"].(string), "No longer needed.") {
		t.Fatalf("edit %v: want the withdrawal shown", last("editMessageText"))
	}
	before := len(published)
	ingest(tap(9, 42, 42, atoi(dropMsg), "c:"+cardHash("drop-me")+":0"))
	if got := last("answerCallbackQuery")["text"]; got != "This card is closed." || len(published) != before {
		t.Fatalf("tap on a withdrawn card: toast %v, published %d: want it refused", got, len(published)-before)
	}

	// An edit the chat refuses is tried again on the next pass and only once it works.
	failEdits = 1
	a.sendEvent(ad, owner, card("retry-me", 6000, "Retry?", yes, no))
	retryMsg := a.cards()["retry-me"].Message
	if err := a.sendEvent(ad, owner, event{At: 6100, Kind: "card-close", Key: "retry-me", Answer: "Yes"}); err == nil {
		t.Fatal("a failed edit was reported as done")
	}
	n = count("editMessageText")
	a.syncCards(ad)
	if count("editMessageText") != n+1 || !strings.Contains(last("editMessageText")["text"].(string), "Answered on the board") || fmt.Sprint(last("editMessageText")["message_id"]) != retryMsg {
		t.Fatalf("sync: edits %d, last %v: want the edit repeated", count("editMessageText")-n, last("editMessageText"))
	}
	a.syncCards(ad)
	if count("editMessageText") != n+1 {
		t.Fatal("a finished edit was repeated")
	}
	if b, _ := os.ReadFile(a.cardsFile()); strings.Contains(string(b), tok) {
		t.Fatal("the bot token reached the card map")
	}
}

func atoi(s string) int { n, _ := strconv.Atoi(s); return n }

// `jg-bus publish card --option value=label` puts the options in the event, and `card-close --answer`
// carries the board's answer; an empty option is refused, a bare one is its own label.
func TestPublishCardOptions(t *testing.T) {
	l := newChatLab(t, true)
	if code := l.a.publish([]string{"card", "k1", "Merge?", "--option", "yes=Yes", "--option", "no=No", "--link", "https://x.test/c"}); code != 0 {
		t.Fatalf("publish exited %d", code)
	}
	l.a.publish([]string{"card-close", "k1", "answered", "--answer", "Yes"})
	rec := readFileString(l.a.record)
	if !strings.Contains(rec, `"options":[{"value":"yes","label":"Yes"},{"value":"no","label":"No"}]`) || !strings.Contains(rec, `"kind":"card-close","key":"k1"`) || !strings.Contains(rec, `"answer":"Yes"`) {
		t.Fatalf("record %q: want the options and the board's answer", rec)
	}
	if code := l.a.publish([]string{"card", "k2", "Q?", "--option", ""}); code == 0 {
		t.Fatal("an empty option was accepted")
	}
	l.a.publish([]string{"card", "k3", "Q?", "--option", "Key it"})
	if rec := readFileString(l.a.record); !strings.Contains(rec, `"options":[{"value":"Key it","label":"Key it"}]`) {
		t.Fatalf("record %q: a bare option is its own label", rec)
	}
}
