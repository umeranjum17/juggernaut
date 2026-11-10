// jg-wake-core is the Go half of the wake library: the decisions bin/jg-wake-lib.sh used to make in
// shell, answered here so one implementation owns them.
//
// The read model of the wake queue - what a queued row is, which rows an actor could act on, and
// which of a list of sequence numbers are still queued. Every command reads the rendered rows and
// never the bus: the store and its fold stay with bin/jg-wake-bus.sh and core/bus.
//
//	jg-wake-core [flags] dedupe <rows-file>
//	    the rows file with one row per event: a repeated kind/key is one row and the newest line
//	    wins, every heartbeat is one row, and the rows keep the order they first appeared in. This
//	    is what the drain and the watcher present, so a row delivered again never reads as two.
//	jg-wake-core [flags] keys <kind>
//	    the distinct keys queued for that kind, oldest first.
//	jg-wake-core [flags] queued <seq>...
//	    which of those sequence numbers are still queued, one per line. Exit 2 when the read model
//	    exists but cannot be read, so a caller never reads a broken queue as an empty one.
//	jg-wake-core [flags] count
//	    how many queued rows the actor could act on right now: Main owns every row a live branch
//	    grant does not reserve, and the branch owns exactly the rows its grant names. A row that
//	    is not a well-formed queue row is Main's, because nobody else can retire it.
//	jg-wake-core [flags] grant-valid <rows-file>
//	    exit 0 when the file is a non-empty list of distinct sequence numbers, and 1 otherwise.
//
// Wake urgency routing - the rule file (defaults/wake-routing, a home's config/wake-routing, or
// JG_WAKE_ROUTING) that gives every event the class now, batch or silent.
//
//	jg-wake-core [flags] route <kind> <key> <payload>
//	    print the event's class. The first matching rule wins and no match prints `now`, so a
//	    missing rule file never hides an event. A `<task>.status` key is matched against the newest
//	    line of that status file. A class may carry `@condition`: parked (a lane of a parked home),
//	    restart-pass (a lead Main's restart pass just restarted) or queue-quiet (no queued row
//	    routes to `now`) or fleet-unchanged (nothing changed since the last heartbeat that woke).
//	jg-wake-core [flags] classify <kind> <key> <payload>
//	    the class jg_wake_append_locked acts on: route, then a repeated `now` event inside the
//	    re-alert window and a `silent` event past the hourly cap both become `batch`. Counting a
//	    settled event against the cap writes state/.wake-silenced. key and payload are already
//	    cleaned of tabs and newlines.
//	jg-wake-core [flags] realert|realert-record <kind> <key> <payload>
//	    record a delivered `now` event in state/.wake-realert for the re-alert window.
//	The route-stdin, classify-stdin, realert-stdin and realert-record-stdin variants
//	omit the payload argument and read its full bytes from stdin.
//	jg-wake-core [flags] digest [mark]
//	    exit 0 and print how many queued rows wait for a turn when `set digest-count` rows have queued
//	    or `set digest-minutes` has passed
//	    since the last digest and at least one is queued; exit 1 otherwise. mark records the digest.
//	jg-wake-core [flags] fleet-fp-record [file]
//	    record the fleet's fingerprint, which the `@fleet-unchanged` condition compares against.
//	    With a file, record it there instead: the settled-wake check keeps its own baseline, so the
//	    heartbeat's is never moved by an acknowledgement.
//	jg-wake-core [flags] fleet-unchanged <file>
//	    exit 0 when the fleet looks the way the fingerprint in that file says, and 1 when it does
//	    not or the file holds none, so an unrecorded baseline never reads as an unchanged fleet.
//	jg-wake-core [flags] routing-files
//	    print the rule files in force, in priority order, one per line.
//	jg-wake-core [flags] rule-set <name> <default>
//	    print the first `set <name> <digits>` the rule files give, else <default>.
//
// Flags give a call the home and the queue the shell library resolved. The queue read model takes
// --queue (state/.wake-queue), --actor (main or branch) and --grant (the branch grant's row
// snapshot). The router takes --state, --home, --root (the checkout holding defaults/), --queue,
// --routing (JG_WAKE_ROUTING), --config (JG_CONFIG_OVERRIDE) and --now (epoch seconds, for a
// replay). Nothing here reads the environment. A missing queue file answers "no rows", which is
// what the file behaviour did. The usage line names every command, and tests/jg-go-entries.test.sh
// holds each name to a caller.
package main

import (
	"flag"
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"
)

func main() { os.Exit(run(os.Args[1:], os.Stdout, os.Stderr)) }

func run(args []string, out, errw io.Writer) int {
	var e env
	var now int64
	fs := flag.NewFlagSet("jg-wake-core", flag.ContinueOnError)
	fs.SetOutput(errw)
	fs.StringVar(&e.queue, "queue", "", "the read model of the queue (state/.wake-queue)")
	fs.StringVar(&e.actor, "actor", "main", "who is asking: main or branch")
	fs.StringVar(&e.grant, "grant", "", "the branch grant's row snapshot, when one is live")
	fs.StringVar(&e.state, "state", "", "state directory")
	fs.StringVar(&e.home, "home", "", "home directory")
	fs.StringVar(&e.defaultRoot, "root", "", "checkout holding defaults/")
	fs.StringVar(&e.routing, "routing", "", "override rule file")
	fs.StringVar(&e.configDir, "config", "", "config directory override")
	fs.StringVar(&e.libDir, "lib", "", "the bin/ holding jg-watch.sh")
	fs.StringVar(&e.procRoot, "proc", "", "procfs root, else /proc")
	fs.Int64Var(&now, "now", 0, "epoch seconds (replay)")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if now != 0 {
		e.now = func() int64 { return now }
	}
	rest := fs.Args()
	if len(rest) == 0 {
		fmt.Fprintln(errw, "usage: jg-wake-core [flags] dedupe <rows-file> | keys <kind> | queued <seq>... | count | "+
			"grant-valid <rows-file> | route|classify|realert|realert-record[-stdin] <kind> <key> [<payload>] | routing-files | "+
			"rule-set <name> <default> | digest [mark] | fleet-fp-record [file] | fleet-unchanged <file>")
		return 2
	}
	cmd, rest := rest[0], rest[1:]
	switch cmd {
	case "route-stdin", "classify-stdin", "realert-stdin", "realert-record-stdin":
		if len(rest) != 2 {
			fmt.Fprintf(errw, "jg-wake-core: %s takes <kind> <key> and payload on stdin\n", cmd)
			return 2
		}
		payload, err := io.ReadAll(os.Stdin)
		if err != nil {
			fmt.Fprintf(errw, "jg-wake-core: read payload: %v\n", err)
			return 2
		}
		cmd, rest = strings.TrimSuffix(cmd, "-stdin"), append(rest, string(payload))
	}
	switch cmd {
	case "dedupe":
		return one(rest, errw, "dedupe", "a rows file", func(a string) int { return e.dedupe(a, out, errw) })
	case "keys":
		return one(rest, errw, "keys", "a wake kind", func(a string) int { return e.keys(a, out, errw) })
	case "queued":
		return e.queued(rest, out, errw)
	case "count":
		return none(rest, errw, "count", func() int { return e.count(out, errw) })
	case "grant-valid":
		return one(rest, errw, "grant-valid", "a rows file", e.grantValid)
	case "route", "classify":
		return e.routeCommand(cmd, rest, out, errw)
	case "routing-files":
		return none(rest, errw, "routing-files", func() int {
			for _, f := range e.routingFiles() {
				fmt.Fprintln(out, f)
			}
			return 0
		})
	case "rule-set":
		if len(rest) != 2 {
			fmt.Fprintln(errw, "jg-wake-core: rule-set takes <name> <default>")
			return 2
		}
		def, err := strconv.ParseInt(rest[1], 10, 64)
		if err != nil {
			def = 0
		}
		fmt.Fprintln(out, e.ruleSet(rest[0], def))
		return 0
	case "digest":
		return e.digestDue(rest, out, errw)
	case "fleet-fp-record":
		if len(rest) > 1 {
			fmt.Fprintln(errw, "jg-wake-core: fleet-fp-record takes at most one file")
			return 2
		}
		file := e.fleetFingerprintFile()
		if len(rest) == 1 {
			file = rest[0]
		}
		if os.WriteFile(file, []byte(e.fleetFingerprint()+"\n"), 0o644) != nil {
			return 2
		}
		return 0
	case "fleet-unchanged":
		return one(rest, errw, "fleet-unchanged", "a fingerprint file", func(file string) int {
			if e.fleetUnchangedSince(file) {
				return 0
			}
			return 1
		})
	case "realert-record", "realert":
		return e.routeCommand("realert-record", rest, out, errw)
	}
	fmt.Fprintf(errw, "jg-wake-core: unknown command %q\n", cmd)
	return 2
}

// routeCommand answers the urgency commands, each of which takes <kind> <key> <payload>.
func (e env) routeCommand(cmd string, rest []string, out, errw io.Writer) int {
	if len(rest) != 3 {
		fmt.Fprintf(errw, "jg-wake-core: %s takes <kind> <key> <payload>\n", cmd)
		return 2
	}
	switch cmd {
	case "route":
		fmt.Fprintln(out, e.route(rest[0], rest[1], rest[2], 0))
	case "classify":
		fmt.Fprintln(out, e.classify(rest[0], rest[1], rest[2]))
	default:
		e.realertRecord(rest[0], rest[1], rest[2])
	}
	return 0
}

// one runs a command that takes exactly one argument.
func one(rest []string, errw io.Writer, cmd, what string, run func(string) int) int {
	if len(rest) != 1 {
		fmt.Fprintf(errw, "jg-wake-core: %s takes %s\n", cmd, what)
		return 2
	}
	return run(rest[0])
}

// none runs a command that takes no argument.
func none(rest []string, errw io.Writer, cmd string, run func() int) int {
	if len(rest) != 0 {
		fmt.Fprintf(errw, "jg-wake-core: %s takes no argument\n", cmd)
		return 2
	}
	return run()
}
