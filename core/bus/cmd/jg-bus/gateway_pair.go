package main

// gateway_pair.go owns `jg-bus gateway pair` and `gateway status`. Pairing records the owner's
// Telegram id from the first private message that carries a one-time code, so no id is ever typed
// or shipped; status reads the setup back without sending anything.

import (
	"context"
	"crypto/rand"
	"encoding/json"
	"fmt"
	"math/big"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// pairCode is the one-time code; a test replaces it.
var pairCode = func() string {
	n, _ := rand.Int(rand.Reader, big.NewInt(1000000))
	return fmt.Sprintf("%06d", n.Int64())
}

// Probe is getMe: the bot the token belongs to, or why it does not work.
func (t *telegram) Probe(ctx context.Context) (string, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, t.base+"/bot"+t.token+"/getMe", nil)
	var resp *http.Response
	if err == nil {
		resp, err = (&http.Client{Timeout: 15 * time.Second}).Do(req)
	}
	if err != nil {
		return "", fmt.Errorf("%s", redact(err.Error(), t.token))
	}
	defer resp.Body.Close()
	var res struct {
		OK     bool `json:"ok"`
		Result struct {
			Username string `json:"username"`
		} `json:"result"`
	}
	if json.NewDecoder(resp.Body).Decode(&res) != nil || !res.OK {
		return "", fmt.Errorf("getMe answered HTTP %d", resp.StatusCode)
	}
	return "@" + res.Result.Username, nil
}

// setConfigKey writes `set <key> <value>` into a config file: the key's line is replaced, or one is
// appended. Everything else in the file stays as it was.
func setConfigKey(path, key, value string) error {
	raw, _ := os.ReadFile(path)
	lines, done := strings.Split(strings.TrimRight(string(raw), "\n"), "\n"), false
	for i, l := range lines {
		if m := setLine.FindStringSubmatch(l); m != nil && m[1] == key {
			lines[i], done = "set "+key+" "+value, true
		}
	}
	if !done {
		lines = append(lines, "set "+key+" "+value)
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	return os.WriteFile(path, []byte(strings.TrimLeft(strings.Join(lines, "\n"), "\n")+"\n"), 0o600)
}

// pair waits up to ten minutes for a private message from a person whose text is the code, sets
// telegram-allow-user to their id, and moves the offset past that update. Run it with the service
// stopped: a second reader of one bot gets HTTP 409.
func (a *app) pair(ad *telegram) int {
	code := pairCode()
	say("Send this code to your bot in a private chat within 10 minutes: %s", code)
	file := filepath.Join(a.state, "captain-chat", ad.Name()+".offset")
	prev, _ := os.ReadFile(file)
	cursor := strings.TrimSpace(string(prev))
	for deadline := time.Now().Add(10 * time.Minute); time.Now().Before(deadline); {
		items, next, err := ad.Receive(context.Background(), cursor)
		if err != nil {
			return die("gateway pair: %s (is the gateway service still running? stop it first)", redact(err.Error(), ad.token))
		}
		for _, in := range items {
			if !in.Private || in.FromBot || in.Chat != in.From || strings.TrimSpace(in.Text) != code {
				continue
			}
			if err := setConfigKey(filepath.Join(a.home, "config", "captain-channel"), "telegram-allow-user", in.From); err != nil {
				return die("gateway pair: cannot record the owner: %v", err)
			}
			_ = os.MkdirAll(filepath.Dir(file), 0o700)
			id, _ := strconv.ParseInt(in.UpdateID, 10, 64)
			if err := os.WriteFile(file, []byte(strconv.FormatInt(id+1, 10)+"\n"), 0o600); err != nil {
				return die("gateway pair: cannot move the update offset: %v", err)
			}
			_, _ = ad.Send(context.Background(), Outbound{Chat: in.Chat, ReplyTo: in.Message, Text: "Paired. This chat now reaches Overwatch."})
			say("paired: telegram-allow-user is set in config/captain-channel; start the gateway service")
			return 0
		}
		cursor = next
	}
	return die("gateway pair: no message with the code arrived in 10 minutes")
}

// gatewayStatus reports the setup and asks the Bot API who the token is, without sending a message.
// It exits non-zero only when a token exists and does not work.
func (a *app) gatewayStatus(token, file string, present bool, tokErr error) int {
	if !present || a.channelMode() != "live" {
		say("gateway: off (no token file at %s, or channel mode is not live)", file)
		return 0
	}
	paired := "not paired; run `jg-bus gateway pair` with the service stopped"
	if a.cfgOr("telegram-allow-user", "") != "" {
		paired = "paired"
	}
	say("gateway: telegram, token file %s, owner %s, %d answers sent", file, paired, countLines(filepath.Join(a.state, "captain-chat", "sent.jsonl")))
	if tokErr != nil {
		say("bot: %v", tokErr)
		return 1
	}
	who, err := (&telegram{base: strings.TrimRight(a.cfgOr("telegram-api-url", "https://api.telegram.org"), "/"), token: token}).Probe(context.Background())
	if err != nil {
		say("bot: getMe failed: %v", err)
		return 1
	}
	say("bot: %s answered getMe", who)
	return 0
}
