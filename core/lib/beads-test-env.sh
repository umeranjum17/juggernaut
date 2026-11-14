#!/usr/bin/env bash
# Sourced by a core test that needs a real Beads backlog in a fixture home. It skips plainly without the pinned
# bd and dolt (JG_BEADS_TEST_BD, JG_BEADS_TEST_DOLT) and puts the checkout's bin/ on PATH so jg-backlog.sh resolves.
# core_beads_home <checkout> <home> [<prefix>=jg]: a fresh store in <home>-store, named by <home>/config/beads-dir.
if [ -z "${JG_BEADS_TEST_BD:-}" ] || [ -z "${JG_BEADS_TEST_DOLT:-}" ]; then
  echo 'skip: JG_BEADS_TEST_BD and JG_BEADS_TEST_DOLT are unset'; exit 0
fi
export JG_BEADS_BD=$JG_BEADS_TEST_BD JG_BEADS_DOLT=$JG_BEADS_TEST_DOLT JG_TASK_PRIORITY_CHECK=/nonexistent
core_beads_home() {
  local fork=$1 home=$2 prefix=${3:-jg} store tpl
  store=$home-store
  # A fresh `bd init` costs seconds, and a suite builds a home per case. The first home per prefix initialises a
  # template beside the homes and every later one copies it, so the cost is paid once per suite.
  tpl=${home%/*}/.beads-template-$prefix
  if [ ! -d "$tpl/.beads" ]; then
    # A dolt that dies while it starts (a Go runtime fatal on a host short of threads or memory) leaves nothing half made: the
    # init is tried up to three times in a clean directory, and a final failure names the first lines of the crash, not its goroutine tail.
    for _try in 1 2 3; do
      rm -rf "$tpl.partial"
      mkdir -p "$tpl.partial"
      BEADS_DIR=$tpl.partial/.beads "$fork/bin/jg-beads.sh" init --prefix "$prefix" >/dev/null 2>"${TMPDIR:-/tmp}/beads-init.err" && break
      [ "$_try" -lt 3 ] || { echo "FAIL: could not initialise the Beads store for $home after 3 tries: $(head -3 "${TMPDIR:-/tmp}/beads-init.err" 2>/dev/null)"; exit 1; }
      sleep "$_try"
    done
    mv "$tpl.partial" "$tpl"
  fi
  mkdir -p "$home/config" "$home/data"
  rm -rf "$store"
  cp -a "$tpl" "$store" || { echo "FAIL: could not copy the Beads store for $home"; exit 1; }
  printf '%s\n' "$store/.beads" > "$home/config/beads-dir"
  : > "$home/config/backlog-intake-loose"
  case ":$PATH:" in *":$fork/bin:"*) ;; *) PATH=$fork/bin:$PATH; export PATH ;; esac
  [ -e "$home/toolchain.versions" ] || ln -sn "$fork/toolchain.versions" "$home/toolchain.versions"
}
