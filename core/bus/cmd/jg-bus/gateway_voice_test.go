package main

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

// A message to the captain goes through the voice file on its way to Telegram: plain terms are
// replaced, a URL is left alone, and with no checker or voice file the text goes out as written.
func TestGatewayVoice(t *testing.T) {
	root, err := filepath.Abs("../../../..")
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv("JG_BUS_ROOT", root)
	t.Setenv("JG_VOICE_FILE", "")
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
	want := "The merge check passed. The local copy is clean. See https://github.com/example/repo/pull/602 key=worktree."
	if len(l.sends) != 1 || l.sends[0]["text"] != want {
		t.Fatalf("sends %v: want one message reading %q", l.sends, want)
	}
	t.Logf("telegram sendMessage, before: %s", text)
	t.Logf("telegram sendMessage, after:  %v", l.sends[0]["text"])

	// An edited voice file changes the send with no code change.
	voice := filepath.Join(t.TempDir(), "voice.md")
	if err := os.WriteFile(voice, []byte("## Settings\n\n- mode: rewrite\n\n## Internal terms\n\n| Pattern | Say instead |\n|---|---|\n| `\\bclean\\b` | tidy |\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Setenv("JG_VOICE_FILE", voice)
	if got := voiceText("The copy is clean."); got != "The copy is tidy." {
		t.Fatalf("edited file: got %q", got)
	}
	t.Logf("edited voice file: %q now sends %q", "The copy is clean.", voiceText("The copy is clean."))

	// No checker, no change: the text goes out as written.
	t.Setenv("JG_BUS_ROOT", filepath.Join(t.TempDir(), "none"))
	if got := voiceText(text); got != text {
		t.Fatalf("no checker: got %q, want the text as written", got)
	}
}
