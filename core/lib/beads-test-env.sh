#!/usr/bin/env bash
# Sourced by a core test that needs a real Beads backlog in a fixture home. It skips plainly without the pinned
# bd and dolt (JG_BEADS_TEST_BD, JG_BEADS_TEST_DOLT) and puts the checkout's bin/ on PATH so jg-tasks-axi.sh resolves.
# core_beads_home <checkout> <home> [<prefix>=jg]: a fresh store in <home>-store, named by <home>/config/beads-dir.
if [ -z "${JG_BEADS_TEST_BD:-}" ] || [ -z "${JG_BEADS_TEST_DOLT:-}" ]; then
  echo 'skip: JG_BEADS_TEST_BD and JG_BEADS_TEST_DOLT are unset'; exit 0
fi
export JG_BEADS_BD=$JG_BEADS_TEST_BD JG_BEADS_DOLT=$JG_BEADS_TEST_DOLT JG_TASK_PRIORITY_CHECK=/nonexistent
core_beads_home() {
  local fork=$1 home=$2 prefix=${3:-jg} store
  store=$home-store
  mkdir -p "$home/config" "$home/data" "$store"
  BEADS_DIR=$store/.beads "$fork/bin/jg-beads.sh" init --prefix "$prefix" >/dev/null 2>"${TMPDIR:-/tmp}/beads-init.err" \
    || { echo "FAIL: could not initialise the Beads store for $home: $(tail -3 "${TMPDIR:-/tmp}/beads-init.err" 2>/dev/null)"; exit 1; }
  printf '%s\n' "$store/.beads" > "$home/config/beads-dir"
  : > "$home/config/backlog-intake-loose"
  case ":$PATH:" in *":$fork/bin:"*) ;; *) PATH=$fork/bin:$PATH; export PATH ;; esac
  [ -e "$home/toolchain.versions" ] || ln -s "$fork/toolchain.versions" "$home/toolchain.versions"
}
