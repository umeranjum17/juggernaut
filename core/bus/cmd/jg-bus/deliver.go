package main

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"time"
)

// consumerName is the durable pull consumer that reads the CAPTAIN stream for delivery.
const consumerName = "captain-ntfy"

// natsArgs is the client login and server every stream command shares.
func (a *app) natsArgs(rest ...string) []string {
	return append(append(a.natsAuth(), "-s", a.cfgOr("nats-url", "")), rest...)
}

// ensureConsumer creates the durable consumer when it is not on the stream. It starts at
// the first message, so an event published while this service was down is delivered when it
// comes back instead of lost.
func (a *app) ensureConsumer() error {
	stream := a.streamName()
	if exec.Command("nats", a.natsArgs("consumer", "info", stream, consumerName)...).Run() == nil {
		return nil
	}
	out, err := exec.Command("nats", a.natsArgs("consumer", "add", stream, consumerName,
		"--pull", "--deliver", "all", "--ack", "explicit", "--defaults")...).CombinedOutput()
	if err != nil {
		return fmt.Errorf("%s", detail(string(out)))
	}
	return nil
}

// eventText reads the captain's text out of one stream message. Dapr may wrap the event in
// a CloudEvents envelope, so the event is the envelope's data when there is one.
func eventText(payload []byte) (ev event, ok bool) {
	var wrapped struct {
		Data json.RawMessage `json:"data"`
	}
	if json.Unmarshal(payload, &wrapped) == nil && len(wrapped.Data) > 0 {
		payload = wrapped.Data
		var inner string // an envelope made without a JSON content type carries the event as a string
		if json.Unmarshal(payload, &inner) == nil {
			payload = []byte(inner)
		}
	}
	if json.Unmarshal(payload, &ev) != nil || ev.Text == "" {
		return ev, false
	}
	return ev, true
}

// deliverOne delivers one stream message to ntfy and writes the delivery record: the stream
// subject, the event key and ntfy's own message id, so the record and ntfy's log name one
// event. A message that is not a captain event, or that ntfy refuses, is named in the
// undelivered record; nothing retries on its own, as on the direct path.
func (a *app) deliverOne(payload []byte) {
	ev, ok := eventText(payload)
	if !ok {
		// A captain reply shares the stream and belongs to the router, not to ntfy.
		var reply struct {
			Answer string `json:"answer"`
		}
		if json.Unmarshal(payload, &reply) == nil && reply.Answer != "" {
			return
		}
		a.noteFailure("deliver", "stream message is not a captain event")
		a.noteUndelivered("", "stream message is not a captain event", toJSON(string(payload)))
		return
	}
	target, id, err := a.deliverToNtfy(ev.Text)
	if err != nil {
		a.noteFailure("ntfy", err.Error())
		a.noteUndelivered(target, err.Error(), toJSON(ev))
		return
	}
	appendQuiet(a.delivered, fmt.Sprintf(`{"at":%d,"subject":%s,"key":%s,"ntfy_id":%s,"target":%s}`,
		time.Now().Unix(), toJSON(ev.Subject), toJSON(ev.Key), toJSON(id), toJSON(target)))
}

// pull fetches the next message with a server-side wait. It returns the payload, whether one
// came, and an error only for a real failure: an empty wait is not one.
func (a *app) pull(wait string) ([]byte, bool, error) {
	cmd := exec.Command("nats", a.natsArgs("--timeout", wait, "consumer", "next",
		a.streamName(), consumerName, "--raw", "--count", "1")...)
	out, err := cmd.CombinedOutput()
	if err == nil {
		return []byte(strings.TrimRight(string(out), "\n")), true, nil
	}
	// An empty wait ends two ways: the client's timer, or the server's own "request timed
	// out" status, which the client then cannot acknowledge because it has no reply.
	if strings.Contains(string(out), "timeout") || strings.Contains(string(out), "does not have a reply") {
		return nil, false, nil
	}
	return nil, false, fmt.Errorf("%s", detail(string(out)))
}

// deliver is the CAPTAIN stream's consumer: every event on the stream goes to ntfy, and
// each delivery is written to state/captain-channel-delivered.jsonl. `--once` drains what is
// waiting and exits; without it the command runs as the service until stopped.
func (a *app) deliver(args []string) int {
	once := len(args) > 0 && args[0] == "--once"
	if len(args) > 0 && !once {
		return die("deliver: unknown flag %s", args[0])
	}
	if a.channelMode() != "live" {
		say("deliver: mode %s, nothing is delivered", a.channelMode())
		return 0
	}
	if _, err := exec.LookPath("nats"); err != nil {
		return die("deliver needs the nats client on PATH")
	}
	if err := os.MkdirAll(a.state, 0o755); err != nil {
		return die("cannot create %s", a.state)
	}
	for !once {
		if err := a.ensureConsumer(); err == nil {
			break
		}
		time.Sleep(2 * time.Second)
	}
	if once {
		if err := a.ensureConsumer(); err != nil {
			return die("cannot create the %s consumer: %v", consumerName, err)
		}
	}
	wait := "30s"
	if once {
		wait = "2s"
	}
	for {
		payload, got, err := a.pull(wait)
		switch {
		case err != nil && once:
			return die("deliver: %v", err)
		case err != nil:
			a.noteFailure("deliver", err.Error())
			time.Sleep(2 * time.Second)
		case got:
			a.deliverOne(payload)
		case once:
			return 0
		}
	}
}
