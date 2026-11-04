package main

// gateway_typing.go shows the owner that a note is being worked on. From the moment the gateway
// files a note until `jg-inbox.sh reply` answers it, the chat shows "typing…". Telegram shows a
// chat action for about 5 seconds, so it is sent again every 4. One chat has one indicator, however
// many notes it has open. A note nobody answers stops after a hard cap, and a refused action is
// logged and never touches the note or its reply.

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"os"
	"os/signal"
	"strconv"
	"sync"
	"syscall"
	"time"
)

const (
	typingEvery = 4 * time.Second // a chat action lasts about 5 s
	typingCap   = 10 * time.Minute
)

// Typing is sendChatAction "typing": the chat shows that the bot is writing.
func (t *telegram) Typing(ctx context.Context, chat string) error {
	body, _ := json.Marshal(map[string]any{"chat_id": json.Number(chat), "action": "typing"})
	_, err := t.call(ctx, "sendChatAction", 5*time.Second, func() (io.Reader, string) { return bytes.NewReader(body), "application/json" })
	return err
}

// typer keeps one indicator per chat for as long as the chat has an open note. A nil typer does
// nothing, which is how a one-shot pass and a platform without the action run.
type typer struct {
	ad     Adapter
	every  time.Duration
	cap    time.Duration
	now    func() time.Time
	fail   func(string) // where a refused action is logged
	mu     sync.Mutex
	open   map[string]map[string]time.Time // chat -> open note -> when it was filed
	wake   chan string
	failed map[string]string // chat -> the refusal last logged, so a dead chat logs once, not every 4 s
	stop   chan struct{}
	once   sync.Once
}

func newTyper(ad Adapter, every, cap time.Duration, fail func(string)) *typer {
	return &typer{ad: ad, every: every, cap: cap, now: time.Now, fail: fail, open: map[string]map[string]time.Time{},
		wake: make(chan string, 16), failed: map[string]string{}, stop: make(chan struct{})}
}

// typerFor is the typer this home's settings describe; chat-typing-cap-seconds is the hard cap.
func (a *app) typerFor(ad Adapter) *typer {
	cap := typingCap
	if n, err := strconv.Atoi(a.cfgOr("chat-typing-cap-seconds", "")); err == nil && n > 0 {
		cap = time.Duration(n) * time.Second
	}
	return newTyper(ad, typingEvery, cap, func(s string) { a.noteFailure("gateway typing", s) })
}

// begin opens a note. The first open note of a chat shows the indicator at once.
func (t *typer) begin(chat, note string) {
	if t == nil {
		return
	}
	t.mu.Lock()
	first := len(t.open[chat]) == 0
	if t.open[chat] == nil {
		t.open[chat] = map[string]time.Time{}
	}
	t.open[chat][note] = t.now()
	t.mu.Unlock()
	if first {
		select {
		case t.wake <- chat:
		default: // the next tick sends it
		}
	}
}

// end closes a note: its chat stops when it has no other open note. An unknown note is ignored.
func (t *typer) end(note string) {
	if t == nil {
		return
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	for chat, notes := range t.open {
		delete(notes, note)
		if len(notes) == 0 {
			delete(t.open, chat)
			delete(t.failed, chat)
		}
	}
}

// shutdown ends every indicator for good.
func (t *typer) shutdown() {
	if t != nil {
		t.once.Do(func() { close(t.stop) })
	}
}

// live reports whether the chat still has a note inside the cap; a note past it is dropped.
func (t *typer) live(chat string) bool {
	t.mu.Lock()
	defer t.mu.Unlock()
	for note, since := range t.open[chat] {
		if t.now().Sub(since) >= t.cap {
			delete(t.open[chat], note)
		}
	}
	if len(t.open[chat]) == 0 {
		delete(t.open, chat)
		delete(t.failed, chat)
		return false
	}
	return true
}

// ping sends one chat action when the chat still has an open note.
func (t *typer) ping(chat string) {
	if !t.live(chat) {
		return
	}
	err := t.ad.Typing(context.Background(), chat)
	t.mu.Lock()
	defer t.mu.Unlock()
	switch {
	case err == nil:
		delete(t.failed, chat)
	case t.failed[chat] != err.Error():
		t.failed[chat] = err.Error()
		t.fail(err.Error())
	}
}

// run sends the indicators until shutdown.
func (t *typer) run() {
	tick := time.NewTicker(t.every)
	defer tick.Stop()
	for {
		select {
		case <-t.stop:
			return
		case chat := <-t.wake:
			t.ping(chat)
		case <-tick.C:
			t.mu.Lock()
			chats := make([]string, 0, len(t.open))
			for chat := range t.open {
				chats = append(chats, chat)
			}
			t.mu.Unlock()
			for _, chat := range chats {
				select {
				case <-t.stop:
					return
				default:
					t.ping(chat)
				}
			}
		}
	}
}

// stopOnSignal ends the indicators and the gateway when the service is told to stop, so nothing
// keeps showing "typing…" for an owner whose bot is gone.
func (t *typer) stopOnSignal() {
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, os.Interrupt, syscall.SIGTERM)
	go func() {
		<-sig
		t.shutdown()
		os.Exit(0)
	}()
}
