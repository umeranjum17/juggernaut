package main

import (
	"bytes"
	"os"
	"strings"
	"testing"
)

// directLab is a chat lab in `direct` mode: the one mode that delivers.
func directLab(t *testing.T, withToken bool) *chatLab {
	return newChatLab(t, withToken)
}

// In direct mode one card is recorded once and sent once, a refused send
// is named undelivered with the target direct, and an answer takes the board's route.
func TestDirectMode(t *testing.T) {
	l := directLab(t, true)
	if l.a.channelMode() != "direct" {
		t.Fatalf("mode %q, want direct", l.a.channelMode())
	}
	l.a.publish([]string{"card", "c-1", "pick one", "--option", "a=A"})
	if len(l.sends) != 1 || countLines(l.a.record) != 1 || l.lost() != 0 {
		t.Fatalf("sends %d, recorded %d, undelivered %d: want 1, 1, 0", len(l.sends), countLines(l.a.record), l.lost())
	}
	l.botCodes = []int{500}
	l.a.publish([]string{"alert", "a-1", "disk full"})
	if l.lost() != 1 || !strings.Contains(readFileString(l.a.undelivered), `"target":"direct"`) || !strings.Contains(readFileString(l.a.undelivered), "disk full") {
		t.Fatalf("undelivered %d: want one line with target direct and the event", l.lost())
	}
	l.a.emitReply("c-1", "a", "A")
	if !strings.Contains(readFileString(l.routed), "a") || l.lost() != 1 {
		t.Fatalf("routed %q: want the board route", readFileString(l.routed))
	}
}

// Every gate accepts direct: the chat target, serve, status, the row and a push.
func TestDirectModeChatGates(t *testing.T) {
	l := directLab(t, true)
	if ad, owner, err := l.a.chatTarget(); ad == nil || owner != "42" || err != nil {
		t.Fatalf("chat target %v %q %v: want the chat on in direct mode", ad, owner, err)
	}
	if l.a.gateway([]string{"enabled"}) != 0 {
		t.Fatal("gateway enabled must say yes in direct mode, so serve stays up")
	}
	if err := l.a.pushOwner("hello"); err != nil || len(l.sends) != 1 {
		t.Fatalf("push: %v, sends %d: want one message", err, len(l.sends))
	}
	if out := captureStdout(func() int { return l.a.gateway([]string{"status", "--row"}) }); strings.HasPrefix(out, "absent") {
		t.Fatalf("row %q: want it on in direct mode", out)
	}
	if out := captureStdout(func() int { return l.a.gateway([]string{"status"}) }); strings.Contains(out, "gateway: off") {
		t.Fatalf("status %q: want it on in direct mode", out)
	}
	if out := captureStdout(l.a.status); !strings.Contains(out, "mode direct") {
		t.Fatalf("channel status %q: want mode direct", out)
	}

}

// captureStdout runs one command with stdout captured.
func captureStdout(run func() int) string {
	old := os.Stdout
	read, write, err := os.Pipe()
	if err != nil {
		return ""
	}
	os.Stdout = write
	done := make(chan string)
	go func() {
		var buf bytes.Buffer
		_, _ = buf.ReadFrom(read)
		done <- buf.String()
	}()
	run()
	os.Stdout = old
	_ = write.Close()
	return <-done
}
