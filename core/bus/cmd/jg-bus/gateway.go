package main

// gateway.go owns `jg-bus gateway`, the captain's chat. Slice 1: Telegram text in. An
// allowlisted private message becomes one inbox note (`jg-inbox.sh note --request-id`) and one
// `inbound` event; the core owns access, records and the note, an adapter only speaks its platform.

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"time"
)

// Adapter is one chat platform. Receive long-polls from a cursor and returns what arrived and
// the cursor after it; the caller commits that cursor only once every item is filed.
type Adapter interface {
	Name() string
	Limit() int // the longest text one message may hold
	Receive(ctx context.Context, cursor string) ([]Inbound, string, error)
	Send(ctx context.Context, out Outbound) (string, error)
}

// Inbound is one platform update. A non-message update has no sender, so the access check drops it.
type Inbound struct {
	UpdateID, Chat, From, Message, Text string
	Private, FromBot                    bool
}

// redact hides the bot token: the Bot API puts it in the URL and a Go *url.Error prints the URL,
// so every error, log line and record passes here.
func redact(s, token string) string { return strings.ReplaceAll(s, token, "<token>") }

type telegram struct {
	base, token string
	wait        time.Duration
	sleep       func(time.Duration)
}

func (t *telegram) Name() string { return "telegram" }

// Receive is getUpdates over net/http, asking for messages only.
func (t *telegram) Receive(ctx context.Context, cursor string) ([]Inbound, string, error) {
	q := url.Values{"timeout": {strconv.Itoa(int(t.wait.Seconds()))}, "allowed_updates": {`["message"]`}}
	if cursor != "" {
		q.Set("offset", cursor)
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, t.base+"/bot"+t.token+"/getUpdates?"+q.Encode(), nil)
	var resp *http.Response
	if err == nil {
		resp, err = (&http.Client{Timeout: t.wait + 15*time.Second}).Do(req)
	}
	if err != nil {
		return nil, cursor, errors.New(redact(err.Error(), t.token))
	}
	defer resp.Body.Close()
	var body struct {
		OK     bool `json:"ok"`
		Result []struct {
			UpdateID int64 `json:"update_id"`
			Message  *struct {
				MessageID int64  `json:"message_id"`
				Text      string `json:"text"`
				From      struct {
					ID    int64 `json:"id"`
					IsBot bool  `json:"is_bot"`
				} `json:"from"`
				Chat struct {
					ID   int64  `json:"id"`
					Type string `json:"type"`
				} `json:"chat"`
			} `json:"message"`
		} `json:"result"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil || !body.OK {
		return nil, cursor, fmt.Errorf("getUpdates answered HTTP %d", resp.StatusCode)
	}
	var out []Inbound
	for _, u := range body.Result {
		in := Inbound{UpdateID: strconv.FormatInt(u.UpdateID, 10)}
		if m := u.Message; m != nil {
			in.Chat, in.From, in.FromBot = strconv.FormatInt(m.Chat.ID, 10), strconv.FormatInt(m.From.ID, 10), m.From.IsBot
			in.Message, in.Text, in.Private = strconv.FormatInt(m.MessageID, 10), m.Text, m.Chat.Type == "private"
		}
		out, cursor = append(out, in), strconv.FormatInt(u.UpdateID+1, 10)
	}
	return out, cursor, nil
}

// ingest files one update. Anyone but the allowlisted owner in a private chat of their own is
// dropped silently and counted by time, update id and sender, never by text, so the bot does not
// show it is live. A note that cannot be filed is the error: the cursor stays, and the request
// id makes the retry safe.
func (a *app) ingest(ad Adapter, allow []string, in Inbound) error {
	if !slices.Contains(allow, in.From) || !in.Private || in.Chat != in.From || in.FromBot {
		appendQuiet(filepath.Join(a.state, "captain-chat", "dropped.tsv"), fmt.Sprintf("%d\t%s\t%s", time.Now().Unix(), in.UpdateID, in.From))
		return nil
	}
	head := fmt.Sprintf("[chat %s %s:%s]", ad.Name(), in.Chat, in.Message)
	if in.Text == "" {
		in.Text = "(no text: this gateway receives text only so far)"
	}
	id := fmt.Sprintf("tg-%s-%s", in.Chat, in.Message)
	out, err := a.inbox(head+"\n"+in.Text+"\n", "note", "--request-id", id, "--json", "-")
	var res struct{ Outcome, ID string }
	if err != nil || json.Unmarshal(out, &res) != nil {
		return fmt.Errorf("jg-inbox note %s was not filed: %v", id, err)
	}
	// Where the answer goes. Written for a replay too, so a crash between the note and this line heals.
	if err := appendLine(filepath.Join(a.state, "captain-chat", "inbound.jsonl"), toJSON(map[string]string{"adapter": ad.Name(), "note": res.ID, "chat": in.Chat, "message": in.Message})); err != nil {
		return err
	}
	if res.Outcome == "created" { // a replay already announced its event
		a.publish([]string{"inbound", id, head})
	}
	return nil
}

// pollOnce files every update from the committed cursor, then commits the cursor: a crash replays
// the batch and the request id turns each replay into the first note.
func (a *app) pollOnce(ad Adapter, allow []string) error {
	dir := filepath.Join(a.state, "captain-chat")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	file := filepath.Join(dir, ad.Name()+".offset")
	prev, _ := os.ReadFile(file)
	items, next, err := ad.Receive(context.Background(), strings.TrimSpace(string(prev)))
	for i := 0; err == nil && i < len(items); i++ {
		err = a.ingest(ad, allow, items[i])
	}
	if err != nil || next == strings.TrimSpace(string(prev)) {
		return err
	}
	if err = os.WriteFile(file+".tmp", []byte(next+"\n"), 0o600); err == nil {
		err = os.Rename(file+".tmp", file)
	}
	return err
}

// gateway receives chat for the captain: `--once` is one pass, `serve` polls until stopped. The
// adapter, token file and owner id are keys of the captain-channel config.
func (a *app) gateway(args []string) int {
	if len(args) != 1 || (args[0] != "--once" && args[0] != "serve") {
		return die("gateway needs --once or serve")
	}
	once := args[0] == "--once"
	if mode := a.channelMode(); mode != "live" || a.cfgOr("gateway-adapters", "") == "" {
		say("gateway: nothing to receive (mode %s, gateway-adapters %q)", mode, a.cfgOr("gateway-adapters", ""))
		return 0
	}
	if a.cfgOr("gateway-adapters", "") != "telegram" {
		return die("gateway-adapters can only name telegram so far")
	}
	file := a.cfgOr("telegram-token-file", "config/captain-chat/telegram.token")
	if !filepath.IsAbs(file) {
		file = filepath.Join(a.home, file)
	}
	info, err := os.Stat(file)
	if err != nil {
		return die("gateway: no telegram token file at %s", file)
	}
	if info.Mode().Perm()&0o077 != 0 {
		return die("gateway: %s is readable by group or others; run chmod 600 on it", file)
	}
	raw, _ := os.ReadFile(file)
	token := strings.TrimSpace(string(raw))
	if token == "" {
		return die("gateway: %s holds no token", file)
	}
	allow := strings.FieldsFunc(a.cfgOr("telegram-allow-user", ""), func(r rune) bool { return r == ',' || r == ' ' })
	ad := &telegram{base: strings.TrimRight(a.cfgOr("telegram-api-url", "https://api.telegram.org"), "/"), token: token, wait: 30 * time.Second, sleep: time.Sleep}
	if once {
		ad.wait = 0
	}
	if !once {
		go func() { // replies are not held behind a 30 s long poll
			for {
				if err := a.followReplies(ad); err != nil {
					a.noteFailure("gateway replies", redact(err.Error(), token))
				}
				time.Sleep(2 * time.Second)
			}
		}()
	}
	for {
		err := a.pollOnce(ad, allow)
		if once && err == nil {
			err = a.followReplies(ad)
		}
		if err != nil {
			a.noteFailure("gateway", redact(err.Error(), token))
			if once {
				return die("gateway: %s", redact(err.Error(), token))
			}
			time.Sleep(5 * time.Second)
		}
		if once {
			return 0
		}
	}
}

// isChatEvent is a chat event's subject: it stays on the stream and is never sent to ntfy.
func isChatEvent(subject string) bool {
	return strings.HasSuffix(subject, ".inbound") || strings.HasSuffix(subject, ".chat")
}
