package main

// gateway_options.go is how Overwatch asks the captain to choose. `jg-inbox.sh reply --option`
// records the labels; the follower sends the answer with one inline button per label. A button
// carries only an opaque `o:<set>:<n>`, and the labels live in state/captain-chat/options.jsonl.
// The owner's tap is answered at once, marks the message with the pick, and is filed as a note
// whose second line is `pick: <label> (<set>)`, so the pick returns like any captain message.

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// Button is one inline button: what the owner reads and the opaque data a tap returns.
type Button struct{ Label, Data string }

// optionSet is one choice put to the owner. Message stays empty until the platform has accepted
// the message that carries the buttons; the line that sets it repeats only Set and Message.
type optionSet struct {
	Set, Note, Chat, Message, Text string
	Labels                         []string
	Change                         bool
	At                             int64
}

// pickRecord is one filed pick; the last of a set is its current one.
type pickRecord struct {
	Set, Label, Update string
}

func keyboard(buttons []Button) map[string]any {
	rows := [][]map[string]string{}
	for _, b := range buttons {
		rows = append(rows, []map[string]string{{"text": b.Label, "callback_data": b.Data}})
	}
	return map[string]any{"inline_keyboard": rows}
}

// Answer ends the spinner on a tapped button. A line of text shows to the tapper for a moment.
func (t *telegram) Answer(ctx context.Context, callback, text string) error {
	msg := map[string]any{"callback_query_id": callback}
	if text != "" {
		msg["text"] = text
	}
	body := toJSON(msg)
	_, err := t.call(ctx, "answerCallbackQuery", 10*time.Second, func() (io.Reader, string) { return bytes.NewReader([]byte(body)), "application/json" })
	return err
}

// Edit replaces the text and the keyboard of a message the bot sent; no buttons removes the keyboard.
func (t *telegram) Edit(ctx context.Context, chat, message, text string, buttons []Button) error {
	_, err := t.textCall(ctx, "editMessageText", 10*time.Second, map[string]any{"chat_id": json.Number(chat), "message_id": json.Number(message), "reply_markup": keyboard(buttons)}, text)
	return err
}

// withOptions puts the buttons on the last text part of a reply, or adds a part for them when the
// reply has no text. The set is named for the reply's cursor, so a repeat of the reply is the same set.
func withOptions(parts []sendPart, w where, cursor, note string, labels []string, change bool) []sendPart {
	set := "s" + strings.TrimLeft(cursor, "0")
	i := -1
	for j := range parts {
		if len(parts[j].out.Files) == 0 {
			i = j
		}
	}
	if i < 0 {
		parts = append(parts, sendPart{key: cursor + "#q", out: Outbound{Chat: w.chat, ReplyTo: w.message, Text: "Choose one:"}})
		i = len(parts) - 1
	}
	for n, l := range labels {
		parts[i].out.Buttons = append(parts[i].out.Buttons, Button{l, fmt.Sprintf("o:%s:%d", set, n)})
	}
	parts[i].opts = &optionSet{Set: set, Note: note, Chat: w.chat, Text: parts[i].out.Text, Labels: labels, Change: change, At: time.Now().Unix()}
	return parts
}

func (a *app) optionsFile() string { return filepath.Join(a.state, "captain-chat", "options.jsonl") }

// storeOptions records the set before its message is sent. A repeat of the same set adds a line
// that readers merge, never a second set.
func (a *app) storeOptions(p sendPart) {
	if p.opts != nil {
		appendQuiet(a.optionsFile(), toJSON(p.opts))
	}
}

// placeOptions records which message carries the set's buttons.
func (a *app) placeOptions(p sendPart, message string) error {
	if p.opts == nil {
		return nil
	}
	return appendLine(a.optionsFile(), toJSON(optionSet{Set: p.opts.Set, Message: message}))
}

// loadSet merges the lines of one set; the first full line wins and the message comes from the
// line that names one.
func (a *app) loadSet(set string) (s optionSet, ok bool) {
	readLines(a.optionsFile(), func(v optionSet) {
		if v.Set != set {
			return
		}
		if len(v.Labels) > 0 && !ok {
			s, ok = v, true
		}
		if v.Message != "" {
			s.Message = v.Message
		}
	})
	return s, ok
}

func (a *app) picksFile() string { return filepath.Join(a.state, "captain-chat", "picks.jsonl") }

// answerTap ends a tap's spinner; a tap too old to answer costs nothing.
func (a *app) answerTap(ad Adapter, in Inbound, text string) {
	if err := ad.Answer(context.Background(), in.Callback, text); err != nil {
		a.noteFailure("gateway answer", err.Error())
	}
}

// pick handles the owner's tap. An unknown or stale set, a tap on another message, and a second tap
// on a set that cannot change are answered and dropped. The note is filed under the tap's own update
// id, so a replay after a crash is the same note.
func (a *app) pick(ad Adapter, in Inbound) error {
	f := strings.Split(in.Data, ":")
	set, n := optionSet{}, -1
	if len(f) == 3 && f[0] == "o" {
		n, _ = strconv.Atoi(f[2])
		set, _ = a.loadSet(f[1])
	}
	days, _ := strconv.Atoi(a.cfgOr("chat-option-days", "7"))
	if days <= 0 {
		days = 7
	}
	if set.Set == "" || n < 0 || n >= len(set.Labels) || set.Message == "" || set.Message != in.Message || set.Chat != in.Chat ||
		time.Since(time.Unix(set.At, 0)) > time.Duration(days)*24*time.Hour {
		a.answerTap(ad, in, "This choice is closed.")
		return nil
	}
	label, current, replay := set.Labels[n], "", false
	readLines(a.picksFile(), func(v pickRecord) {
		if v.Set == set.Set {
			current, replay = v.Label, replay || v.Update == in.UpdateID
		}
	})
	switch {
	case replay: // this very tap was already filed; only its answer and mark may have been lost
		a.answerTap(ad, in, "Picked: "+label)
		return nil
	case current == label:
		a.answerTap(ad, in, "Already picked: "+label)
		return nil
	case current != "" && !set.Change:
		a.answerTap(ad, in, "Already picked: "+current)
		return nil
	}
	a.answerTap(ad, in, "Picked: "+label)
	head := fmt.Sprintf("[chat %s %s:%s]", ad.Name(), in.Chat, in.Message)
	id := "tg-pick-" + in.UpdateID
	out, err := a.inbox(head+"\npick: "+label+" ("+set.Set+")\n", "note", "--request-id", id, "--json", "-")
	var res struct{ Outcome, ID string }
	if err != nil || json.Unmarshal(out, &res) != nil {
		return fmt.Errorf("jg-inbox note %s was not filed: %v", id, err)
	}
	if err := appendLine(filepath.Join(a.state, "captain-chat", "inbound.jsonl"), toJSON(map[string]string{"adapter": ad.Name(), "note": res.ID, "chat": in.Chat, "message": in.Message})); err != nil {
		return err
	}
	if err := appendLine(a.picksFile(), toJSON(pickRecord{set.Set, label, in.UpdateID})); err != nil {
		return err
	}
	if res.Outcome == "created" {
		a.emit("inbound", id, head, "", nil)
	}
	var buttons []Button
	if set.Change { // the owner may still change it: every button stays, the pick is marked
		for i, l := range set.Labels {
			if i == n {
				l = "✅ " + l
			}
			buttons = append(buttons, Button{l, fmt.Sprintf("o:%s:%d", set.Set, i)})
		}
	}
	if err := ad.Edit(context.Background(), in.Chat, in.Message, strings.TrimSpace(set.Text+"\n\nPicked: "+label), buttons); err != nil { // the pick is filed; a missing mark costs nothing
		a.noteFailure("gateway pick mark", err.Error())
	}
	return nil
}
