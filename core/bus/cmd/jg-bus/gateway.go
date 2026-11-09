package main

// gateway.go owns `jg-bus gateway`, the captain's chat. Slice 1: Telegram text in. An
// allowlisted private message becomes one inbox note (`jg-inbox.sh note --request-id`) and one
// `inbound` event; the core owns access, records and the note, an adapter only speaks its platform.

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"os/exec"
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
	Limit() int        // the longest text one message may hold
	FetchLimit() int64 // the largest file Fetch can download
	Receive(ctx context.Context, cursor string) ([]Inbound, string, error)
	Fetch(ctx context.Context, m MediaRef, w io.Writer) (int64, error)
	Send(ctx context.Context, out Outbound) (string, error)
	Answer(ctx context.Context, callback, text string) error // end a button tap's spinner, with an optional line shown to the tapper
	Edit(ctx context.Context, chat, message, text string, buttons []Button) error
	Out() OutLimits                                        // what Send can carry: file, picture, caption and album sizes
	React(ctx context.Context, chat, message string) error // mark a message as received
	Typing(ctx context.Context, chat string) error         // show that an answer is being written
}

// Inbound is one platform update. A non-message update has no sender, so the access check drops it.
type Inbound struct {
	UpdateID, Chat, From, Message, Text string
	ReplyTo                             string // the message this one answers, if any
	Private, FromBot                    bool
	Media                               []MediaRef
	Callback, Data                      string // a button tap: the query to answer and the button's opaque data
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
	q := url.Values{"timeout": {strconv.Itoa(int(t.wait.Seconds()))}, "allowed_updates": {`["message","callback_query"]`}}
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
				MessageID int64 `json:"message_id"`
				ReplyTo   *struct {
					MessageID int64 `json:"message_id"`
				} `json:"reply_to_message"`
				Text    string `json:"text"`
				Caption string `json:"caption"`
				tgMedia
				From struct {
					ID    int64 `json:"id"`
					IsBot bool  `json:"is_bot"`
				} `json:"from"`
				Chat struct {
					ID   int64  `json:"id"`
					Type string `json:"type"`
				} `json:"chat"`
			} `json:"message"`
			Callback *struct {
				ID   string `json:"id"`
				Data string `json:"data"`
				From struct {
					ID    int64 `json:"id"`
					IsBot bool  `json:"is_bot"`
				} `json:"from"`
				Message *struct {
					MessageID int64 `json:"message_id"`
					Chat      struct {
						ID   int64  `json:"id"`
						Type string `json:"type"`
					} `json:"chat"`
				} `json:"message"`
			} `json:"callback_query"`
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
			if in.Text == "" {
				in.Text = m.Caption
			}
			in.Media = m.refs()
			if m.ReplyTo != nil {
				in.ReplyTo = strconv.FormatInt(m.ReplyTo.MessageID, 10)
			}
		}
		if c := u.Callback; c != nil {
			in.Callback, in.Data, in.From, in.FromBot = c.ID, c.Data, strconv.FormatInt(c.From.ID, 10), c.From.IsBot
			if c.Message != nil { // a tap on a message the bot cannot name has no chat, so it is dropped
				in.Chat, in.Message, in.Private = strconv.FormatInt(c.Message.Chat.ID, 10), strconv.FormatInt(c.Message.MessageID, 10), c.Message.Chat.Type == "private"
			}
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
		if in.Callback != "" {
			a.answerTap(ad, in, "") // the tapper's spinner ends; nothing else shows
		}
		return nil
	}
	if strings.HasPrefix(in.Data, "c:") { // a tap on a card's option answers the card
		return a.tapCard(ad, in)
	}
	if in.Callback != "" { // a button tap answers an option set, not a message
		return a.pick(ad, in)
	}
	if isStatusCommand(in) { // the gateway answers this itself: no card, no note, no wake
		a.answerStatus(ad, in)
		return nil
	}
	if card := a.cardAnswered(in); card != "" { // the owner answered a card in the chat: the board takes it, not the inbox
		a.emitReply(card, in.Text, "")
		a.closeAnswered(ad, card, in.Text) // the card's buttons go, as for a tap
		return nil
	}
	head := fmt.Sprintf("[chat %s %s:%s]", ad.Name(), in.Chat, in.Message)
	reacted := false
	react := func() { // the note is filed or about to be; a missing reaction costs nothing
		if !reacted {
			reacted = true
			if err := ad.React(context.Background(), in.Chat, in.Message); err != nil {
				a.noteFailure("gateway reaction", err.Error())
			}
		}
	}
	files, stored := a.fetchMedia(ad, in, react)
	if in.Text == "" && len(files) == 0 {
		in.Text = "(no text: this message has nothing the gateway can read yet)"
	}
	id := fmt.Sprintf("tg-%s-%s", in.Chat, in.Message)
	lines := append([]string{head}, files...)
	if in.Text != "" {
		lines = slices.Insert(lines, 1, in.Text)
	}
	out, err := a.inbox(strings.Join(lines, "\n")+"\n", "note", "--request-id", id, "--json", "-")
	var res struct{ Outcome, ID string }
	if err != nil || json.Unmarshal(out, &res) != nil {
		return fmt.Errorf("jg-inbox note %s was not filed: %v", id, err)
	}
	// Where the answer goes. Written for a replay too, so a crash between the note and this line heals.
	if err := appendLine(filepath.Join(a.state, "captain-chat", "inbound.jsonl"), toJSON(map[string]string{"adapter": ad.Name(), "note": res.ID, "chat": in.Chat, "message": in.Message})); err != nil {
		return err
	}
	a.recordInboundLegs(res.ID, in, stored)
	react()
	if res.Outcome == "created" { // a replay already announced its event
		a.typing.begin(in.Chat, res.ID)
		a.emit("inbound", id, head, "", stored)
		a.refuseLarge(ad, in)
	}
	// Counted last and for a replay too, so a failure here costs the owner nothing: the note, its
	// event and the reaction are done, and the retry only adds the missing ledger row.
	return a.recordKPI(res.ID, in.Text)
}

// recordKPI counts the owner's note as a captain message in the Overwatch KPI ledger, exactly as
// bin/jg-chat.sh counts one typed at the board. The note id makes it one row per note: a replay or a
// retry finds the row and adds none, and a home whose config/overwatch-kpi reads off records nothing.
func (a *app) recordKPI(note, text string) error {
	if strings.TrimSpace(text) == "" {
		text = "(chat note with no text)"
	}
	cmd := exec.Command(filepath.Join(a.root, "bin", "jg-overwatch-kpi.sh"), "record", "--id", note, "--", text)
	cmd.Env = append(os.Environ(), "JG_HOME="+a.home, "JG_STATE_OVERRIDE="+a.state, "JG_DATA_OVERRIDE="+a.data)
	if out, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("jg-overwatch-kpi did not record note %s: %v: %s", note, err, strings.TrimSpace(string(out)))
	}
	return nil
}

// recordInboundLegs notes which legs of the round trip this filed message proves: a text-only
// message is the text leg, and each stored picture or file is its own leg.
func (a *app) recordInboundLegs(note string, in Inbound, stored []mediaFile) {
	if len(in.Media) == 0 && in.Text != "" {
		a.recordLeg("in-text", note)
	}
	for _, f := range stored {
		if f.kind == "image" || f.kind == "file" {
			a.recordLeg("in-"+f.kind, note)
		}
	}
}

// pollOnce files every update from the committed cursor, then commits the cursor: a crash replays
// the batch and the request id turns each replay into the first note.
func (a *app) pollOnce(ad Adapter, allow []string) error {
	dir := filepath.Join(a.state, "captain-chat")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	a.pruneMedia()
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

// tokenPath is where this home keeps its bot token.
func (a *app) tokenPath() string {
	file := a.cfgOr("telegram-token-file", "config/captain-chat/telegram.token")
	if !filepath.IsAbs(file) {
		file = filepath.Join(a.home, file)
	}
	return file
}

// readTokenFile is the one reader of a bot token file. A missing file is "not present", not an
// error (the channel is optional); a file that group or others can read is refused.
func (a *app) readTokenFile() (token, file string, present bool, err error) {
	file = a.tokenPath()
	info, statErr := os.Stat(file)
	if statErr != nil {
		return "", file, false, nil
	}
	if info.Mode().Perm()&0o077 != 0 {
		return "", file, true, fmt.Errorf("%s is readable by group or others; run chmod 600 on it", file)
	}
	raw, _ := os.ReadFile(file)
	if token = strings.TrimSpace(string(raw)); token == "" {
		return "", file, true, fmt.Errorf("%s holds no token", file)
	}
	return token, file, true, nil
}

// gateway receives chat for the captain: `--once` is one pass, `serve` polls until stopped, `pair`
// records the owner's id, `setup` is the guided first-time path, `status` reports, `enabled` is the service wiring's silent question,
// `push <text>` sends one unprompted message to the owner (gateway_push.go).
// With no token file every subcommand but `status` does nothing.
func (a *app) gateway(args []string) int {
	if len(args) == 2 && args[0] == "status" && args[1] == "--row" {
		return a.gatewayRow()
	}
	if len(args) > 0 && args[0] == "push" {
		return a.gatewayPush(args[1:])
	}
	if len(args) != 1 || !slices.Contains([]string{"--once", "serve", "pair", "status", "enabled", "setup"}, args[0]) {
		return die("gateway needs --once, serve, pair, status [--row], enabled or setup")
	}
	if args[0] == "setup" { // opt-in only: nothing but the user's own command reaches it
		return a.setup(os.Stdin)
	}
	once := args[0] == "--once"
	token, file, present, err := a.readTokenFile()
	wanted := a.channelMode() == "live" && present && a.cfgOr("gateway-adapters", "telegram") == "telegram"
	if args[0] == "enabled" {
		if wanted {
			return 0
		}
		return 1
	}
	if args[0] == "status" {
		return a.gatewayStatus(token, file, present, err)
	}
	if !wanted {
		return 0
	}
	if err != nil {
		return die("gateway: %v", err)
	}
	allow := strings.FieldsFunc(a.cfgOr("telegram-allow-user", ""), func(r rune) bool { return r == ',' || r == ' ' })
	ad := &telegram{base: strings.TrimRight(a.cfgOr("telegram-api-url", "https://api.telegram.org"), "/"), token: token, wait: 30 * time.Second, sleep: time.Sleep}
	if args[0] == "pair" {
		return a.pair(ad)
	}
	if once {
		ad.wait = 0
	}
	if !once {
		a.typing = a.typerFor(ad)
		a.typing.stopOnSignal()
		go a.typing.run()
		if len(allow) > 0 {
			go a.serveGatewayEvents(ad, allow[0]) // cards, outcomes, alerts and digests out to the chat
		}
		go func() { // replies are not held behind a 30 s long poll
			for {
				if err := a.followReplies(ad); err != nil {
					a.noteFailure("gateway replies", redact(err.Error(), token))
				}
				time.Sleep(2 * time.Second)
			}
		}()
	}
	if !once {
		a.beat(ad) // the service is up before its first poll returns
	}
	for {
		err := a.pollOnce(ad, allow)
		if !once {
			a.recordPoll(ad, err, token)
		}
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

// isChatEvent is a chat event's subject: it stays on the stream and is never named undelivered.
func isChatEvent(subject string) bool {
	return strings.HasSuffix(subject, ".inbound") || strings.HasSuffix(subject, ".chat")
}

// cardAnswered is the card key when the update is a text reply to a card the chat showed, and ""
// otherwise (the update then becomes a note).
func (a *app) cardAnswered(in Inbound) (card string) {
	if in.ReplyTo == "" || in.Text == "" || len(in.Media) > 0 {
		return ""
	}
	readLines(filepath.Join(a.state, "captain-chat", "sent.jsonl"), func(v map[string]string) {
		if v["card"] != "" && v["chat"] == in.Chat && v["message"] == in.ReplyTo {
			card = v["card"]
		}
	})
	return card
}
