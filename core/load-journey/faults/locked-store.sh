# shellcheck shell=bash
# Fault: a backlog writer died between creating the lock and writing its token, so every backlog write fails LOCKED.
# Owner of the recovery: core/backlog-lock-reclaim (the home's watcher check). Sourced by bin/jg-load-journey.sh.
fault_inject() {  # <home> <lane>
  : > "$1/data/backlog.md.lock"
  touch -d '10 minutes ago' "$1/data/backlog.md.lock"
}
fault_recover() {  # <home>: one run of the check, as the watcher runs it
  JG_BACKLOG_LOCK_SAFE_AGE_S=60 "$JGL_ROOT/core/backlog-lock-reclaim/backlog-lock-reclaim.check.sh" "$1"
}
fault_recovered() {  # <home> <lane>: the lock is gone, so a backlog write can take it again
  [ ! -e "$1/data/backlog.md.lock" ]
}
