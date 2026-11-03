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

// Outbound is one message to send: ReplyTo is the id of the message it answers. With Files it is
// a picture or a file and Text is its caption.
type Outbound struct {
	Chat, ReplyTo, Text string
	Files               []LocalFile
}

// sendError carries the Bot API's error code, so a call that can never work (a blocked bot) is
// told from one worth another try.
type sendError struct {
	method string
	code   int
	msg    string
}

func (e *sendError) Error() string { return fmt.Sprintf("%s answered %d: %s", e.method, e.code, e.msg) }

func (t *telegram) Limit() int { return 4096 }

// Send is sendMessage threaded on ReplyTo, or the files of out. A 429 waits and sends again.
func (t *telegram) Send(ctx context.Context, out Outbound) (string, error) {
	reply, _ := json.Marshal(map[string]any{"message_id": json.Number(out.ReplyTo), "allow_sending_without_reply": true})
	if len(out.Files) > 0 {
		return t.sendFiles(ctx, out, string(reply))
	}
	body, _ := json.Marshal(map[string]any{"chat_id": json.Number(out.Chat), "text": out.Text, "reply_parameters": json.RawMessage(reply)})
	return t.call(ctx, "sendMessage", 30*time.Second, func() (io.Reader, string) { return bytes.NewReader(body), "application/json" })
}

// call posts one Bot API method and returns the id of the message it made.
func (t *telegram) call(ctx context.Context, method string, wait time.Duration, body func() (io.Reader, string)) (string, error) {
	for try := 0; ; try++ {
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
		if err := func() error {
			ctx, cancel := context.WithTimeout(ctx, wait)
			defer cancel()
			r, kind := body()
			req, _ := http.NewRequestWithContext(ctx, http.MethodPost, t.base+"/bot"+t.token+"/"+method, r)
			req.Header.Set("Content-Type", kind)
			resp, err := http.DefaultClient.Do(req)
			if err != nil {
				return errors.New(redact(err.Error(), t.token))
			}
			defer resp.Body.Close()
			raw, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
			if json.Unmarshal(raw, &res) != nil {
				res.Code = resp.StatusCode
			}
			return nil
		}(); err != nil {
			return "", err
		}
		switch {
		case res.OK:
			return strconv.FormatInt(res.Result.ID, 10), nil
		case res.Code == http.StatusTooManyRequests && try < 3:
			t.sleep(time.Duration(res.Parameters.RetryAfter) * time.Second)
		default:
			return "", &sendError{method, res.Code, redact(res.Description, t.token)}
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

// where is the chat and message a note came from, and so where its answer goes.
type where struct{ chat, message string }

// sendPart is one send of a reply; its key is how sent.jsonl remembers it was done.
type sendPart struct {
	key string
	out Outbound
}

// replyParts is the sends one reply takes: each file that may go, then its text. The text rides
// as the caption of the first file when it fits one. A file that must not be sent is left out and
// named in the text, so the owner is told instead of left waiting.
func (a *app) replyParts(ad Adapter, w where, cursor, body string, attach []string) (parts []sendPart) {
	lim, files, refused := ad.Out(), []LocalFile{}, []string{}
	for _, p := range attach {
		if f, why := a.vetAttachment(lim, p); why != "" {
			refused = append(refused, why)
		} else {
			files = append(files, f)
		}
	}
	if len(refused) > 0 {
		body = strings.TrimSpace(body + "\n\n" + strings.Join(refused, "\n"))
	}
	caption := ""
	if len(files) > 0 && utf16Len(body) <= lim.Caption {
		caption, body = body, ""
	}
	for i, f := range files {
		out := Outbound{Chat: w.chat, ReplyTo: w.message, Files: []LocalFile{f}}
		if i == 0 {
			out.Text = caption
		}
		parts = append(parts, sendPart{cursor + "#f" + strconv.Itoa(i), out})
	}
	for i, text := range chunks(body, ad.Limit()) {
		parts = append(parts, sendPart{cursor + "#" + strconv.Itoa(i), Outbound{Chat: w.chat, ReplyTo: w.message, Text: text}})
	}
	return parts
}

// followReplies sends every reply made since the committed cursor to the chat its note came from.
// A reply to a note that did not come from this adapter is passed over. Each part is recorded in
// sent.jsonl as it goes, so a restart after a part sent never sends that part again; a send that
// fails leaves the cursor, and the next pass tries again. A call that can never work (400, 403,
// 413) is written to the undelivered record and passed over, so one dead chat cannot hold the rest.
func (a *app) followReplies(ad Adapter) error {
	dir := filepath.Join(a.state, "captain-chat")
	cursorFile := filepath.Join(dir, ad.Name()+".reply-cursor")
	prev, _ := os.ReadFile(cursorFile)
	cursor := strings.TrimSpace(string(prev))
	out, err := a.inbox("", "receipts", "--after", cursor, "--all-replies")
	var rec struct {
		Replies []struct {
			ID, Body, Cursor string
			Attachments      []string
		}
	}
	if err != nil || json.Unmarshal(out, &rec) != nil {
		return fmt.Errorf("jg-inbox receipts failed: %v", err)
	}
	notes, sent := map[string]where{}, map[string]bool{}
	readLines(filepath.Join(dir, "inbound.jsonl"), func(v map[string]string) {
		if v["adapter"] == ad.Name() {
			notes[v["note"]] = where{v["chat"], v["message"]}
		}
	})
	readLines(filepath.Join(dir, "sent.jsonl"), func(v map[string]string) { sent[v["key"]] = true })
	for _, r := range rec.Replies {
		if w, ok := notes[r.ID]; ok {
			parts := a.replyParts(ad, w, r.Cursor, r.Body, r.Attachments)
			for _, p := range parts {
				if sent[p.key] {
					continue
				}
				id, err := ad.Send(context.Background(), p.out)
				var se *sendError
				if errors.As(err, &se) && (se.code == 400 || se.code == 403 || se.code == 413) {
					a.noteUndelivered(ad.Name(), err.Error(), toJSON(map[string]string{"note": r.ID, "key": p.key}))
					break
				} else if err != nil {
					return err
				}
				if err := appendLine(filepath.Join(dir, "sent.jsonl"), toJSON(map[string]string{"key": p.key, "note": r.ID, "chat": w.chat, "message": id})); err != nil {
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
