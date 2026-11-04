package main

import (
	"context"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

// stubRewrite is the injected model: a script that prints reply whatever it is asked, so no test
// calls a real model.
func stubRewrite(t *testing.T, reply string, exit int) {
	t.Helper()
	script := filepath.Join(t.TempDir(), "rewrite.sh")
	body := "#!/bin/sh\ncat >/dev/null\nprintf '%s' '" + reply + "'\nexit " + strconv.Itoa(exit) + "\n"
	if err := os.WriteFile(script, []byte(body), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("JG_VOICE_REWRITE_CMD", script)
}

// A message to the captain goes through the voice file on its way to Telegram: a message with a
// banned term is rewritten whole by the model step and re-checked, a refused message is never
// sent, a URL is left alone, and with no checker or voice file the text goes out as written.
func TestGatewayVoice(t *testing.T) {
	root, err := filepath.Abs("../../../..")
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv("JG_BUS_ROOT", root)
	t.Setenv("JG_VOICE_FILE", "")
	want := "The merge check passed. The local copy is clean. See https://github.com/example/repo/pull/602 key=worktree."
	stubRewrite(t, want, 0)
	l := newChatLab(t, true)
	ad, owner, err := l.a.chatTarget()
	if ad == nil || err != nil {
		t.Fatalf("chat target %v, %v", ad, err)
	}
	ad.sleep = func(time.Duration) {}
	p := l.a.gatewayPart(ad, owner)
	text := "The merge guard passed. The worktree is clean. See https://github.com/example/repo/pull/602 key=worktree."
	if err := p.handle([]byte(l.a.eventJSON(1000, "outcome", "v1", text, ""))); err != nil {
		t.Fatal(err)
	}
	if len(l.sends) != 1 || l.sends[0]["text"] != want {
		t.Fatalf("sends %v: want one message reading %q", l.sends, want)
	}
	t.Logf("telegram sendMessage, before: %s", text)
	t.Logf("telegram sendMessage, after:  %v", l.sends[0]["text"])

	// A rewrite that still holds a banned term, or a model that fails, sends nothing: the send fails
	// with a 400 and the re-draft instruction, so the event is recorded as undelivered.
	for _, bad := range []struct {
		reply string
		exit  int
	}{{"The worktree is clean.", 0}, {"", 1}} {
		stubRewrite(t, bad.reply, bad.exit)
		before := len(l.sends)
		if _, err := ad.Send(context.Background(), Outbound{Chat: "1", Text: text}); err == nil || !strings.Contains(err.Error(), "Re-draft it") {
			t.Fatalf("a refused message must fail with a re-draft instruction, got %v", err)
		}
		if len(l.sends) != before {
			t.Fatalf("a refused message was sent: %v", l.sends[before:])
		}
	}
	stubRewrite(t, "The copy is tidy.", 0)

	// An edited voice file changes the send with no code change.
	voice := filepath.Join(t.TempDir(), "voice.md")
	if err := os.WriteFile(voice, []byte("## Settings\n\n- mode: rewrite\n\n## Internal terms\n\n| Pattern | Say instead |\n|---|---|\n| `\\bclean\\b` | tidy |\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Setenv("JG_VOICE_FILE", voice)
	if got, err := voiceText("The copy is clean."); err != nil || got != "The copy is tidy." {
		t.Fatalf("edited file: got %q, %v", got, err)
	}
	if got, err := voiceText("The copy is fine."); err != nil || got != "The copy is fine." {
		t.Fatalf("a clean message must pass unchanged: got %q, %v", got, err)
	}

	// No checker, no change: the text goes out as written.
	t.Setenv("JG_BUS_ROOT", filepath.Join(t.TempDir(), "none"))
	if got, err := voiceText(text); err != nil || got != text {
		t.Fatalf("no checker: got %q, %v, want the text as written", got, err)
	}
}
