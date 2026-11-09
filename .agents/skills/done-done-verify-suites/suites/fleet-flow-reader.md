# Fleet flow reader

Fleet flow reader: run `JG_BIN=<Juggernaut bin/> bash core/fleet-flow/tests/jg-flow.test.sh` for the isolated two-home journey. Lookout consumes the reader's JSON directly. On a live home, time `JG_HOME=<home> fleet-flow/bin/jg-flow.sh --json --capacity` read-only and compare its status-line fields with the fork library's command-substitution forms over every `state/*.status` line.
