#!/usr/bin/env bash
# jg-contract-carrier.sh - how a home's primary session gets the supervisor contract from a file of its own.
#
# Usage: jg-contract-carrier.sh contract           print the contract file, relative to the home root
#        jg-contract-carrier.sh path <harness>     print the carrier file of that harness (no output and exit 1 when its row has none)
#        jg-contract-carrier.sh check <harness>    print the proof the contract is in the session after a compaction:
#                                                  file    the harness loads the carrier file by itself, at the start and after a compaction
#                                                  reemit  session start runs again after a compaction and its output holds the contract
#                                                  none    neither
#        jg-contract-carrier.sh ensure <harness>   make a `file` row true: write the carrier file (an import line, or a copy of the core file)
#
# The table below is the one owner of the proofs: one row per verified primary harness. A harness that is
# not in it, such as `unknown`, reads `none`. `check` prints `file` only when the carrier file is in the home
# root and holds what its kind names; before that a row with a candidate file reads its base proof (the report
# data/fable-thin-context/report.md section 6.2: claude is `reemit` until one run of the candidate).
# A row has one of two kinds of carrier file:
#   import  the file holds one import line naming the contract file (claude: CLAUDE.local.md expands it)
#   copy    the file holds a copy of the core file AGENTS.md under one marker line, because the harness does not
#           expand an import (codex, lab thin-tc5-codex: AGENTS.override.md holding `@AGENTS.md` was not read,
#           the same text written directly was). The copy must fit the harness's default read limit of 32 KiB;
#           a larger core file is not copied and the row keeps its base proof.
#   native  the harness reads the core file AGENTS.md itself and ensure writes no file (cursor, lab thin-tc5-cursor:
#           AGENTS.md was read, an @import in CLAUDE.local.md was not expanded, a .cursor/rules file with no front
#           matter was not read). Whether it stays in the session after a compaction is not proven (print mode has
#           none), so the row keeps its base proof `reemit` and the digest still prints the contract.
# A harness row that reads `none` has no tracked channel after a compaction (docs/sessionstart-nudge.md).
#
# ensure: prints nothing when the file already holds what its kind names or the row has no candidate file.
# An import file gets its line appended and no other text in it is rewritten. A copy file is written whole
# when it is absent or starts with the marker line (a stale copy is refreshed); a file with other text, a
# symlink, or a core file over the limit is left alone and ensure says why on one line. It prints one line
# and exits 3 when it had to write: the session that is starting did not load that file, so session start still prints the
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

# harness  base-proof  carrier-file ("-" holds none)  kind (import, copy or native)
TABLE='
claude    reemit  CLAUDE.local.md      import
pi        reemit  -
pi-signed reemit  -
omp       reemit  -
codex     none    AGENTS.override.md   copy
cursor    reemit  -                    native
opencode  file    -                    native
grok      reemit  -                    native
kimi      reemit  -                    native
agy       reemit  -                    native
'

COPY_LIMIT=32768  # the default read limit of a Codex instruction file, in bytes
COPY_MARKER='<!-- jg-contract-carrier: copy of AGENTS.md; ensure rewrites this file, edit AGENTS.md instead -->'

row() {  # <harness>: "<base> <file> <kind>" or nothing
  printf '%s\n' "$TABLE" | awk -v h="$1" '$1 == h { print $2, $3, ($4 == "" ? "-" : $4); exit }'
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
  local file kind
  read -r _ file kind <<< "$(row "$1")"
  { [ -n "${file:-}" ] && [ "$file" != - ]; } && printf '%s\n' "$file"
  return 0
}

carrier_kind() {  # <harness>: the kind of its row's file
  local kind
  read -r _ _ kind <<< "$(row "$1")"
  printf '%s\n' "${kind:--}"
}

core_file() { printf '%s/AGENTS.md\n' "$HOME_ROOT"; }

copy_fits() {  # the core file plus its marker line fit the read limit
  [ -f "$(core_file)" ] && [ $(( $(wc -c < "$(core_file)") + ${#COPY_MARKER} + 1 )) -le "$COPY_LIMIT" ]
}

copy_is_ours() {  # <path>: a regular file that starts with the marker line
  [ -f "$1" ] && [ ! -L "$1" ] && [ "$(head -n 1 "$1" 2>/dev/null)" = "$COPY_MARKER" ]
}

write_copy() {  # <path>
  { printf '%s\n' "$COPY_MARKER"; cat "$(core_file)"; } > "$1"
}

holds_line() {  # <path> <kind>: the file holds what its kind names
  case "$2" in
    import)
      [ -f "$1" ] && [ ! -L "$1" ] && grep -Fxq -- "$(import_line)" "$1" 2>/dev/null \
        && [ -f "$HOME_ROOT/$(contract)" ]
      ;;
    copy)
      copy_fits && copy_is_ours "$1" && tail -n +2 "$1" | cmp -s - "$(core_file)"
      ;;
    *) return 1 ;;
  esac
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
    if [ -n "$file" ] && holds_line "$HOME_ROOT/$file" "$(carrier_kind "$harness")"; then
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
    kind=$(carrier_kind "$harness")
    holds_line "$target" "$kind" && exit 0
    [ ! -L "$target" ] || { printf 'jg-contract-carrier: %s is a symlink; wrote nothing\n' "$file"; exit 1; }
    if [ "$kind" = copy ]; then
      [ -f "$(core_file)" ] || { printf 'jg-contract-carrier: AGENTS.md is absent; wrote nothing\n'; exit 1; }
      if ! copy_fits; then
        printf 'jg-contract-carrier: AGENTS.md is over the %s byte read limit of %s; wrote nothing, the digest holds the contract\n' "$COPY_LIMIT" "$file"
        exit 0
      fi
      if [ -e "$target" ] && ! copy_is_ours "$target"; then
        printf 'jg-contract-carrier: %s holds text this script did not write; wrote nothing\n' "$file"
        exit 1
      fi
      if ! write_copy "$target" 2>/dev/null; then
        printf 'jg-contract-carrier: could not write %s\n' "$target"
        exit 1
      fi
      printf 'jg-contract-carrier: wrote %s with a copy of AGENTS.md\n' "$file"
      exit 3
    fi
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
