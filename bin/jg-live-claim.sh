#!/usr/bin/env bash
# jg-live-claim.sh - the "fixed means live" rule: a report that a user-visible
# change is fixed or done carries the released version that is running and where
# it is observable, or it says plainly that the change is merged but not
# released.
# The verdict is decided from the claim's own words and a recorded release state.
# Nothing here calls a model, a forge, or the network.
# jg_dod_block (bin/jg-dod-lib.sh) hands the rule to every generated ship brief,
# bin/jg-squad-lead-report.sh applies it to a lead's parent report, and
# bin/jg-branch-report.sh applies it to the supervision branch's captain-facing
# summary; this header is the single owner of the rule and of the record format.
# Usage: jg-live-claim.sh <verb> <claim>
#   Prints the claim to keep, followed by a newline.
#   Exit 0 when the claim stands as written.
#   Exit 3 when it was downgraded, with the reason and the next step on stderr.
#   Exit 2 on misuse.
#
# The rule fires on the completion verb `done` whose claim says a fix happened:
# fixed, fixes, now works, works now, is live, live now, resolved, shipped,
# deployed, released, or is done.
# Any other verb, and a claim that says none of those, is printed untouched, so
# an ordinary report such as `done: PR <url>` never needs this vocabulary.
#
# A claim the rule fires on stands as written when it already says the truth:
#   - `merged-not-released`, or `not released`: it states the plain position.
#   - `screen: none`: the change has no user-visible screen to observe.
#   - `live: <ref> @ <where>`: a released ref and the place it is observable,
#     where the release record names <ref>, and that names the PRs the release
#     carries (`carries: #12 #15`) and the open PRs that wait for the next
#     release (`waiting: #20`, or `waiting: none`).
# Anything else is downgraded to `merged-not-released: <claim>`, so a merged
# change can never reach the captain as a fix he can already use.
#
# Release record: `${JG_DATA_OVERRIDE:-$JG_HOME/data}/releases`, or the path in
# JG_RELEASES_FILE.
# One release per line, `#` starts a comment line, and the first field is the
# released ref: a version tag, or a commit id, where a claimed commit id of 7 or
# more characters also matches a record whose ref starts with it.
# An absent, unreadable, or silent record proves no release, so a ref it does not
# name is downgraded rather than accepted.
# A record line may carry an optional `prs=12,15` field anywhere after the ref:
# the PR numbers that release carries.
# The waiting list is every task record `$STATE/*.meta` with a `pr=` URL whose
# `<id>.pr-poll-merge-notified` marker is absent (the PR is not merged) and
# whose number no release record carries; nothing here asks the forge.
# A live claim that omits `carries:` or `waiting:` is flagged: stdout is the
# claim extended with the missing clause from those records, stderr names each
# omission, and the exit is 3, so a caller that prints stdout prints the whole
# claim.
# A record with no `prs=` field cannot say what it carries, so the extension
# reads `carries: unrecorded`.
# A release is live only when its services run: a `live:` claim that the record
# supports also needs bin/jg-live-services.sh to pass on this machine, and is
# downgraded with the down services named when any required one is not running.
set -u

die() { printf 'jg-live-claim: %s\n' "$*" >&2; exit 2; }

keep_as_written() { printf '%s\n' "$claim"; exit 0; }

# A fix claim the rule applies to: a completion verb that says something changed.
claim_reports_a_fix() {  # <verb> <claim>
  [ "$1" = 'done' ] || return 1
  printf '%s\n' "$2" | grep -Ewi -e 'fixed' -e 'fixes' -e 'now works' -e 'works now' \
    -e 'is live' -e 'live now' -e 'resolved' -e 'shipped' -e 'deployed' \
    -e 'released' -e 'is done' >/dev/null
}

claim_states_the_truth() {  # <claim>
  if printf '%s\n' "$1" | grep -Eqi -e 'merged[ -]not[ -]released' -e 'not released'; then
    return 0
  fi
  printf '%s\n' "$1" | grep -Eqi '(^|[[:space:]])screen:[[:space:]]*none([[:space:]]|$)'
}

released_ref_in_claim() {  # <claim> -> the ref named by a `live:` clause, or nothing
  printf '%s\n' "$1" | sed -n 's/.*[Ll]ive:[[:space:]]*\([^[:space:]@][^[:space:]@]*\).*/\1/p' | tail -n 1
}

observation_in_claim() {  # <claim> -> the text after `@`, or nothing
  printf '%s\n' "$1" | sed -n 's/.*[Ll]ive:[^@]*@[[:space:]]*\(..*\)/\1/p' | tail -n 1
}

ref_is_recorded() {  # <ref>
  local ref=$1
  [ -n "$ref" ] && [ -r "$releases" ] || return 1
  awk -v r="$ref" '
    /^[[:space:]]*#/ { next }
    NF == 0 { next }
    $1 == r { hit = 1 }
    r ~ /^[0-9a-f]+$/ && length(r) >= 7 && index($1, r) == 1 { hit = 1 }
    END { exit(hit ? 0 : 1) }
  ' "$releases"
}

record_prs_for_ref() {  # <ref> -> `#N #M` from the matching record's prs= field
  local ref=$1
  [ -r "$releases" ] || return 0
  awk -v r="$ref" '
    /^[[:space:]]*#/ { next }
    NF == 0 { next }
    $1 == r || (r ~ /^[0-9a-f]+$/ && length(r) >= 7 && index($1, r) == 1) {
      for (i = 2; i <= NF; i++) if ($i ~ /^prs=/) {
        v = $i; sub(/^prs=/, "", v); gsub(/#/, "", v); n = split(v, p, ",")
        for (j = 1; j <= n; j++) if (p[j] ~ /^[0-9]+$/) printf "%s#%s", (k++ ? " " : ""), p[j]
        print ""; exit
      }
    }
  ' "$releases"
}

waiting_prs() {  # -> `#N #M` of recorded open PRs no release carries
  local state=${JG_STATE_OVERRIDE:-${JG_HOME:-}/state} meta id url n out='' carried=''
  [ -r "$releases" ] && carried=$(awk '/^[[:space:]]*#/ { next } { for (i = 2; i <= NF; i++) if ($i ~ /^prs=/) { v = $i; sub(/^prs=/, "", v); gsub(/#/, "", v); gsub(/,/, " ", v); print v } }' "$releases")
  for meta in "$state"/*.meta; do
    [ -f "$meta" ] || continue
    id=${meta##*/}; id=${id%.meta}
    [ -e "$state/$id.pr-poll-merge-notified" ] && continue
    url=$(sed -n 's/^pr=//p' "$meta" | tail -n 1)
    n=${url##*/}
    case "$n" in ''|*[!0-9]*) continue ;; esac
    printf '%s\n' "$carried" | tr ' ' '\n' | grep -qx "$n" && continue
    case " $out " in *" #$n "*) continue ;; esac
    out="$out #$n"
  done
  printf '%s\n' "${out# }"
}

claim_names() {  # <claim> <word>
  printf '%s\n' "$1" | grep -Eqi "(^|[^[:alnum:]_])$2:"
}

downgrade() {  # <claim>
  printf 'merged-not-released: %s\n' "$1"
  printf '%s\n' 'jg-live-claim: downgraded to merged-not-released: release it and name the released version and where it is observable (live: <ref> @ <where>), or report it as merged-not-released.' >&2
  exit 3
}

[ "$#" -eq 2 ] || die 'usage: jg-live-claim.sh <verb> <claim>'
verb=${1%:}
claim=$2

claim_reports_a_fix "$verb" "$claim" || keep_as_written
claim_states_the_truth "$claim" && keep_as_written

releases=${JG_RELEASES_FILE:-}
if [ -z "$releases" ]; then
  data_dir=${JG_DATA_OVERRIDE:-${JG_HOME:-}/data}
  releases=$data_dir/releases
fi
ref=$(released_ref_in_claim "$claim")
where=$(observation_in_claim "$claim")
if [ -n "$ref" ] && [ -n "$where" ] && ref_is_recorded "$ref"; then
  svc_script=${JG_LIVE_SERVICES_BIN:-${0%/*}/jg-live-services.sh}
  if [ ! -x "$svc_script" ]; then keep_as_written; fi
  if svc_out=$("$svc_script" --quiet 2>&1); then
    extended=$claim
    if ! claim_names "$claim" carries; then
      carried=$(record_prs_for_ref "$ref")
      extended="$extended; carries: ${carried:-unrecorded}"
      printf 'jg-live-claim: the live claim does not name the PRs release %s carries (carries: #N ...); ' "$ref" >&2
      if [ -n "$carried" ]; then printf 'added from the release record.\n' >&2
      else printf 'the release record has no prs= field for it.\n' >&2; fi
    fi
    if ! claim_names "$claim" waiting; then
      waiting=$(waiting_prs)
      extended="$extended; waiting: ${waiting:-none}"
      printf 'jg-live-claim: the live claim does not name the open PRs that wait for the next release (waiting: #N ... or waiting: none); added from the task records.\n' >&2
    fi
    printf '%s\n' "$extended"
    [ "$extended" = "$claim" ] && exit 0
    exit 3
  fi
  printf 'merged-not-released: %s\n' "$claim"
  printf 'jg-live-claim: release %s is recorded but not live: %s. Bring the services up (bin/jg-stack.sh up), then claim it live.\n' "$ref" "$(printf '%s' "$svc_out" | tail -n 1)" >&2
  exit 3
fi

downgrade "$claim"
