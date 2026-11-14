#!/usr/bin/env bash
# jg-contract-carrier.sh - how a home's primary session gets the supervisor contract from a file of its own.
#
# Usage: jg-contract-carrier.sh contract           print the contract file, relative to the home root
#        jg-contract-carrier.sh path <harness>     print the carrier file of that harness (no output and exit 1 when its row has none)
#        jg-contract-carrier.sh check <harness>    print the proof the contract is in the session after a compaction:
#                                                  file    the harness loads the carrier file by itself, at the start and after a compaction
#                                                  reemit  session start runs again after a compaction and its output holds the contract
#                                                  none    neither
#        jg-contract-carrier.sh ensure <harness>   make a `file` row true: write the carrier file with its one import line
#
# The table below is the one owner of the proofs: one row per verified primary harness. A harness that is
# not in it, such as `unknown`, reads `none`. `check` prints `file` only when the carrier file is in the home
# root and holds the import line; before that a row with a candidate file reads its base proof (the report
# data/fable-thin-context/report.md section 6.2: claude is `reemit` until one run of the candidate).
# A harness row that reads `none` has no tracked channel after a compaction (docs/sessionstart-nudge.md).
#
# ensure: prints nothing when the file already holds the line or the row has no candidate file. It appends
# the line to an existing file and never rewrites other text in it. It prints one line and exits 3 when it
# had to write: the session that is starting did not load that file, so session start still prints the
# contract in its digest this once. It writes nothing, says why on one line and exits 0 for a harness that
# is not in the table and for a home above a worker copy (the code root is not the home root). It exits 1
# when the write fails.
#
# bin/jg-session-start.sh calls `ensure` at each start (only when it holds the lock) and `check`; when `check`
# does not print `file` the digest prints the contract, so no primary holds a core file alone.
# Environment: JG_HOME (the home root; default the code root), JG_ROOT_OVERRIDE (the code root).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODE_ROOT="${JG_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
HOME_ROOT="${JG_HOME:-$CODE_ROOT}"

# harness  base-proof  carrier-file ("-" holds none)
TABLE='
claude    reemit  CLAUDE.local.md
pi        reemit  -
pi-signed reemit  -
omp       reemit  -
codex     none    -
cursor    none    -
opencode  none    -
grok      none    -
kimi      none    -
'

row() {  # <harness>: "<base> <file>" or nothing
  printf '%s\n' "$TABLE" | awk -v h="$1" '$1 == h { print $2, $3; exit }'
}

# The contract today is the whole AGENTS.md; once the supervisor contract has its own file it is that file.
contract() {
  if [ -f "$CODE_ROOT/docs/contract/supervisor.md" ]; then
    printf 'docs/contract/supervisor.md\n'
  else
    printf 'AGENTS.md\n'
  fi
}

import_line() { printf '@%s\n' "$(contract)"; }

carrier_file() {  # <harness>: the file name of its row, or nothing
  local r file
  r=$(row "$1")
  file=${r#* }
  { [ -n "$r" ] && [ "$file" != - ]; } && printf '%s\n' "$file"
  return 0
}

holds_line() {  # <path>
  [ -f "$1" ] && [ ! -L "$1" ] && grep -Fxq -- "$(import_line)" "$1" 2>/dev/null \
    && [ -f "$HOME_ROOT/$(contract)" ]
}

cmd=${1:-}
harness=${2:-}
case "$cmd" in
  contract)
    contract
    ;;
  path)
    file=$(carrier_file "$harness")
    [ -n "$file" ] || exit 1
    printf '%s/%s\n' "$HOME_ROOT" "$file"
    ;;
  check)
    r=$(row "$harness")
    [ -n "$r" ] || { printf 'none\n'; exit 0; }
    file=$(carrier_file "$harness")
    if [ -n "$file" ] && holds_line "$HOME_ROOT/$file"; then
      printf 'file\n'
    else
      printf '%s\n' "${r%% *}"
    fi
    ;;
  ensure)
    if [ -z "$(row "$harness")" ]; then
      printf 'jg-contract-carrier: harness %s is not in the table; wrote nothing, the digest holds the contract\n' "${harness:-unknown}"
      exit 0
    fi
    file=$(carrier_file "$harness")
    [ -n "$file" ] || exit 0
    if [ "$(cd "$CODE_ROOT" && pwd -P)" != "$(cd "$HOME_ROOT" 2>/dev/null && pwd -P)" ]; then
      printf 'jg-contract-carrier: this is a worker copy above the home root, not a home; wrote nothing, the digest holds the contract\n'
      exit 0
    fi
    target=$HOME_ROOT/$file
    holds_line "$target" && exit 0
    [ ! -L "$target" ] || { printf 'jg-contract-carrier: %s is a symlink; wrote nothing\n' "$file"; exit 1; }
    [ -f "$HOME_ROOT/$(contract)" ] || { printf 'jg-contract-carrier: %s is absent; wrote nothing\n' "$(contract)"; exit 1; }
    if ! printf '%s\n' "$(import_line)" >> "$target" 2>/dev/null; then
      printf 'jg-contract-carrier: could not write %s\n' "$target"
      exit 1
    fi
    printf 'jg-contract-carrier: wrote %s with the contract import (%s)\n' "$file" "$(import_line)"
    exit 3
    ;;
  -h|--help|'')
    sed -n '2,/^set -u$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//; $d'
    [ -n "$cmd" ] || exit 2
    ;;
  *)
    printf 'jg-contract-carrier: unknown command: %s\n' "$cmd" >&2
    exit 2
    ;;
esac
