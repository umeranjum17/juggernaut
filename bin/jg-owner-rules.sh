#!/usr/bin/env bash
# jg-owner-rules.sh - the shared owner-rules surface and the command that writes it.
#
# Usage:
#   jg-owner-rules.sh init [--force]
#   jg-owner-rules.sh add --kind owner --words "<the owner's own words>" \
#     --scope <scope> --enforce <where it is enforced> [--date YYYY-MM-DD] [--title <one line>]
#   jg-owner-rules.sh split [--surface <file>] [--apply]
#   jg-owner-rules.sh audit [--fail] [--source <file-or-directory>]...
#
# The surface is $DATA/owner-rules.md: one entry per standing owner decision,
# each carrying the owner's verbatim words, the date, the scope, the kind, and
# the code or contract that enforces it. It is the only shared home for an owner
# correction. bin/jg-session-start.sh prints it in every session's context
# digest, so every worker in every project reads it; a correction that lives in
# one agent's memory or notes instead is what `audit` exists to catch.
#
# Every entry carries a kind on its `- Kind:` line:
#   owner    the owner's own taste and authority, what only he decides: his
#            voice, his device and account limits, his focus order, no forecast
#            dates, the branch flow he chose, a design pick he must make.
#   product  an engineering default that is the same for every user of
#            Juggernaut: the delivery route, intake discipline, thin CI, the PR
#            waiting-for status, escalation batching and backoff, choke-point
#            alerts, prior art before new work.
# A product rule is not an owner rule, because its fix belongs to the product:
# AGENTS.md where an agent needs it always, a shipped default, a doc, or the
# code that enforces it. `add` refuses one and names the ticket that carries it.
#
# init    Write the surface header. No entry is guessed: an entry is the owner's
#         own call, so this file starts empty on purpose. Refuses to overwrite
#         an existing surface unless --force is passed.
# add     Append one entry of --kind owner. It refuses an entry with no kind, a
#         product rule, no owner words, no scope, or no enforcement point, an
#         enforcement point that names a missing repository path, words already
#         recorded in this surface, and words holding a line break (one entry is
#         one line per field).
#         --date defaults to today in UTC and must be YYYY-MM-DD.
# split   Report how the surface divides by kind: how many entries are owner, how
#         many are product, and which carry no kind yet. --apply rewrites the
#         surface to its owner entries only, so the product half can be filed as
#         the ticket it needs. Each product entry is named with its enforcement
#         point, in both modes. It refuses to apply while an entry has no kind.
#         Exit status is 0 when every entry is classified, 1 when an entry still
#         needs a kind, and 2 on a refusal or a usage error.
# audit   Report every owner quote that a private memory, notes or agent-config
#         file still holds and that this surface, the shared captain files, and
#         the tracked code never carry: a rule enforced only in one agent's
#         memory. Exit 0 with findings by default (a report); --fail makes
#         findings fatal. Sources default to $DATA/learnings.md plus every path
#         named in $CONFIG/owner-rule-sources (one file or directory per line,
#         `~` allowed), plus each --source given. A directory contributes its
#         *.md and *.txt files.
#         The quote test is verbatim and literal, so a paraphrase is invisible
#         to it, and JSONL session logs are not parsed - export the text you
#         want checked into a notes file and point a source at it.
#         ponytail: verbatim quote matching only, add paraphrase scoring if a
#         real correction is ever missed this way.
#
# Entry format, machine-readable by this command and readable as prose:
#   ## 2026-10-25 - Questions go on the board
#   - Kind: owner
#   - Scope: every captain-facing reply
#   - Enforced by: bin/jg-turnend-guard.sh; bin/jg-question-card.sh
#   - Owner's words: "..."
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
    jg_compat_marker_ok() { [ "${1-}" = JUGGERNAUT_OP ]; }
    jg_compat_marker() { printf "%s\n" "${1-}/.jg-squad-lead-home"; }
    jg_compat_parent_marker() { printf "%s\n" "${1-}/.jg-squad-lead-parent"; }
    jg_compat_claims_root() { printf "%s\n" "${1-}"; }
    jg_compat_pick() { printf "%s\n" "${1-}"; }
    jg_compat_kind() { printf "%s\n" "${1-}"; }
    jg_compat_meta_is_squad_lead() { grep -q "^kind=squad_lead\$" "${1-}" 2>/dev/null; }'
fi
unset _jg_d
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JG_ROOT="${JG_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
JG_HOME="${JG_HOME:-${JG_ROOT_OVERRIDE:-$JG_ROOT}}"
DATA="${JG_DATA_OVERRIDE:-$JG_HOME/data}"
CONFIG="${JG_CONFIG_OVERRIDE:-$JG_HOME/config}"
SURFACE="$DATA/owner-rules.md"

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
  exit 2
}
die() { printf 'jg-owner-rules: %s\n' "$1" >&2; exit 2; }

flow() { printf '%s' "$1" | tr '\n\t' '  ' | tr -s ' ' | sed 's/^ //; s/ $//'; }

surface_header() {
  cat <<'EOF'
# Owner rules

Standing decisions the owner gave the fleet, one entry each, in his own words.
Every entry carries `- Kind: owner`: his own taste and authority, the thing only he decides.
An engineering default any Juggernaut user should get is a product rule and never belongs here; it is a ticket and a change to what ships.
This is the only shared home for an owner correction: workers read it with the session digest, and a rule kept in one agent's memory is not a rule.
Write entries with `bin/jg-owner-rules.sh add --kind owner`; `split` reports the split by kind and `audit` finds quotes still trapped in private notes.
EOF
}

cmd_init() {
  local force=0
  [ "${1:-}" = --force ] && force=1
  mkdir -p "$DATA" || die "cannot create $DATA"
  if [ -e "$SURFACE" ] && [ "$force" -eq 0 ]; then
    die "$SURFACE already exists; pass --force to rewrite it"
  fi
  surface_header > "$SURFACE" || die "cannot write $SURFACE"
  printf 'wrote %s\n' "$SURFACE"
}

require_repo_paths() {  # <enforcement point> -> refuse a named path that does not exist
  local token path
  for token in $(printf '%s' "$1" | tr ';,()' '    '); do
    case "$token" in
      */*) ;;
      *) continue ;;
    esac
    case "$token" in
      *://*) continue ;;
    esac
    path=$token
    case "$path" in
      /*) ;;
      *) path="$JG_ROOT/$path" ;;
    esac
    [ -e "$path" ] || die "the enforcement point names $token, which does not exist in this checkout (fix --enforce)"
  done
}

words_already_recorded() {  # <normalized words>
  [ -f "$SURFACE" ] || return 1
  grep -Fq -- "$1" "$SURFACE"
}

cmd_add() {
  local words='' scope='' enforce='' date='' title='' kind=''
  while [ $# -gt 0 ]; do
    case "$1" in
      --kind) shift; [ $# -gt 0 ] || die "--kind needs a value"; kind=$1 ;;
      --words) shift; [ $# -gt 0 ] || die "--words needs a value"; words=$1 ;;
      --scope) shift; [ $# -gt 0 ] || die "--scope needs a value"; scope=$1 ;;
      --enforce) shift; [ $# -gt 0 ] || die "--enforce needs a value"; enforce=$1 ;;
      --date) shift; [ $# -gt 0 ] || die "--date needs a value"; date=$1 ;;
      --title) shift; [ $# -gt 0 ] || die "--title needs a value"; title=$1 ;;
      *) die "unknown argument: $1" ;;
    esac
    shift
  done

  kind=$(printf '%s' "$kind" | tr '[:upper:]' '[:lower:]')
  case "$kind" in
    '')
      die "refused: name the kind; this surface holds --kind owner entries only, and a product rule (an engineering default every Juggernaut user should get) is filed as a ticket with bin/jg-tasks-axi.sh add" ;;
    owner) ;;
    product)
      die "refused: a product rule is not an owner rule; file it with bin/jg-tasks-axi.sh add and put the default where it ships - AGENTS.md, a shipped default, a doc, or the code that enforces it" ;;
    *)
      die "refused: --kind must be owner (got '$kind')" ;;
  esac

  [ -n "$words" ] || die "refused: the entry needs the owner's own words (--words \"...\")"
  if [ "$(printf '%s' "$words" | wc -l | tr -d ' ')" -ne 0 ]; then
    die "refused: --words must be one line; quote the sentence he said"
  fi
  words=$(flow "$words")
  [ "$(printf '%s' "$words" | wc -w | tr -d ' ')" -ge 3 ] \
    || die "refused: --words needs at least three words of his own; a paraphrase is not a rule"

  scope=$(flow "$scope")
  [ -n "$scope" ] || die "refused: the entry needs a scope (--scope <where it applies>)"

  enforce=$(flow "$enforce")
  case "$enforce" in
    ''|none|None|NONE|n/a|N/A|-|todo|TODO)
      die "refused: the entry needs an enforcement point; a rule with nothing enforcing it is a wish (--enforce <script or contract>)" ;;
  esac
  require_repo_paths "$enforce"

  [ -n "$date" ] || date=$(date -u +%Y-%m-%d)
  case "$date" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
    *) die "refused: --date must be YYYY-MM-DD (got '$date')" ;;
  esac

  [ -n "$title" ] || title=$(printf '%s' "$words" | cut -c1-60)
  title=$(flow "$title")

  mkdir -p "$DATA" || die "cannot create $DATA"
  [ -f "$SURFACE" ] || { surface_header > "$SURFACE" || die "cannot write $SURFACE"; }
  words_already_recorded "$words" && die "refused: these words are already recorded in $SURFACE"

  {
    printf '\n## %s - %s\n' "$date" "$title"
    printf -- '- Kind: %s\n' "$kind"
    printf -- '- Scope: %s\n' "$scope"
    printf -- '- Enforced by: %s\n' "$enforce"
    printf -- '- Owner'"'"'s words: "%s"\n' "$words"
  } >> "$SURFACE" || die "cannot write $SURFACE"
  printf 'recorded: %s\n' "$title"
}

# cmd_split - report the owner/product split, and write the owner half back with --apply.
cmd_split() {
  local surface='' apply=0 report owners products unknown tmp
  while [ $# -gt 0 ]; do
    case "$1" in
      --surface) shift; [ $# -gt 0 ] || die "--surface needs a value"; surface=$1 ;;
      --apply) apply=1 ;;
      *) die "unknown argument: $1" ;;
    esac
    shift
  done
  [ -n "$surface" ] || surface=$SURFACE
  [ -f "$surface" ] || die "no rules surface at $surface"

  tmp=$(mktemp -d "${TMPDIR:-/tmp}/jg-owner-rules-split.XXXXXX") || die "cannot create a temporary directory"
  # The path is this run's own mktemp directory, quoted above, so the trap sees one fixed value.
  # shellcheck disable=SC2064
  trap "rm -f -- '$tmp'/* 2>/dev/null; rmdir -- '$tmp' 2>/dev/null || true" EXIT

  report=$(LC_ALL=C awk -v owner_out="$tmp/owner-rules.md" -v apply="$apply" '
    function flush() {
      if (block == "") return
      total++
      if (kind == "owner") {
        owners++
        if (apply) printf "%s", block > owner_out
      } else if (kind == "product") {
        products++
        printf "product: %s%s\n", title, (enforce == "" ? "" : " [enforced by: " enforce "]")
      } else {
        unclassified++
        printf "no kind: %s\n", title
      }
      block = ""
    }
    /^## / {
      flush()
      if (!started) { if (apply) printf "%s", header > owner_out; started = 1 }
      title = $0
      sub(/^## /, "", title)
      block = $0 "\n"
      kind = ""
      enforce = ""
      next
    }
    {
      if (block == "") { header = header $0 "\n"; next }
      block = block $0 "\n"
      if (kind == "" && $0 ~ /^- Kind:/) {
        kind = tolower($0)
        sub(/^- kind:[ \t]*/, "", kind)
        sub(/[ \t]+$/, "", kind)
      }
      if (enforce == "" && $0 ~ /^- Enforced by:/) {
        enforce = $0
        sub(/^- Enforced by:[ \t]*/, "", enforce)
        sub(/[ \t]+$/, "", enforce)
      }
    }
    END {
      flush()
      if (apply && !started) printf "%s", header > owner_out
      printf "total: %d\n", total
      printf "owners: %d\n", owners
      printf "products: %d\n", products
      printf "unclassified: %d\n", unclassified
    }
  ' "$surface") || die "cannot read $surface"

  [ -z "$report" ] || printf '%s\n' "$report"
  owners=$(printf '%s\n' "$report" | sed -n 's/^owners: //p')
  products=$(printf '%s\n' "$report" | sed -n 's/^products: //p')
  unknown=$(printf '%s\n' "$report" | sed -n 's/^unclassified: //p')

  if [ "$apply" -eq 1 ]; then
    [ "$unknown" -eq 0 ] \
      || die "refused: $unknown entries carry no kind yet; add a '- Kind: owner' or '- Kind: product' line to each one first"
    cat "$tmp/owner-rules.md" > "$surface" || die "cannot write $surface"
    printf 'applied: %s keeps %s owner entries and drops %s product entries\n' "$surface" "$owners" "$products"
    [ "$products" -eq 0 ] \
      || printf 'file each product entry as a ticket with bin/jg-tasks-axi.sh add, and put the default where it ships\n'
  fi

  [ "$unknown" -eq 0 ] && return 0
  return 1
}

normalize() { tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9\n' ' ' | tr -s ' \n' ' '; }

audit_sources() {
  local extra=$1 src rest
  [ -f "$DATA/learnings.md" ] && printf '%s\n' "$DATA/learnings.md"
  if [ -f "$CONFIG/owner-rule-sources" ]; then
    while IFS= read -r src; do
      src=$(printf '%s' "$src" | sed 's/[[:space:]]*$//')
      case "$src" in ''|'#'*) continue ;; esac
      rest=${src#\~}
      [ "$rest" = "$src" ] || src="$HOME$rest"
      printf '%s\n' "$src"
    done < "$CONFIG/owner-rule-sources"
  fi
  [ -z "$extra" ] || printf '%s\n' "$extra"
}

audit_files() {  # <source list file> -> the text files to scan
  local src f
  while IFS= read -r src; do
    [ -n "$src" ] || continue
    if [ -d "$src" ]; then
      find "$src" -maxdepth 2 -type f \( -name '*.md' -o -name '*.txt' \) 2>/dev/null \
        | LC_ALL=C sort | head -n 200 | sed 's/^/S /'
    elif [ -f "$src" ]; then
      printf 'S %s\n' "$src"
    fi
  done < "$1"
}

cmd_audit() {
  local fail=0 extra=''
  while [ $# -gt 0 ]; do
    case "$1" in
      --fail) fail=1 ;;
      --source) shift; [ $# -gt 0 ] || die "--source needs a value"; extra="$extra$1
" ;;
      *) die "unknown argument: $1" ;;
    esac
    shift
  done

  local tmp rc=0 quoted='' quotes unscanned=0 finding
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/jg-owner-rules.XXXXXX") || die "cannot create a temporary directory"
  trap 'rm -f -- "$tmp"/* 2>/dev/null; rmdir -- "$tmp" 2>/dev/null || true' EXIT
  audit_sources "$extra" > "$tmp/sources" || true
  audit_files "$tmp/sources" > "$tmp/files" || true

  {
    for f in "$SURFACE" "$DATA/captain.md" "$DATA/captain-shared.md" "$JG_ROOT/AGENTS.md"; do
      [ -f "$f" ] && cat "$f"
    done
    find "$JG_ROOT/bin" "$JG_ROOT/docs" "$JG_ROOT/.agents/skills" -type f 2>/dev/null \
      | grep -v '^'"$JG_ROOT"'/bin/jg-owner-rules.sh$' | while IFS= read -r f; do cat "$f" 2>/dev/null; done
  } | normalize > "$tmp/surface" 2>/dev/null || true

  local f
  quoted=''
  while IFS= read -r f; do
    [ -f "$f" ] && [ -r "$f" ] || continue
    quoted="$quoted$(LC_ALL=C awk '
      { while (match($0, /"[^"]{8,}"/)) {
          q = substr($0, RSTART + 1, RLENGTH - 2)
          print FILENAME "\t" FNR "\t" q
          $0 = substr($0, RSTART + RLENGTH)
        } }' "$f" 2>/dev/null | LC_ALL=C awk -F'\t' '
      { n = split($3, w, /[^A-Za-z0-9]+/); c = 0
        for (i = 1; i <= n; i++) if (length(w[i]) > 1) c++
        if (c >= 4) print }' 2>/dev/null)"$'\n'
  done < <(cut -c3- "$tmp/files")

  quotes=$(printf '%s' "$quoted" | grep -c . || true)
  [ "$quotes" -gt 0 ] || unscanned=1
  while IFS=$'\t' read -r file line text; do
    [ -n "$file" ] || continue
    finding=$(printf '%s' "$text" | normalize)
    grep -Fq -- "$finding" "$tmp/surface" && continue
    rc=1
    printf 'private: %s:%s\n  words: "%s"\n  fix: bin/jg-owner-rules.sh add --kind owner --words "%s" --scope <scope> --enforce <script or contract>\n' \
      "$file" "$line" "$text" "$text"
  done <<< "$quoted"

  if [ "$unscanned" -eq 1 ]; then
    printf 'no owner quotes found in %s source path(s); nothing to report (name more sources in %s)\n' \
      "$(grep -c . "$tmp/sources" 2>/dev/null || printf 0)" "$CONFIG/owner-rule-sources"
  elif [ "$rc" -eq 0 ]; then
    printf 'clean: all %s quoted owner words in the scanned notes are already in the shared surface or the code\n' "$quotes"
  else
    printf 'flagged: quoted owner words above live only in a private note; record each one with bin/jg-owner-rules.sh add\n'
  fi
  [ "$fail" -eq 1 ] && [ "$rc" -ne 0 ] && exit 1
  exit 0
}

[ $# -ge 1 ] || usage
cmd=$1
shift
case "$cmd" in
  init) cmd_init "$@" ;;
  add) cmd_add "$@" ;;
  split) cmd_split "$@" ;;
  audit) cmd_audit "$@" ;;
  -h|--help|help) usage ;;
  *) usage ;;
esac
