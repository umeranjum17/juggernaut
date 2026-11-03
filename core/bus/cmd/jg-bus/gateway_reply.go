package main

// gateway_reply.go is the gateway's way out. Overwatch answers a chat note with
// `jg-inbox.sh reply`; the follower reads those replies from the inbox receipts and sends each as
// a message threaded on the note's own, so jg-inbox.sh keeps its rule of no network calls.

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
	"unicode/utf16"
)

// Outbound is one message to send: ReplyTo is the platform id of the message it answers.
type Outbound struct{ Chat, ReplyTo, Text string }

// sendError carries the Bot API's own error code, so the follower can tell a call that will
// never work (a blocked bot) from one worth another try.
type sendError struct {
	code int
	msg  string
}

func (e *sendError) Error() string { return fmt.Sprintf("sendMessage answered %d: %s", e.code, e.msg) }

func (t *telegram) Limit() int { return 4096 }

// Send is sendMessage threaded on ReplyTo. A 429 waits the time Telegram names and sends the
// same call again.
func (t *telegram) Send(ctx context.Context, out Outbound) (string, error) {
	chat, to := json.Number(out.Chat), json.Number(out.ReplyTo)
	body, _ := json.Marshal(map[string]any{"chat_id": chat, "text": out.Text,
		"reply_parameters": map[string]any{"message_id": to, "allow_sending_without_reply": true}})
	for try := 0; ; try++ {
		req, _ := http.NewRequestWithContext(ctx, http.MethodPost, t.base+"/bot"+t.token+"/sendMessage", bytes.NewReader(body))
		req.Header.Set("Content-Type", "application/json")
		resp, err := (&http.Client{Timeout: 30 * time.Second}).Do(req)
		if err != nil {
			return "", errors.New(redact(err.Error(), t.token))
		}
		var res struct {
			OK          bool   `json:"ok"`
			Code        int    `json:"error_code"`
			Description string `json:"description"`
			Result      struct {
				ID int64 `json:"message_id"`
			} `json:"result"`
			Parameters struct {
				RetryAfter int `json:"retry_after"`
			} `json:"parameters"`
		}
		raw, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
		resp.Body.Close()
		if json.Unmarshal(raw, &res) != nil {
			res.Code = resp.StatusCode
		}
		switch {
		case res.OK:
			return strconv.FormatInt(res.Result.ID, 10), nil
		case res.Code == http.StatusTooManyRequests && try < 3:
			t.sleep(time.Duration(res.Parameters.RetryAfter) * time.Second)
		default:
			return "", &sendError{res.Code, redact(res.Description, t.token)}
		}
	}
}

// chunks splits text on line breaks into parts of at most limit UTF-16 units, the unit Telegram
// counts; one line longer than the limit is cut where it must be.
func chunks(text string, limit int) []string {
	var out []string
	for strings.TrimSpace(text) != "" {
		n, cut := 0, len(text)
		for i, r := range text {
			if n += len(utf16.Encode([]rune{r})); n > limit {
				cut = i
				break
			}
		}
		part, rest := text[:cut], text[cut:]
		if cut < len(text) {
			if nl := strings.LastIndex(part, "\n"); nl > 0 {
				part, rest = text[:nl], text[nl+1:]
			}
		}
		if strings.TrimSpace(part) != "" {
			out = append(out, part)
		}
		text = rest
	}
	return out
}

// inbox runs the real jg-inbox.sh against this home.
func (a *app) inbox(stdin string, args ...string) ([]byte, error) {
	cmd := exec.Command(filepath.Join(a.root, "bin", "jg-inbox.sh"), args...)
	cmd.Stdin = strings.NewReader(stdin)
	cmd.Env = append(os.Environ(), "JG_HOME="+a.home, "JG_STATE_OVERRIDE="+a.state, "JG_DATA_OVERRIDE="+a.data)
	return cmd.Output()
}

// readLines decodes each line of a jsonl record into T; a torn or blank line is skipped.
func readLines[T any](path string, each func(T)) {
	raw, _ := os.ReadFile(path)
	for _, l := range strings.Split(string(raw), "\n") {
		var v T
		if json.Unmarshal([]byte(l), &v) == nil {
			each(v)
		}
	}
}

// followReplies sends every reply made since the committed cursor to the chat its note came from.
// A reply to a note that did not come from this adapter is passed over. Each part is recorded in
// sent.jsonl as it goes, so a restart after a part sent never sends that part again; a send that
// fails leaves the cursor, and the next pass tries again. A call that can never work (400, 403)
// is written to the undelivered record and passed over, so one dead chat cannot hold the rest.
func (a *app) followReplies(ad Adapter) error {
	dir := filepath.Join(a.state, "captain-chat")
	cursorFile := filepath.Join(dir, ad.Name()+".reply-cursor")
	prev, _ := os.ReadFile(cursorFile)
	cursor := strings.TrimSpace(string(prev))
	out, err := a.inbox("", "receipts", "--after", cursor, "--all-replies")
	var rec struct {
		Replies []struct{ ID, Body, Cursor string }
	}
	if err != nil || json.Unmarshal(out, &rec) != nil {
		return fmt.Errorf("jg-inbox receipts failed: %v", err)
	}
	type where struct{ chat, message string }
	notes, sent := map[string]where{}, map[string]bool{}
	readLines(filepath.Join(dir, "inbound.jsonl"), func(v map[string]string) {
		if v["adapter"] == ad.Name() {
			notes[v["note"]] = where{v["chat"], v["message"]}
		}
	})
	readLines(filepath.Join(dir, "sent.jsonl"), func(v map[string]string) { sent[v["key"]] = true })
	for _, r := range rec.Replies {
		if w, ok := notes[r.ID]; ok {
			for i, part := range chunks(r.Body, ad.Limit()) {
				key := r.Cursor + "#" + strconv.Itoa(i)
				if sent[key] {
					continue
				}
				id, err := ad.Send(context.Background(), Outbound{Chat: w.chat, ReplyTo: w.message, Text: part})
				var se *sendError
				if errors.As(err, &se) && (se.code == 400 || se.code == 403) {
					a.noteUndelivered(ad.Name(), err.Error(), toJSON(map[string]string{"note": r.ID, "key": key}))
					break
				} else if err != nil {
					return err
				}
				if err := appendLine(filepath.Join(dir, "sent.jsonl"), toJSON(map[string]string{"key": key, "note": r.ID, "chat": w.chat, "message": id})); err != nil {
					return err
				}
			}
		}
		if err := os.WriteFile(cursorFile+".tmp", []byte(r.Cursor+"\n"), 0o600); err != nil {
			return err
		}
		if err := os.Rename(cursorFile+".tmp", cursorFile); err != nil {
			return err
		}
	}
	return nil
}
