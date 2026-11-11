#!/usr/bin/env bash
# Resolve a project's REGISTERED delivery posture from the data/projects.md registry.
# Default usage prints two words to stdout: "<mode> <yolo>" where mode is one of
# no-mistakes|direct-PR|local (or the old local-only|local-trunk, read as before) and yolo is on|off.
# --branch-prefix instead prints one value: the project's registered ship-branch
# prefix, "fm/" when the project registers none, is unregistered, or the registry
# is absent, so every existing installation keeps its current "fm/<task-id>"
# branch names unchanged.
# --kind <kind> beside --branch-prefix names the unregistered default by the kind
# of work: feature gives "feature/", bug or fix-like (bugfix, fix, hotfix, defect,
# regression) gives "fix/", and any other kind (chore, docs, test, ...) gives
# "chore/". A registry prefix always wins and no --kind keeps "fm/".
# --registered prints only an EXPLICIT registry prefix, and exits 1 with nothing
# when the project registers none, so bin/jg-spawn.sh does not report a
# kind-named branch as drifting from a prefix nobody registered.
#
# MECHANICAL CONSUMERS ONLY. This answers "what posture did the captain register
# for this project", never "how does this task ship". A task's delivery mode,
# yolo, and ship-branch prefix are resolved by juggernaut at intake and passed
# explicitly to bin/jg-brief.sh, bin/jg-spawn.sh, and bin/jg-promote.sh (AGENTS.md
# section 7 and the task-dispatch skill; bin/jg-brief.sh's own header owns the
# --branch-prefix flag it accepts).
# The consumers are bin/jg-fleet-sync.sh (skip local-only clones),
# bin/jg-bootstrap.sh (skip the GitHub-auth probe when every clone is local-only),
# bin/jg-home-seed.sh and bin/jg-remote-home-seed.sh (refuse local-only seeding,
# run no-mistakes init), bin/jg-spawn.sh's advisory registry-deviation notice,
# and --forge for bin/jg-spawn.sh's forge agreement and yolo refusal and for
# bin/jg-promote.sh, which takes the forge binding from here because it is a
# project fact rather than a task choice.
#
# Registry line format (data/projects.md):
#   - <name> - <desc> (added <date>)                                 -> no-mistakes off fm/  (legacy default)
#   - <name> [<mode>] - <desc> (added <date>)                        -> <mode> off fm/
#   - <name> [<mode> +yolo] - <desc> (added <date>)                  -> <mode> on fm/
#   - <name> [<mode> +yolo branch=<prefix>] - <desc> (added <date>)  -> <mode> <yolo> <prefix>
#   - <name> [<mode> forge=gerrit] - <desc> (added <date>)           -> <mode> off, --forge gerrit
#   - <name> [<mode> forge=forgejo] - <desc> (added <date>)          -> <mode> <yolo>, --forge forgejo
#   <name> may contain spaces; it ends at the literal " [" or " - " that follows it.
#   Bracket tokens are order-independent: +yolo, branch=<prefix>, and forge=<value>
#   are recognized by their own shape wherever they appear, and whichever token is
#   left over is the mode. <prefix> must not contain a space; an empty override
#   ("branch=") resolves to "" for a bare "<task-id>" ship branch instead of the
#   legacy "fm/<task-id>".
#
# Registered modes:
#   no-mistakes            full pipeline -> PR -> configured merge authority (default)
#   direct-PR              push + PR via gh-axi, no pipeline
#   local                  the one local style (core/machines/styles/delivery-styles.tsv): lanes land on the local trunk; yolo on lands them by
#                          itself, yolo off waits for the captain's word. Same trunk rules as local-trunk below.
#   local-only             local branch, no remote/PR, guarded local merge
#   local-trunk            the local trunk flow (docs/trunk-flow.md, bin/jg-trunk.sh): lanes ship as local-trunk
#                          tasks and land on a local trunk by themselves; goes live and out as ONE release PR
#                          only on the captain's word. Mechanical and --raw output both retain local-trunk.
#                          Every trunk rule applies to a local-trunk project ONLY: no-mistakes, direct-PR and
#                          local-only keep their own rules exactly as before.
#   no-mistakes-prod-only  a conditional policy, not a task mode: juggernaut
#                          classifies each task's surface at intake (the
#                          project-management skill owns that classification).
#                          Mechanical output maps it to its most rigorous leg,
#                          no-mistakes, so sync, seeding, and init treat such a
#                          project as the remote-backed pipeline project it is.
# yolo (orthogonal) = merge authority only: when on, juggernaut merges green,
#   in-scope work itself (AGENTS.md section 7).
# branch=<prefix> (orthogonal) = overrides the "fm/" ship-branch prefix so a
#   project's branch and PR do not read as juggernaut-authored, e.g. for a
#   third-party repo that does not use this tooling. Query it with
#   --branch-prefix; it never appears in the default "<mode> <yolo>" output, so
#   existing mechanical callers are unaffected by its presence.
# forge (orthogonal, and orthogonal to yolo too) = which forge the project's
#   remote actually is, never inferred from mode, remote name, host, or protocol.
#   `none` means a forge whose pull requests and checks no-mistakes already
#   drives, `gerrit` means a Gerrit server: no pull requests, so the worker
#   publishes a change with gerrit-axi instead, and `forgejo` means a Forgejo or
#   Gitea server, whose pull requests the worker handles with tea rather than
#   gh-axi (bin/jg-dod-lib.sh owns what each changes for a worker in each
#   publishing mode; docs/forgejo-tea-integration.md holds the tea evidence).
#   The binding is EXPLICIT because a provider family must never be guessed;
#   bin/jg-forge-detect.sh proposes gerrit from a protocol fact at project-add
#   intake, forgejo has no such fact and is proposed from the captain's own
#   account of the host, and the captain's confirmation is what this record holds.
#   A forge describes what a mode publishes, so it composes with no-mistakes and
#   direct-PR and is REFUSED on local-only, which publishes nothing: that mode
#   lands by fast-forwarding local main, which on a review-server project
#   advances it with content the server has never seen
#   (docs/gerrit-forge-integration.md section 3).
#
# A registered `forge=gerrit` project reports yolo=off with an explicit stderr
# refusal, on the captain's decision of 2026-09-15: a Gerrit Code-Review+2 is a
# positive attributed claim that a named human approved, read by colleagues and
# by any audit, and juggernaut must not manufacture one.
#
# --raw prints the registered mode annotation unmapped, so a caller that must
# tell a conditional policy apart from a flat mode sees "no-mistakes-prod-only"
# itself. Not combined with --branch-prefix, which has no conditional-policy leg.
#
# A project with no registry entry, or a home with no registry at all, falls
# back to "direct-PR off" (or "fm/" under --branch-prefix) and warns to stderr:
# a direct pull request with done-done proof is the default delivery route, and
# no-mistakes is chosen per project for real risk. An unknown mode in a
# registered line, and a legacy bracket-less line, still resolve to
# "no-mistakes off", so a typo or an older registry never silently drops a gate
# its owner registered. Other annotation tokens are ignored, as they always were, keyed
# ones included: a `<key>=<value>` token whose key is neither exactly `forge` nor
# `branch` resolves as it did before the forge existed, and in the mode slot it
# is read as an unknown mode. A key one or two edits from `forge` (such as
# `forg=` or `Forge=`) is still ignored, with one stderr warning naming the token
# and the forge=gerrit and forge=forgejo spellings. The one refusal is a
# malformed forge binding - a `forge=` token whose value is empty or outside the
# closed set - which is REFUSED in the default and --forge output forms: nothing
# on stdout, exit status 3, the token named. Resolving it to "no registered
# forge" would hand a Gerrit project the pull-request contract the binding
# exists to prevent.
# local-only with a forge is refused the same way. --branch-prefix does not make
# that check: it answers only the registered prefix, and a prefix is orthogonal
# to the forge binding, so it prints even when the forge token is malformed;
# every path that reads the forge binding (default, --forge, and spawn's
# forge-agreement check) still refuses.
# Usage: jg-project-mode.sh [--raw|--branch-prefix [--kind <kind>] [--registered]|--forge] <project-name>
# jg-compat (shim, slice S1; deleted by S10): old names still resolve.
_jg_d=${BASH_SOURCE[0]%/*}
[ "$_jg_d" != "${BASH_SOURCE[0]}" ] || _jg_d=.
if [ -r "$_jg_d/jg-compat.sh" ]; then
  # shellcheck source=bin/jg-compat.sh
  . "$_jg_d/jg-compat.sh"
else
  # A copy of this script with no compat file beside it (a test fixture) has no
  # legacy record to read, so every legacy reader answers "nothing legacy here".
  eval 'jg_compat_legacy_of() { printf "%s\n" "${1-}"; }
    jg_compat_legacy_product() { printf "%s\n" "${1-}"; }
    jg_compat_record_ok() { [ "${1-}" = "${2-}" ]; }
    jg_compat_label_ok() { [ -n "${1-}" ] && [ "${1-}" = "${2-}" ]; }
    jg_compat_marker() { printf "%s\n" "${1-}/.jg-squad-lead-home"; }
    jg_compat_parent_marker() { printf "%s\n" "${1-}/.jg-squad-lead-parent"; }
    jg_compat_claims_root() { printf "%s\n" "${1-}"; }
    jg_compat_pick() { printf "%s\n" "${1-}"; }
    jg_compat_kind() { printf "%s\n" "${1-}"; }
    jg_compat_meta_is_squad_lead() { grep -q "^kind=squad_lead\$" "${1-}" 2>/dev/null; }'
fi
unset _jg_d
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/jg-delivery-style.sh
. "$SCRIPT_DIR/jg-delivery-style.sh"
JG_ROOT="${JG_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
JG_HOME="${JG_HOME:-${JG_ROOT_OVERRIDE:-$JG_ROOT}}"
DATA="${JG_DATA_OVERRIDE:-$JG_HOME/data}"
REG="$DATA/projects.md"
RAW=0
BRANCH_PREFIX_QUERY=0
WANT_FORGE=0
KIND=
REGISTERED_ONLY=0
case "${1:-}" in
  --raw) RAW=1; shift ;;
  --branch-prefix)
    BRANCH_PREFIX_QUERY=1; shift
    while [ "$#" -gt 1 ]; do
      case "$1" in
        --kind) KIND=${2:-}; shift 2 ;;
        --registered) REGISTERED_ONLY=1; shift ;;
        *) break ;;
      esac
    done
    ;;
  --forge) WANT_FORGE=1; shift ;;
esac
NAME=${1:?usage: jg-project-mode.sh [--raw|--branch-prefix [--kind <kind>] [--registered]|--forge] <project-name>}

# The unregistered ship-branch prefix: "fm/" without a kind, else named by kind.
default_prefix() {
  local k
  k=$(printf '%s' "$KIND" | tr '[:upper:]' '[:lower:]' | tr -d '[]')
  case "$k" in
    '') echo "fm/" ;;
    feature) echo "feature/" ;;
    bug|bugfix|fix|hotfix|defect|regression) echo "fix/" ;;
    *) echo "chore/" ;;
  esac
}
# The prefix to print: a registered one wins; the sentinel means none was registered.
unset_prefix='(default prefix)'
prefix_answer() {  # <registered-or-sentinel>
  if [ "$1" != "$unset_prefix" ]; then
    echo "$1"
  elif [ "$REGISTERED_ONLY" -eq 0 ]; then
    default_prefix
  else
    return 1
  fi
}

if [ ! -f "$REG" ]; then
  echo "warn: no registry at $REG; defaulting $NAME to direct-PR off" >&2
  if [ "$BRANCH_PREFIX_QUERY" -eq 1 ]; then
    prefix_answer "$unset_prefix" || exit 1
  elif [ "$WANT_FORGE" -eq 1 ]; then echo none; else echo "direct-PR off"; fi
  exit 0
fi

# awk emits one "near <token>" line per keyed token whose key is a near miss of
# `forge`, then "posture <mode> <yolo> <branch-prefix> <forge>" (branch-prefix is
# the raw prefix, or "(default prefix)" when none is registered; forge is `none` or the whole `forge=<value>`
# token, so an empty value survives the split), or nothing if the project is
# absent. Every other token beside the mode is ignored, exactly as before either
# annotation existed.
parsed=$(awk -v n="$NAME" -v sentinel="$unset_prefix" '
  function dist(x, y,   i, j, lx, ly, d, c, v) {
    lx = length(x); ly = length(y);
    for (i=0; i<=lx; i++) d[i,0] = i;
    for (j=0; j<=ly; j++) d[0,j] = j;
    for (i=1; i<=lx; i++) for (j=1; j<=ly; j++) {
      c = (substr(x,i,1) == substr(y,j,1)) ? 0 : 1;
      v = d[i-1,j] + 1;
      if (d[i,j-1] + 1 < v) v = d[i,j-1] + 1;
      if (d[i-1,j-1] + c < v) v = d[i-1,j-1] + c;
      d[i,j] = v;
    }
    return d[lx,ly];
  }
  {
    # Exact whole-name match on the raw line text (never a regex, so a name
    # containing dots or brackets is compared literally): the line must start
    # with "- " n, and the text right after the name must be empty, or start
    # with " [" or " - ", so a name that is a leading prefix of a longer
    # registered name does not match that longer row.
    prefix = "- " n; plen = length(prefix);
    if (substr($0, 1, plen) != prefix) next
    after = substr($0, plen + 1);
    if (after != "" && substr(after, 1, 2) != " [" && substr(after, 1, 3) != " - ") next
    mode="no-mistakes"; yolo="off"; branch=sentinel; forge="none";
    if (substr(after, 1, 2) == " [") {
      s="";
      nk = split(after, rest, " ");
      for (i=1; i<=nk; i++) { s = s (s==""?"":" ") rest[i]; if (rest[i] ~ /\]$/) break }
      gsub(/^\[|\]$/, "", s);           # strip the surrounding brackets
      k = split(s, a, " ");
      # Tokens are order-independent: +yolo, branch=<prefix>, and forge=<value>
      # are recognized by their own shape wherever they appear, keyed tokens
      # that are neither are ignored (with a near-miss warning for the forge
      # spelling), and the first token left over is the mode.
      mode_set = 0
      for (j=1; j<=k; j++) {
        if (a[j]=="+yolo") { yolo="on"; continue }
        if (a[j] ~ /^branch=/) { branch = substr(a[j], 8); continue }
        if (a[j] ~ /^forge=/) { forge = a[j]; continue }
        if (a[j] ~ /^[^=]+=/) {
          key = substr(a[j], 1, index(a[j], "=") - 1);
          e = dist(key, "forge");
          if (e >= 1 && e <= 2) print "near", a[j];
          if (mode_set == 0) { mode = a[j]; mode_set = 1 }
          continue
        }
        if (a[j] != "" && mode_set == 0) { mode = a[j]; mode_set = 1 }
      }
    }
    # branch is printed LAST: an empty branch= override must survive as an
    # empty final field, which only holds when nothing follows it.
    print "posture", mode, yolo, forge, branch; exit
  }
' "$REG")

if [ -z "$parsed" ]; then
  echo "warn: project \"$NAME\" not in registry; defaulting to direct-PR off" >&2
  if [ "$BRANCH_PREFIX_QUERY" -eq 1 ]; then
    prefix_answer "$unset_prefix" || exit 1
  elif [ "$WANT_FORGE" -eq 1 ]; then echo none; else echo "direct-PR off"; fi
  exit 0
fi

posture=
while IFS=' ' read -r kind rest; do
  case "$kind" in
    near) echo "warn: ignoring \"$rest\" registered for $NAME in $REG; it is not a forge binding, and the forge binding is spelled forge=gerrit or forge=forgejo" >&2 ;;
    posture) posture=$rest ;;
  esac
done <<EOF
$parsed
EOF
while IFS=' ' read -r m y f b; do
  mode=$m; yolo=$y; rest_forge=$f; branch=$b
done <<EOF
$posture
EOF
forge=${rest_forge:-none}
case "$mode" in
  no-mistakes-prod-only) ;;
  *) jg_delivery_style_accepts "$mode" || { echo "warn: unknown mode \"$mode\" for $NAME; defaulting to no-mistakes off" >&2; mode=no-mistakes; yolo=off; branch=$unset_prefix; } ;;
esac
case "$yolo" in on|off) ;; *) yolo=off ;; esac
if [ "$BRANCH_PREFIX_QUERY" -eq 1 ]; then
  prefix_answer "$branch" || exit 1
  exit 0
fi

case "$forge" in
  none|forge=gerrit|forge=forgejo) forge=${forge#forge=} ;;
  forge=)
    echo "refused: empty forge binding \"forge=\" registered for $NAME in $REG; the accepted values are forge=gerrit and forge=forgejo, or no forge token at all for a forge whose pull requests no-mistakes already drives; correct the registry entry" >&2
    exit 3 ;;
  *)
    echo "refused: unknown forge \"${forge#forge=}\" registered for $NAME in $REG; the accepted values are forge=gerrit and forge=forgejo, or no forge token at all for a forge whose pull requests no-mistakes already drives; correct the registry entry" >&2
    exit 3 ;;
esac
if [ "$forge" != none ] && jg_delivery_style_is "$mode" local; then
  echo "refused: $NAME is registered $mode with forge=$forge in $REG; $mode publishes nothing, so a forge has no meaning there, and its landing would fast-forward local main with content the review server has never seen; register no-mistakes or direct-PR to publish through the forge, or drop the forge token to keep the project local" >&2
  exit 3
fi
if [ "$WANT_FORGE" -eq 1 ]; then
  echo "$forge"
  exit 0
fi
if [ "$forge" = gerrit ] && [ "$yolo" = on ]; then
  echo "refused: +yolo is registered for $NAME but yolo is inactive for forge=gerrit, so this reports yolo=off: a Gerrit Code-Review+2 is a positive attributed claim that a named human approved, and juggernaut must not manufacture one (captain's decision 2026-09-15)" >&2
  yolo=off
fi
# A conditional policy is not a task mode. Mechanical callers get its most
# rigorous leg; --raw callers get the annotation itself (see the header).
if [ "$RAW" -eq 0 ] && [ "$mode" = no-mistakes-prod-only ]; then
  mode=no-mistakes
fi
echo "$mode $yolo"
