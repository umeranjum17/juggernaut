#!/usr/bin/env bash
# jg-gate-states.sh - print "<gate id><TAB><open|closed>" for every owner question in a home's store.
#
# Usage: jg-gate-states.sh <home>
# The status classifier (core/classify/cmd/jg-classify/gates.go) runs this through
# JG_CLASSIFY_GATE_STATES when a decision is open, to read a key that is a gate id from the gate, so a
# status line is never a second record of an owner call. Read-only. A home whose store serves no
# questions prints nothing and exits non-zero, and the classifier then reads the status log alone.
set -u
home=${1:?usage: jg-gate-states.sh <home>}
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
JG_HOME=$home "$here/jg-backlog.sh" questions --all --json 2>/dev/null | jq -er '.[] | [.id, .state] | @tsv'
