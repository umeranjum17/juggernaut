package main

// gateway_receipt.go is the gateway's small talk with the owner: a reaction on every message it
// files as a note, so the owner sees it arrived, and `/status`, answered by the gateway itself
// without waking Overwatch or filing a note.

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// receiptEmoji is the reaction that says "filed". Telegram only takes emoji from its own list.
const receiptEmoji = "👀"

// React is setMessageReaction: it marks one message as received.
func (t *telegram) React(ctx context.Context, chat, message string) error {
	body, _ := json.Marshal(map[string]any{"chat_id": json.Number(chat), "message_id": json.Number(message),
		"reaction": []map[string]string{{"type": "emoji", "emoji": receiptEmoji}}})
	_, err := t.call(ctx, "setMessageReaction", 10*time.Second, func() (io.Reader, string) { return bytes.NewReader(body), "application/json" })
	return err
}

// isStatusCommand is true for a message that is only `/status`, with or without the `@botname`
// Telegram adds when the command is picked from a menu.
func isStatusCommand(in Inbound) bool {
	f := strings.Fields(in.Text)
	return len(f) == 1 && len(in.Media) == 0 && (f[0] == "/status" || strings.HasPrefix(f[0], "/status@"))
}

// statusLine is the first line of `gateway status`, and the head of the chat's /status answer.
func (a *app) statusLine(file string) string {
	paired := "not paired; run `jg-bus gateway pair` with the service stopped"
	if a.cfgOr("telegram-allow-user", "") != "" {
		paired = "paired"
	}
	return fmt.Sprintf("gateway: telegram, token file %s, owner %s, %d answers sent", file, paired, countLines(filepath.Join(a.state, "captain-chat", "sent.jsonl")))
}

// answerStatus replies to /status from the gateway's own state. The message reached the bot, so the
// bot works; no token is read and no note, event or wake follows. A failed reply is logged only.
func (a *app) answerStatus(ad Adapter, in Inbound) {
	text := a.statusLine(filepath.Base(a.tokenPath())) + "\nbot: answering this message now"
	if asks := a.ownerAsks(); asks != "" {
		text += "\n\n" + asks
	}
	if _, err := ad.Send(context.Background(), Outbound{Chat: in.Chat, ReplyTo: in.Message, Text: text}); err != nil {
		a.noteFailure("gateway status", err.Error())
	}
}

// ownerAsks is the owner's own asks, in his words, from bin/jg-owner-asks.sh (no model, no network).
// A script that is missing, slow or failing adds nothing: /status still answers from the gateway.
func (a *app) ownerAsks() string {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, filepath.Join(a.root, "bin", "jg-owner-asks.sh"))
	cmd.Env = append(os.Environ(), "JG_HOME="+a.home)
	out, err := cmd.Output()
	if err != nil {
		a.noteFailure("gateway status asks", err.Error())
		return ""
	}
	return strings.TrimSpace(string(out))
}
