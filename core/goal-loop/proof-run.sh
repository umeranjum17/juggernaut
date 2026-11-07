#!/usr/bin/env bash
# proof-run.sh <goal data dir> <jg-home> <seconds> <proof argv...>: run a Goal's proof detached, from the home.
# The check starts this and returns at once; a later pass reads <dir>/proof.exit. The log is <dir>/proof.log and
# the runner's pid is <dir>/proof.pid, so a runner that died without an exit file can be told from one still running.
set -u
dir=$1 home=$2 secs=$3
shift 3
echo $$ > "$dir/proof.pid"
rm -f "$dir/proof.exit"
(cd "$home" && exec timeout "$secs" "$@") > "$dir/proof.log" 2>&1 < /dev/null
echo $? > "$dir/proof.exit.tmp" && mv "$dir/proof.exit.tmp" "$dir/proof.exit"
