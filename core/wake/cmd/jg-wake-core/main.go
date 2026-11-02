// jg-wake-core is the Go half of the wake library: the decisions bin/jg-wake-lib.sh used to make in
// shell, answered here so one implementation owns them. This slice owns wake urgency routing, the
// rule files (a home's config/wake-routing read first, then defaults/wake-routing, or JG_WAKE_ROUTING
// alone) that give every event the class now, batch or silent.
//
//	jg-wake-core [flags] route <kind> <key> <payload>
//	    print the event's class. The first matching rule wins across the rule files and no match
//	    prints `now`, so a missing rule file never hides an event. A `<task>.status` key is matched
//	    against the newest line of that status file. A class may carry `@condition`: parked (a lane
//	    of a parked home), restart-pass (a lead Main's restart pass just restarted), queue-quiet (no
//	    queued row routes to `now`) or watcher-alive (a live watcher holds this home's watcher lock).
//	jg-wake-core [flags] classify <kind> <key> <payload>
//	    the class jg_wake_append_locked acts on: route, then a repeated `now` event inside the
//	    re-alert window and a `silent` event past the hourly cap both become `batch`. A status row's
//	    identity is its newest line, so a repeated outcome line never wakes twice while a new line
//	    always does. Counting a settled event against the cap writes state/.wake-silenced. key and
//	    payload are already cleaned of tabs and newlines.
//	jg-wake-core [flags] realert <kind> <key> <payload>
//	    record a delivered `now` event in state/.wake-realert for the re-alert window.
//	jg-wake-core [flags] routing-files
//	    print the rule files in force, in priority order, one per line.
//
// Flags give the home the shell library resolved: --state, --home, --root (the checkout holding
// defaults/), --queue (state/.wake-queue), --routing (JG_WAKE_ROUTING), --config (JG_CONFIG_OVERRIDE),
// --lib (JG_WAKE_LIB_DIR), --proc (JG_PROC_ROOT_OVERRIDE) and --now (epoch seconds, for a replay).
// Nothing here reads the environment.
//
// Exit 0 with the answer on stdout, 2 for a request that is not valid.
package main

import (
	"flag"
	"fmt"
	"os"
)

func main() { os.Exit(run(os.Args[1:])) }

func run(args []string) int {
	fs := flag.NewFlagSet("jg-wake-core", flag.ContinueOnError)
	var e env
	var now int64
	fs.StringVar(&e.state, "state", "", "state directory")
	fs.StringVar(&e.home, "home", "", "home directory")
	fs.StringVar(&e.defaultRoot, "root", "", "checkout holding defaults/")
	fs.StringVar(&e.queue, "queue", "", "wake queue read model")
	fs.StringVar(&e.routing, "routing", "", "override rule file")
	fs.StringVar(&e.configDir, "config", "", "config directory override")
	fs.StringVar(&e.lib, "lib", "", "bin directory holding jg-watch.sh")
	fs.StringVar(&e.procRoot, "proc", "/proc", "proc filesystem root")
	fs.Int64Var(&now, "now", 0, "epoch seconds (replay)")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if now != 0 {
		e.now = func() int64 { return now }
	}
	rest := fs.Args()
	if len(rest) == 0 {
		fmt.Fprintln(os.Stderr, "usage: jg-wake-core [flags] route|classify|realert <kind> <key> <payload> | routing-files")
		return 2
	}
	cmd, rest := rest[0], rest[1:]
	switch cmd {
	case "route", "classify", "realert":
		if len(rest) != 3 {
			fmt.Fprintf(os.Stderr, "jg-wake-core: %s takes <kind> <key> <payload>\n", cmd)
			return 2
		}
		switch cmd {
		case "route":
			fmt.Println(e.route(rest[0], rest[1], rest[2], 0))
		case "classify":
			fmt.Println(e.classify(rest[0], rest[1], rest[2]))
		default:
			e.realertRecord(rest[0], rest[1], rest[2])
		}
	case "routing-files":
		for _, f := range e.ruleFiles() {
			fmt.Println(f)
		}
	default:
		fmt.Fprintf(os.Stderr, "jg-wake-core: unknown command %q\n", cmd)
		return 2
	}
	return 0
}
