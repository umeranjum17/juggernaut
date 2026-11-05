package main

// gateway_events.go is the gateway's outbound side. Card, outcome, alert and digest events on
// CAPTAIN reach the owner's private chat through the durable consumer `captain-gateway`. When the
// bus refuses a publish, `emit` sends the same event through the same adapter in-process. A card
// shown in the chat is remembered in sent.jsonl, so the owner's reply to it can answer the card.

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// chatKinds are the events the owner hears in the chat (summary is Main's own turn summary, bin/jg-captain-say.sh); probes and the chat's own events stay off it.
var chatKinds = map[string]bool{"card": true, "card-close": true, "outcome": true, "alert": true, "digest": true, "summary": true}

// realHome says whether the owner may hear from a home: the gateway's own home, or a member of the
// machine registry that is not a throw-away location. A test home never joins that registry (see
// registerHome), so the card a test suite publishes into the shared bus is refused here rather than
// reaching the owner's chat. An event with no home is from a publisher older than the field.
func (a *app) realHome(home string) bool {
	if home == "" {
		return true
	}
	home = resolveHome(home)
	if home == resolveHome(a.home) {
		return true
	}
	state, member := a.registeredStates()[home]
	if !member {
		return false
	}
	_, labHomeDir := labHome(home, a.root)
	_, labStateDir := labHome(state, a.root)
	return !labHomeDir && !labStateDir
}

// retryWindow is how long a failing send is tried again, with a doubling wait, before it is named undelivered.
var retryWindow = 10 * time.Minute

// chatTarget is the adapter and the owner's private chat. The adapter is nil, with no error, when the
// channel is not live, there is no token file or no owner is paired: the chat is optional and silent.
func (a *app) chatTarget() (*telegram, string, error) {
	token, _, present, err := a.readTokenFile()
	owner := strings.FieldsFunc(a.cfgOr("telegram-allow-user", ""), func(r rune) bool { return r == ',' || r == ' ' })
	if !present || len(owner) == 0 || a.channelMode() != "live" || a.cfgOr("gateway-adapters", "telegram") != "telegram" {
		return nil, "", nil
	}
	return &telegram{base: strings.TrimRight(a.cfgOr("telegram-api-url", "https://api.telegram.org"), "/"), token: token, sleep: time.Sleep}, owner[0], err
}

// sendEvent sends one event to the owner, one message per part. Each part is recorded in sent.jsonl as
// it goes, so a repeat of the event (a redelivery) sends only what is still missing.
func (a *app) sendEvent(ad Adapter, owner string, ev event) error {
	text := strings.TrimSpace(ev.Text + "\n" + ev.Link)
	if ev.Kind == "card" {
		text += "\n\nReply to this message to answer."
	}
	dir := filepath.Join(a.state, "captain-chat")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	switch {
	case ev.Kind == "card-close":
		return a.closeCard(ad, ev)
	case ev.Kind == "card" && len(ev.Options) > 0:
		return a.sendCard(ad, owner, ev)
	}
	done := map[string]bool{}
	readLines(filepath.Join(dir, "sent.jsonl"), func(v map[string]string) { done[v["key"]] = true })
	for i, part := range chunks(text, ad.Limit()) {
		key := fmt.Sprintf("ev:%s:%s:%d#%d", ev.Kind, ev.Key, ev.At, i)
		if done[key] {
			continue
		}
		id, err := ad.Send(context.Background(), Outbound{Chat: owner, Text: part})
		if err != nil {
			return err
		}
		line := map[string]string{"key": key, "chat": owner, "message": id}
		if ev.Kind == "card" {
			line["card"] = ev.Key
		}
		if err := appendLine(filepath.Join(dir, "sent.jsonl"), toJSON(line)); err != nil {
			return err
		}
	}
	return nil
}

// sendToChat is the in-process fallback: one try, because the emitter's caller waits for it.
func (a *app) sendToChat(ev event) error {
	ad, owner, err := a.chatTarget()
	switch {
	case !chatKinds[ev.Kind]:
		err = errors.New("the chat does not carry " + ev.Kind + " events")
	case err == nil && ad == nil:
		err = errors.New("no chat is set up")
	case err == nil:
		if err = a.sendEvent(ad, owner, ev); err != nil {
			err = errors.New(redact(err.Error(), ad.token))
		}
	}
	return err
}

// deliverEvent is the consumer's handler: a failing send is tried again with a doubling wait until the
// window ends, then the event is named in the undelivered record. A call that can never work (a
// blocked bot, a bad request) is not tried again.
func (a *app) deliverEvent(ad *telegram, owner string, body []byte) (err error) {
	var ev event
	if json.Unmarshal(eventBody(body), &ev) != nil || !chatKinds[ev.Kind] {
		return nil
	}
	if !a.realHome(ev.Home) { // named once in the log, then dropped: sending it again could not change the answer
		a.noteFailure("gateway "+ev.Kind+" not sent", "the "+ev.Key+" event comes from "+ev.Home+", which is not a registered home")
		return nil
	}
	for wait, spent := 2*time.Second, time.Duration(0); ; wait = min(2*wait, time.Minute) {
		if err = a.sendEvent(ad, owner, ev); err == nil {
			return nil
		}
		var se *sendError
		if errors.As(err, &se) && (se.code == 400 || se.code == 403) || spent+wait > retryWindow {
			a.noteUndelivered(ad.Name(), redact(err.Error(), ad.token), string(body))
			return err
		}
		ad.sleep(wait)
		spent += wait
	}
}

// gatewayPart is the durable consumer `captain-gateway` on CAPTAIN. It starts at new events, so a first
// start does not replay a week of old cards into the chat.
func (a *app) gatewayPart(ad *telegram, owner string) *part {
	p := a.routerPart()
	p.name, p.filter, p.deliver = "captain-gateway", a.cfgOr("subject-prefix", "")+".>", "new"
	p.handle = func(body []byte) error { return a.deliverEvent(ad, owner, body) }
	return p
}

// serveGatewayEvents runs the consumer for as long as the gateway runs; a failure is tried again.
func (a *app) serveGatewayEvents(ad *telegram, owner string) {
	for {
		a.serveConsumer(a.gatewayPart(ad, owner))
		time.Sleep(5 * time.Second)
	}
}
