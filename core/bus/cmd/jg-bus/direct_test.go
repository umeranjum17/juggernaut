package main

import (
	"os"
	"strings"
	"testing"
	"time"
)

// directLab is a chat lab in `direct` mode with no bus listening at all.
func directLab(t *testing.T, withToken bool) *chatLab {
	l := newChatLab(t, withToken)
	l.daprDown = true
	conf := l.a.configFiles[0]
	b, _ := os.ReadFile(conf)
	os.WriteFile(conf, []byte(strings.Replace(string(b), "set mode live", "set mode direct", 1)), 0o600)
	return l
}

// In direct mode one card is recorded once and sent once, the bus is never posted to, a refused send
// is named undelivered with the target direct, and an answer takes the board's route.
func TestDirectMode(t *testing.T) {
	l := directLab(t, true)
	if l.a.channelMode() != "direct" {
		t.Fatalf("mode %q, want direct", l.a.channelMode())
	}
	l.a.publish([]string{"card", "c-1", "pick one", "--option", "a=A"})
	if len(l.sends) != 1 || countLines(l.a.record) != 1 || l.lost() != 0 || len(l.published) != 0 {
		t.Fatalf("sends %d, recorded %d, undelivered %d, posted %v: want 1, 1, 0, none", len(l.sends), countLines(l.a.record), l.lost(), l.published)
	}
	l.botCodes = []int{500}
	l.a.publish([]string{"alert", "a-1", "disk full"})
	if l.lost() != 1 || !strings.Contains(readFileString(l.a.undelivered), `"target":"direct"`) || !strings.Contains(readFileString(l.a.undelivered), "disk full") {
		t.Fatalf("undelivered %d: want one line with target direct and the event", l.lost())
	}
	l.a.emitReply("c-1", "a", "A")
	if !strings.Contains(readFileString(l.routed), "a") || len(l.published) != 0 || l.lost() != 1 {
		t.Fatalf("routed %q, posted %v: want the board route and no bus", readFileString(l.routed), l.published)
	}
}

// Every gate that asked for mode live now accepts direct: the chat target, serve, status, the row and a push.
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
	// serve starts no consumer: the event loop returns at once instead of retrying a missing bus.
	ad, owner, _ := l.a.chatTarget()
	done := make(chan struct{})
	go func() { l.a.serveGatewayEvents(ad, owner); close(done) }()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("serveGatewayEvents kept running in direct mode: it started the consumer")
	}
}
