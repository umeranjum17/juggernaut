package main

// gateway_push.go is the gateway's unprompted message: `jg-bus gateway push <text>` sends the text
// to the owner's private chat, so a fleet report reaches the captain without a question. The owner
// is the first telegram-allow-user, and in a private chat that id is the chat id, so no id is
// shipped or typed. A home with no token file has no chat, so the command stays silent there and
// the board card stays the delivery. Every other reason a message does not leave (the channel is
// not live, no owner is paired, the Bot API refuses) is a failure: it is written to the channel
// log and the command exits 1, so a caller that needs the owner to know can tell.

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"strings"
	"time"
)

// errNoChat is not a failure: a home with no token file, or with its channel switched off on purpose,
// has no chat to push to, and the board card stays its delivery.
var errNoChat = errors.New("this home has no chat (no bot token file, or the channel is off)")

// pushOwner sends one message to the owner's private chat, or says why it did not.
func (a *app) pushOwner(text string) error {
	token, _, present, err := a.readTokenFile()
	switch {
	case !present:
		return errNoChat
	case a.channelMode() == "off":
		return errNoChat
	case a.channelMode() != "live":
		return fmt.Errorf("the channel mode is %q, not live", a.channelMode())
	case a.cfgOr("gateway-adapters", "telegram") != "telegram":
		return fmt.Errorf("the gateway adapters are %q, not telegram", a.cfgOr("gateway-adapters", "telegram"))
	case strings.TrimSpace(text) == "":
		return errors.New("no text to send")
	case err != nil:
		return err
	}
	owner := strings.FieldsFunc(a.cfgOr("telegram-allow-user", ""), func(r rune) bool { return r == ',' || r == ' ' })
	if len(owner) == 0 {
		return errors.New("no owner is paired (telegram-allow-user is empty)")
	}
	ad := &telegram{base: strings.TrimRight(a.cfgOr("telegram-api-url", "https://api.telegram.org"), "/"), token: token, wait: 0, sleep: time.Sleep}
	for _, part := range chunks(text, ad.Limit()) {
		if _, err := ad.Send(context.Background(), Outbound{Chat: owner[0], Text: part}); err != nil {
			return errors.New(redact(err.Error(), token))
		}
	}
	return nil
}

func (a *app) gatewayPush(args []string) int {
	text := strings.TrimSpace(strings.Join(args, " "))
	if len(args) == 0 {
		raw, _ := io.ReadAll(os.Stdin)
		text = strings.TrimSpace(string(raw))
	}
	err := a.pushOwner(text)
	switch {
	case err == nil, errors.Is(err, errNoChat):
		return 0
	case text == "":
		return 0
	}
	a.noteFailure("gateway push", err.Error())
	say("jg-bus: gateway push: %v", err)
	return 1
}
