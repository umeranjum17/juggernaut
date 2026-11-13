#!/usr/bin/env bash
# Queues split by tests (slice H29e): sourced by core/trunk-landing/trunk-landing.sh, never run.
#
# Two ready lanes that change files whose tests share no script need not wait for each other's gate. A lane's selection is the list of
# scripts the project's own selector names for its one commit (bin/jg-test-run.sh --changed --base HEAD^ --list, the selector the
# sealed-run check of bin/jg-trunk.sh reads too). Lanes whose selections share no script go in separate queues. Each queue has its own
# chain of fronts (JG_TRUNK_QUEUE, bin/jg-trunk.sh) and its own stack; the trunk still moves by the one compare-and-swap of
# bin/jg-trunk.sh, so a queue that finds the trunk moved is rebased and gated again, as any lane is.
#   A lane whose selection meets one queue is in that queue.
#   A lane whose selection meets two queues is in both: it waits until one of them has ended, so it is never gated beside either.
#   A lane whose selection cannot be named (the project has no selector, or it failed) meets every queue: it is the one-queue rule that
#   ran before this slice, so a project with no selector is unchanged.
# The selection of a lane head is read once, in a throwaway clone, and kept in $MEM/<task>.<head>.selection (one script per line, or `*`).
# A running lane keeps its queue in $MEM/<task>.<head>.queue (the queue name) until its run ends.
# Needs from the caller: MEM, and the host's `git`. Reads nothing else of the home.

PARTITION_ALL='*'

# partition_selection <project dir> <task> <head>: prints the selection, one script per line, or `*` when it cannot be named.
partition_selection() {
  local proj=$1 id=$2 head=$3 tmp out f; f="$MEM/$id.$head.selection"
  if [ -s "$f" ]; then cat "$f"; return 0; fi
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/jg-partition-XXXXXX") || { echo "$PARTITION_ALL"; return 0; }
  out=$(
    git -C "$proj" cat-file -e "$head:bin/jg-test-run.sh" 2>/dev/null || exit 1
    env -i PATH="$PATH" HOME="${HOME:-/}" git clone -q --shared --no-checkout "$proj" "$tmp/tree" 2>/dev/null || exit 1
    env -i PATH="$PATH" HOME="${HOME:-/}" git -C "$tmp/tree" checkout -q --detach "$head" 2>/dev/null || exit 1
    cd "$tmp/tree" || exit 1
    env -i PATH="$PATH" HOME="${HOME:-/}" timeout 120 bash bin/jg-test-run.sh --changed --base HEAD^ --list 2>/dev/null | grep -E '^[^[:space:]]+\.sh$' | sort -u
  ) || out=
  rm -rf -- "$tmp"
  # A selector that names nothing for a change that has files is the same as one that cannot name it: the lane meets every queue.
  [ -n "$out" ] || out=$PARTITION_ALL
  printf '%s\n' "$out" > "$f.tmp.$$" && mv -f -- "$f.tmp.$$" "$f"
  printf '%s\n' "$out"
}

# partition_assign <max queues>: reads, on stdin, in this order
#   Q <queue> <script,script,... | *>     a queue that is running now (one line per running lane; a queue may repeat)
#   C <task> <script,script,... | *>      a ready lane, oldest first
# and prints, for each ready lane, `<task> <queue>` (a queue that runs now, or a new queue named by its first lane) or `<task> wait`
# (it meets two queues, or every queue slot is taken, or it meets a lane that is waiting ahead of it).
partition_assign() {
  awk -v max="$1" '
    function meets(a, b,    n, i, xs) {
      if (a == "*" || b == "*") return 1
      n = split(a, xs, ",")
      for (i = 1; i <= n; i++) if (index("," b ",", "," xs[i] ",")) return 1
      return 0
    }
    function join(a, b,    n, i, xs, out) {
      if (a == "*" || b == "*") return "*"
      out = a; n = split(b, xs, ",")
      for (i = 1; i <= n; i++) if (!index("," out ",", "," xs[i] ",")) out = out "," xs[i]
      return out
    }
    $1 == "Q" { if (!($2 in sel)) { nq++; order[nq] = $2; sel[$2] = $3 } else sel[$2] = join(sel[$2], $3); next }
    $1 == "C" {
      id = $2; s = $3; hits = 0; hit = ""
      for (i = 1; i <= nq; i++) if (meets(sel[order[i]], s)) { hits++; if (hit == "") hit = order[i] }
      blocked = (held != "" && meets(held, s))
      if (blocked || hits >= 2) { print id, "wait"; held = (held == "" ? s : join(held, s)); next }
      if (hits == 1) { sel[hit] = join(sel[hit], s); print id, hit; next }
      if (nq >= max) { print id, "wait"; held = (held == "" ? s : join(held, s)); next }
      nq++; order[nq] = id; sel[id] = s; print id, id
    }'
}

# partition_record <task> <head> <queue> / partition_forget <task> <head>: the running lane keeps its queue name, and gives it back when its run ends.
partition_record() { printf '%s\n' "$3" > "$MEM/$1.$2.queue.tmp.$$" && mv -f -- "$MEM/$1.$2.queue.tmp.$$" "$MEM/$1.$2.queue"; }
partition_forget() { rm -f -- "$MEM/$1.$2.queue"; }
partition_queue_of() { cat "$MEM/$1.$2.queue" 2>/dev/null || true; }  # <task> <head>: the queue a lane runs in, empty for none

# partition_scripts <task> <head>: the selection of a lane as one comma-joined word, read from its record (`*` when it has none).
partition_scripts() {
  local s; s=$(paste -sd, "$MEM/$1.$2.selection" 2>/dev/null || true)
  printf '%s\n' "${s:-$PARTITION_ALL}"
}
