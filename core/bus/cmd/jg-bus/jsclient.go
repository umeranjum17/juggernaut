package main

// jsclient.go - the smallest JetStream pull client the machine consumers need, written on the
// standard library because the shipped Go module carries no NATS library.
//
// Why it exists: the `nats` CLI's `consumer next` acknowledges a message in the same call that
// fetches it, so a consumer that used it called an event "delivered" before its handler had run.
// This client fetches one message and leaves it open. The caller acknowledges it only after the
// handler returned (+ACK), asks for another try when the handler failed (-NAK with a delay), or
// gives up on it (+TERM), and keeps it alive with +WPI while a slow handler runs.
//
// It speaks the NATS client protocol over plain TCP: CONNECT with a user and password, a pull
// request to $JS.API.CONSUMER.MSG.NEXT.<stream>.<consumer>, and the acknowledgement published to the
// message's reply subject. It does not do TLS; the bus the stack runs listens on 127.0.0.1.

import (
	"bufio"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"
)

// jsConn is one connection to the server. Writes are locked so the keep-alive ticker and the
// acknowledgement never interleave their bytes.
type jsConn struct {
	c   net.Conn
	r   *bufio.Reader
	wmu sync.Mutex
}

// jsMsg is one fetched message. Reply is the acknowledgement subject.
type jsMsg struct {
	Subject string
	Reply   string
	Data    []byte
	Status  int // the server's status code on a status message (408 timeout, 409 conflict, 503 no responders), else 0
	Text    string
}

func dialNATS(rawurl, user, pass string) (*jsConn, error) {
	u, err := url.Parse(rawurl)
	if err != nil || u.Host == "" {
		return nil, fmt.Errorf("cannot read the bus address %q", rawurl)
	}
	if u.Scheme != "nats" {
		return nil, fmt.Errorf("the bus address %q is not a plain nats:// address", rawurl)
	}
	host := u.Host
	if u.Port() == "" {
		host = net.JoinHostPort(u.Hostname(), "4222")
	}
	c, err := net.DialTimeout("tcp", host, 5*time.Second)
	if err != nil {
		return nil, err
	}
	j := &jsConn{c: c, r: bufio.NewReaderSize(c, 64<<10)}
	_ = c.SetDeadline(time.Now().Add(5 * time.Second))
	if line, err := j.r.ReadString('\n'); err != nil || !strings.HasPrefix(line, "INFO") {
		_ = c.Close()
		return nil, fmt.Errorf("the server did not greet with INFO: %q %v", strings.TrimSpace(line), err)
	}
	connect := map[string]any{"verbose": false, "pedantic": false, "headers": true, "no_responders": true,
		"protocol": 1, "lang": "go", "version": "jg-bus", "name": "jg-bus"}
	if user != "" {
		connect["user"], connect["pass"] = user, pass
	}
	data, _ := json.Marshal(connect)
	if err := j.write("CONNECT " + string(data) + "\r\nPING\r\n"); err != nil {
		_ = c.Close()
		return nil, err
	}
	if err := j.readUntilPong(); err != nil {
		_ = c.Close()
		return nil, err
	}
	_ = c.SetDeadline(time.Time{})
	return j, nil
}

func (j *jsConn) close() { _ = j.c.Close() }

func (j *jsConn) write(s string) error {
	j.wmu.Lock()
	defer j.wmu.Unlock()
	_, err := io.WriteString(j.c, s)
	return err
}

func (j *jsConn) publish(subject, reply string, payload []byte) error {
	head := "PUB " + subject + " "
	if reply != "" {
		head += reply + " "
	}
	return j.write(head + strconv.Itoa(len(payload)) + "\r\n" + string(payload) + "\r\n")
}

// readUntilPong reads protocol lines until the server's PONG; an -ERR line is the reason a
// connection was refused.
func (j *jsConn) readUntilPong() error {
	for {
		_, pong, err := j.readOp()
		if err != nil || pong {
			return err
		}
	}
}

// readOp reads one operation. It answers PING itself and returns a message for MSG and HMSG.
func (j *jsConn) readOp() (*jsMsg, bool, error) {
	line, err := j.r.ReadString('\n')
	if err != nil {
		return nil, false, err
	}
	line = strings.TrimRight(line, "\r\n")
	f := strings.Fields(line)
	if len(f) == 0 {
		return nil, false, nil
	}
	switch strings.ToUpper(f[0]) {
	case "PING":
		return nil, false, j.write("PONG\r\n")
	case "PONG":
		return nil, true, nil
	case "-ERR":
		return nil, false, fmt.Errorf("the server refused the connection: %s", strings.Trim(strings.TrimPrefix(line, f[0]), " '"))
	case "MSG", "HMSG":
		hdr := strings.ToUpper(f[0]) == "HMSG"
		// MSG <subject> <sid> [reply] <bytes>; HMSG <subject> <sid> [reply] <header bytes> <total bytes>
		need := 4
		if hdr {
			need = 5
		}
		if len(f) < need || len(f) > need+1 {
			return nil, false, fmt.Errorf("malformed server line %q", line)
		}
		m := &jsMsg{Subject: f[1]}
		rest := f[3:]
		if len(rest) == need-2 { // a reply subject is present
			m.Reply, rest = rest[0], rest[1:]
		}
		hlen := 0
		if hdr {
			hlen, _ = strconv.Atoi(rest[0])
			rest = rest[1:]
		}
		total, err := strconv.Atoi(rest[0])
		if err != nil || total < hlen || total > 64<<20 {
			return nil, false, fmt.Errorf("malformed server line %q", line)
		}
		buf := make([]byte, total+2)
		if _, err := io.ReadFull(j.r, buf); err != nil {
			return nil, false, err
		}
		if hlen > 0 {
			first, _, _ := strings.Cut(string(buf[:hlen]), "\r\n")
			if p := strings.Fields(first); len(p) >= 2 {
				m.Status, _ = strconv.Atoi(p[1])
				m.Text = strings.Join(p[2:], " ")
			}
		}
		m.Data = buf[hlen:total]
		return m, false, nil
	}
	return nil, false, nil // INFO, +OK
}

// next fetches one message from a durable pull consumer and leaves it unacknowledged. It returns
// nil, nil when nothing arrived within wait.
func (j *jsConn) next(stream, consumer string, wait time.Duration) (*jsMsg, error) {
	var raw [8]byte
	_, _ = rand.Read(raw[:])
	inbox := "_INBOX.jgbus." + hex.EncodeToString(raw[:])
	req, _ := json.Marshal(map[string]any{"batch": 1, "expires": int64(wait)})
	if err := j.write("SUB " + inbox + " 1\r\n"); err != nil {
		return nil, err
	}
	if err := j.publish("$JS.API.CONSUMER.MSG.NEXT."+stream+"."+consumer, inbox, req); err != nil {
		return nil, err
	}
	_ = j.c.SetReadDeadline(time.Now().Add(wait + 10*time.Second))
	defer func() { _ = j.c.SetReadDeadline(time.Time{}) }()
	for {
		m, _, err := j.readOp()
		if err != nil {
			return nil, err
		}
		if m == nil {
			continue
		}
		switch m.Status {
		case 0:
			return m, nil
		case 100: // idle heartbeat
			continue
		case 404, 408: // nothing waiting, request expired
			return nil, nil
		case 503:
			return nil, fmt.Errorf("no consumer %s on stream %s answered (no responders)", consumer, stream)
		default:
			return nil, fmt.Errorf("the server answered %d %s", m.Status, m.Text)
		}
	}
}

// tries is how many times the server has delivered this message, from its acknowledgement subject:
// $JS.ACK.<stream>.<consumer>.<delivered>.<stream seq>.<consumer seq>.<time>.<pending> (nine tokens), or
// the same with a domain and an account hash after ACK and a random token at the end (twelve).
func (m *jsMsg) tries() int {
	t := strings.Split(m.Reply, ".")
	i := len(t) - 5
	if len(t) >= 12 {
		i = len(t) - 6
	}
	if len(t) < 9 || i < 0 {
		return 1
	}
	n, err := strconv.Atoi(t[i])
	if err != nil || n < 1 {
		return 1
	}
	return n
}

// sync waits for the server to have read everything written so far, so an acknowledgement is not
// lost to a process that exits right after it.
func (j *jsConn) sync() error {
	if err := j.write("PING\r\n"); err != nil {
		return err
	}
	_ = j.c.SetReadDeadline(time.Now().Add(5 * time.Second))
	defer func() { _ = j.c.SetReadDeadline(time.Time{}) }()
	return j.readUntilPong()
}

func (j *jsConn) ack(m *jsMsg) error { return j.respond(m, "+ACK") }

// nak asks the server to redeliver the message after delay.
func (j *jsConn) nak(m *jsMsg, delay time.Duration) error {
	body := "-NAK"
	if delay > 0 {
		body += fmt.Sprintf(` {"delay": %d}`, int64(delay))
	}
	return j.respond(m, body)
}

// term tells the server to stop delivering the message.
func (j *jsConn) term(m *jsMsg) error { return j.respond(m, "+TERM") }

func (j *jsConn) respond(m *jsMsg, body string) error {
	if m.Reply == "" {
		return fmt.Errorf("the message has no acknowledgement subject")
	}
	if err := j.publish(m.Reply, "", []byte(body)); err != nil {
		return err
	}
	return j.sync()
}

// keepAlive sends +WPI every interval until the returned stop is called, so a handler that runs
// longer than the consumer's ack wait does not see the message redelivered under it.
func (j *jsConn) keepAlive(m *jsMsg, every time.Duration) (stop func()) {
	done := make(chan struct{})
	finished := make(chan struct{})
	go func() {
		defer close(finished)
		t := time.NewTicker(every)
		defer t.Stop()
		for {
			select {
			case <-done:
				return
			case <-t.C:
				_ = j.publish(m.Reply, "", []byte("+WPI"))
			}
		}
	}()
	return func() { close(done); <-finished }
}
