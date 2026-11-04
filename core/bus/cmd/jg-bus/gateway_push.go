package main

// gateway_push.go is the gateway's unprompted message: `jg-bus gateway push <text>` sends the text
// to the owner's private chat, so a fleet report reaches the captain without a question. The owner
// is the first telegram-allow-user, and in a private chat that id is the chat id, so no id is
// shipped or typed. With no token file, a channel that is not live or no paired owner it does
// nothing and says nothing: the board card stays the delivery.

import (
	"context"
	"io"
	"os"
	"strings"
	"time"
)

func (a *app) gatewayPush(args []string) int {
	text := strings.TrimSpace(strings.Join(args, " "))
	if len(args) == 0 {
		raw, _ := io.ReadAll(os.Stdin)
		text = strings.TrimSpace(string(raw))
	}
	token, _, present, err := a.readTokenFile()
	if !present || a.channelMode() != "live" || a.cfgOr("gateway-adapters", "telegram") != "telegram" || text == "" {
		return 0
	}
	if err != nil {
		return die("gateway push: %v", err)
	}
	owner := strings.FieldsFunc(a.cfgOr("telegram-allow-user", ""), func(r rune) bool { return r == ',' || r == ' ' })
	if len(owner) == 0 {
		return 0
	}
	ad := &telegram{base: strings.TrimRight(a.cfgOr("telegram-api-url", "https://api.telegram.org"), "/"), token: token, wait: 0, sleep: time.Sleep}
	for _, part := range chunks(text, ad.Limit()) {
		if _, err := ad.Send(context.Background(), Outbound{Chat: owner[0], Text: part}); err != nil {
			a.noteFailure("gateway push", redact(err.Error(), token))
			return die("gateway push: %s", redact(err.Error(), token))
		}
	}
	return 0
}
