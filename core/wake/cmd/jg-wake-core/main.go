// jg-wake-core is the Go half of the wake library: the decisions bin/jg-wake-lib.sh used to make in
// shell, answered here so one implementation owns them. This slice owns the read model of the wake
// queue - what a queued row is, which rows an actor could act on, and which of a list of sequence
// numbers are still queued. Every command reads the rendered rows and never the bus: the store and
// its fold stay with bin/jg-wake-bus.sh and core/bus.
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
// Flags give the call the queue and the grant the shell library resolved: --queue (state/.wake-queue),
// --actor (main or branch) and --grant (the branch grant's row snapshot). Nothing here reads the
// environment. A missing queue file answers "no rows", which is what the file behaviour did.
package main

import (
	"flag"
	"fmt"
	"io"
	"os"
)

func main() { os.Exit(run(os.Args[1:], os.Stdout, os.Stderr)) }

// env is what one call needs, resolved from the flags the shell library passes.
type env struct {
	queue string
	actor string
	grant string
}

func run(args []string, out, errw io.Writer) int {
	var e env
	fs := flag.NewFlagSet("jg-wake-core", flag.ContinueOnError)
	fs.SetOutput(errw)
	fs.StringVar(&e.queue, "queue", "", "the read model of the queue (state/.wake-queue)")
	fs.StringVar(&e.actor, "actor", "main", "who is asking: main or branch")
	fs.StringVar(&e.grant, "grant", "", "the branch grant's row snapshot, when one is live")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	rest := fs.Args()
	if len(rest) == 0 {
		fmt.Fprintln(errw, "usage: jg-wake-core [--queue FILE] [--actor main|branch] [--grant FILE] dedupe <rows-file> | keys <kind> | queued <seq>... | count | grant-valid <rows-file>")
		return 2
	}
	cmd, rest := rest[0], rest[1:]
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
	}
	fmt.Fprintf(errw, "jg-wake-core: unknown command %q\n", cmd)
	return 2
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
