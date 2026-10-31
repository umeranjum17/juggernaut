#!/usr/bin/env bash
# Scaffold a operator brief or persistent squad_lead charter at
# data/<task-id>/brief.md under the active juggernaut home.
# For ordinary tasks, the standard Setup/Rules/Definition-of-done contract is
# filled in. Ship and scout `# Task` sections have two subsections Juggernaut
# fills before dispatch: `{TASK}` under `## Captain's intent` (the captain's
# own ask plus the context needed to read it, including the substance of any
# report, decision, or PR the ask refers to, without added speaker labels or
# direct address) and `{JUGGERNAUT_SPEC}`
# under `## Juggernaut spec` (build instructions, which are never the captain's
# intent). bin/jg-dod-lib.sh owns the no-mistakes `--intent` contract those
# subsections feed; bin/jg-spawn.sh refuses leftover placeholders and a
# `## Captain's intent` line opening with a Captain label or address. SquadLead
# charters still use a single `{TASK}` charter fill. Juggernaut may adjust other
# sections when the task genuinely deviates (e.g. working an existing external
# PR instead of shipping a new one).
# Usage: jg-brief.sh <task-id> <repo-name> --mode <no-mistakes|direct-PR|local-only> [--branch-prefix <prefix>] [--base-branch <branch>] [--forge <none|gerrit|forgejo> [--shape squash]] [--design-call <yes|no> --design-reason <text>] [--demo-call <yes|no> --demo-reason <text>] [--herdr-lab] [--medium <mobile|web|desktop|cli|backend>]
#        jg-brief.sh <task-id> <repo-name> --scout [--base-branch <branch>] [--herdr-lab]
#        jg-brief.sh <task-id> --squad-lead {<project>...|--no-projects}
#   --medium names the project's medium at intake, so the brief can carry this
#   home's stack advice from config/preferred-stack.json. It is a recommendation,
#   never a gate, and is optional.
#   --scout writes the scout contract instead: the deliverable is a report at
#   data/<task-id>/report.md (no branch, no push, no PR) and the worktree is scratch.
#   A visual deliverable goes on a sign-off board report, never a retired review
#   surface, and the report carries the sign-off report link only.
#   --squad-lead writes a persistent squad_lead charter. The project list
#   is cloned into the squad_lead home, while the natural-language scope
#   tells the main juggernaut when to route work there; routine churn stays in its own home;
#   captain-relevant escalations and marked from-juggernaut replies append to this
#   home's status file.
#   --no-projects writes a project-less charter for a domain whose subject is the
#   juggernaut repo itself (its home is a juggernaut worktree, its crews take pooled
#   worktrees of the same repo). It is mutually exclusive with a project list, and
#   omitting both still fails loudly so an accidental omission is never silent.
#   Set JG_SQUAD_LEAD_CHARTER='<charter>' to fill the charter text.
#   Set JG_SQUAD_LEAD_SCOPE='<scope>' to write a routing scope distinct from the charter text.
#   --herdr-lab is mandatory when the task will issue Herdr lifecycle commands.
#   It adds the hard isolation contract backed by bin/jg-herdr-lab.sh.
#   The flag must be explicit because {TASK} and {JUGGERNAUT_SPEC} are filled
#   after scaffolding and the caller-supplied repo string cannot reliably
#   identify this repo. Briefs made without it carry a loud declaration so an
#   omitted contract cannot be silent.
# --design-call <yes|no> --design-reason <text> records the per-task first-draft
# call on a ship brief as `Design call (first-draft): <yes|no> - <reason>`. Juggernaut
# or the lead judges it per task: yes for bigger redesigns, new screens, landing
# pages and design options; no for small UI fixes. The two flags go together and
# are refused on --scout and --squad-lead. bin/jg-spawn.sh records the call in the
# task record as design_call=, and bin/jg-merge-gate-lib.sh's jg_dod_design_gate
# refuses to merge a yes-task whose completion receipt evidence carries no
# `first-draft receipt: <ref>` line. A brief without the line (an older brief)
# warns at spawn and counts as no. No model decides: the gate is a shell check.
# --demo-call <yes|no> --demo-reason <text> records the per-task product demo-video
# call as `Demo-video call (TakeOne): <yes|no> - <reason>`: yes when the task ships a
# demo video of an app, no otherwise. The pair is validated like the design call and
# refused on --scout and --squad-lead. It takes effect only while the home has the
# presence flag config/takeone-demo (docs/configuration.md); with the flag absent the
# pair is accepted and the brief carries no demo line. bin/jg-spawn.sh records demo_call=,
# and bin/jg-merge-gate-lib.sh's jg_dod_demo_gate refuses to merge a yes-task whose
# completion receipt evidence carries no `takeone receipt: <ref>` line.
# --risk <reason> states why this task needs the no-mistakes pipeline, as one of
# release, security, migration, large-change, shared-protocol or fork-repo. It is
# required on a no-mistakes ship brief and refused elsewhere: no-mistakes is for
# real risk, and a task with no such risk ships as direct-PR with a done-done
# check. The local presence flag config/delivery-risk-loose turns the check off
# (docs/configuration.md "Delivery risk").
# --ui-change <yes|no> records on a ship brief whether the task changes the UI, as
# `UI change (nav-check): <yes|no>`. A yes brief carries the no-silent-removal rule:
# the PR body lists `Nav before:` and `Nav after:` and any removed screen is named.
# bin/jg-spawn.sh records ui_change= and bin/jg-merge-gate-lib.sh's jg_dod_nav_gate
# refuses to merge a yes-task whose PR body drops a nav item without a
# `Removed by captain words: <quote>` line. No flag (an older brief) warns and counts as no.
# Every ship brief also carries a `# Prior art` section: new or complex work
# starts from what already exists, so the worker surveys similar products and
# open-source projects, checks their licences, compares three to five options,
# and fills the section with its pick and the reasons. bin/jg-prior-art-gate.sh
# refuses the section left empty or holding the scaffold text; a change that is
# neither new nor complex records `Prior art: none needed - <why>` instead.
# For ship tasks, --mode is REQUIRED and shapes the definition of done. Juggernaut
# resolves it per task at intake (AGENTS.md section 7); data/projects.md holds the
# captain's standing posture as context, and this script never reads it:
#   no-mistakes  implement -> /no-mistakes pipeline -> PR -> configured merge authority
#   direct-PR    implement -> push + open PR via gh-axi (no pipeline) -> configured merge authority
#   local-only   implement on branch, stop and report "ready in branch" (no push/PR);
#                the configured merge authority approves, juggernaut merges to local main
# no-mistakes-prod-only is a registry policy, not a task mode; resolve it to one of
# the three concrete modes at intake before calling this script.
# --branch-prefix <prefix> optionally overrides the ship branch's "fm/" prefix, so
# the resolved branch is "<prefix><task-id>" instead of the default "fm/<task-id>".
# Pass an empty prefix ("--branch-prefix ''") for a bare "<task-id>" branch, or a
# conventional prefix such as "fix/" - useful for a third-party project that does
# not use this tooling and should not see an "fm/"-branded branch or PR. Defaults
# to "fm/" when omitted, so every existing installation's branch names are
# unchanged. Like --mode, this script never reads data/projects.md for it: the
# registry's optional "branch=<prefix>" annotation (bin/jg-project-mode.sh's
# header owns that format and its --branch-prefix query) is the captain's
# standing per-project preference, and juggernaut resolves it per task at intake
# and passes the explicit flag. Refused on --scout and --squad-lead: a scout
# makes no branch and a charter is not a delivery contract.
# --base-branch <branch> starts the task from origin's <branch> instead of the
# repository default, for work that belongs on a named integration, feature, or
# release branch. It writes a "Base branch: <branch>" line under `# Setup`, which
# bin/jg-spawn.sh requires to agree with the same --base-branch it is passed to
# choose the copy's starting point, and a ship's
# Definition of done then targets that branch with its pull request.
# bin/jg-dod-lib.sh's jg_base_branch_valid owns which deliveries accept one.
# Refused on --squad-lead.
# --forge names the project's forge, defaults to none, and is orthogonal to --mode
# exactly as the registry's `forge=` token is. It is the captain's confirmed
# registry binding, read from data/projects.md at intake and passed here; this
# script never infers a forge and never looks the binding up, and bin/jg-spawn.sh
# refuses a brief whose forge disagrees with the registry. bin/jg-project-mode.sh's
# header owns what the binding means, and bin/jg-dod-lib.sh owns what `gerrit`
# and `forgejo` change in the Definition of done. On `forgejo` this script also
# names tea instead of gh-axi in the ship brief's forge-CLI rule. A forge on
# --mode local-only is refused, because that mode publishes nothing.
# --shape names how a forge=gerrit task is published, and only `squash` - one
# change - is accepted: `stack` is refused until a stack can be watched by its
# membership pinned when its watch is armed, because the merge watch follows one
# change.
# It defaults to squash on gerrit and is refused without it.
# --upstream-consent <host>/<owner>/<repo> records the captain's one-off
# approval for this one task to publish to that repository when it is
# juggernaut's own upstream. It renders as an `upstream-consent=` token on the
# Delivery contract line, bin/jg-spawn.sh checks it against this home's role
# authority and records it in the task record, and bin/jg-promote.sh honors it
# the same way. Ship-only: a scout publishes nothing and a charter is not a
# delivery contract.
# --project <dir> is the task's project directory, used to detect when a ship
# brief would publish to juggernaut's own repository: for such a task this
# scaffold refuses a publishing mode that the home's role or recorded consent
# does not authorize, before the contract exists. Pass it on every ship
# scaffold so detection does not depend on the caller recognizing the repo;
# bin/jg-spawn.sh repeats the check at launch regardless.
# The generated ship brief records the chosen mode as a fixed machine-readable
# "Delivery contract: mode=<mode>" line, followed by " forge=gerrit shape=squash"
# on Gerrit or " forge=forgejo" on Forgejo. bin/jg-spawn.sh reads that line and
# refuses to launch a ship task whose explicit --mode or registered forge
# disagrees, so an adjusted brief and the recorded task metadata cannot drift
# apart.
# Ship briefs begin with a worktree-isolation assertion before the branch step.
# Both operator scaffolds carry one shared rule against administering the
# infrastructure every lane shares - the no-mistakes daemon and the worktree pool
# their own slot came from - so ship and scout cannot drift apart. A squad_lead
# charter omits it: that home allocates and returns slots for its own operators.
# --mode, --forge, and --shape are refused on scout and squad_lead scaffolds: a
# scout's deliverable is a report rather than a merge, and a charter is not a
# delivery contract.
# There is no --yolo flag here. The worker never owns merge decisions, so yolo is
# a spawn-time and juggernaut-side input only (AGENTS.md section 7).
# Every scaffold's status protocol distinguishes the configured
# declared-external-wait verb (JG_CLASSIFY_PAUSED_VERB, default "paused") from
# "blocked:": pause for a known wait expected to clear on its own, including
# the worker's own background work, pipeline or long command; blocked when
# juggernaut must act. The first-sight alert remains; repeats use the long cadence.
# Emission-time syntax and legacy unknown-time handling are owned by
# bin/jg-classify-lib.sh; each scaffold renders the stamp as a literal <epoch>
# placeholder the worker replaces with a numeric Unix time as it appends, so a
# scaffold never emits a substitution a file-write tool would copy through.
# Every scaffold also carries the steering-inbox receive-and-ack section:
# process state/<id>.inbox/*.msg in order and acknowledge each by moving it to
# handled/ (record, doorbell, and ladder owned by bin/jg-task-inbox-lib.sh).
# Ship tasks include a project-memory section bounding operator edits to a
# project's AGENTS.md/CLAUDE.md: only corrections of factually wrong
# information, including wrong information the task itself introduced - never
# additions of missing knowledge. A correction edits only the wrong text and
# never runs jg-ensure-agents-md.sh, whose inserted sections and created
# pointer file are themselves additions.
# Scaffolds carry no role scope: jg-spawn.sh supplies jg_brief_worker_role from
# jg-dod-lib.sh to every ship/scout launch brief, so this file never becomes a
# second owner of a contract that must stay current across relaunches.
# A home may carry standing worker instructions without editing this tracked
# script: when config/brief-include.md exists under the active home, ship and
# scout scaffolds append its text verbatim as their last section, "# Home brief
# additions", which defers to every other section of the brief. It goes last
# because the machine-read `# Task` heading resolves to its first match, so
# appended text can never shadow it; a later scout promotion appends its ship
# contract below it, which that position-free deference already covers. An
# absent or blank file changes nothing; a present path that is not a readable
# regular file, or text carrying its own "Delivery contract: mode=" line (which
# a later scout promotion could not outrank), stops the scaffold before
# anything is written. SquadLead charters never take it.
# Refuses to overwrite an existing brief.
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
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

# shellcheck source=bin/jg-addons-dir-lib.sh
. "$SCRIPT_DIR/jg-addons-dir-lib.sh"
# shellcheck source=bin/jg-marker-lib.sh
. "$SCRIPT_DIR/jg-marker-lib.sh"
# shellcheck source=bin/jg-classify-lib.sh
. "$SCRIPT_DIR/jg-classify-lib.sh"
# shellcheck source=bin/jg-dod-lib.sh
. "$SCRIPT_DIR/jg-dod-lib.sh"
# shellcheck source=bin/jg-role-lib.sh
. "$SCRIPT_DIR/jg-role-lib.sh"
# shellcheck source=bin/jg-preferred-stack-lib.sh
. "$SCRIPT_DIR/jg-preferred-stack-lib.sh"
PAUSED_VERB=${JG_CLASSIFY_PAUSED_VERB:-$JG_CLASSIFY_PAUSED_VERB_DEFAULT}
IFS= read -r -d '' OPERATOR_PAUSE_INSTRUCTIONS <<EOF || true
   Use \`$PAUSED_VERB: {why}\` - never \`blocked:\` - when deliberately waiting for work or an external condition expected to clear on its own, including your own validation round.
   Before ending your turn with your own background shell or monitor still running, or before waiting on your own pipeline run or a long foreground command, append \`$PAUSED_VERB [at=<epoch>]: {job and completion condition}\` to the status file.
   Name what you are waiting for and what will let you resume; do not repeat the declaration on every poll.
   Do not declare active implementation or reasoning as a wait.
   Juggernaut may still raise one first-sight alert; the declared wait then uses the existing long recheck cadence instead of repeated possible-wedge alarms.
   When you know when the wait clears, include \`until <YYYY-MM-DDTHH:MMZ>\` (UTC) for a recheck at that time.
   Follow the resolution rule below when the wait clears, then resume the task.
   Use \`blocked:\` when you are stuck and need help.
EOF

resolve_directory_input() {
  local name=$1 path=$2 resolved
  case "$path" in
    /*) printf '%s\n' "$path"; return 0 ;;
  esac
  resolved=$(CDPATH='' cd -- "$path" 2>/dev/null && pwd -P) || {
    echo "error: $name directory cannot be resolved: $path" >&2
    return 1
  }
  printf '%s\n' "$resolved"
}

JG_ROOT="${JG_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
JG_HOME=$(resolve_directory_input JG_HOME "${JG_HOME:-${JG_ROOT_OVERRIDE:-$JG_ROOT}}") || exit 1
if [ -n "${JG_DATA_OVERRIDE:-}" ]; then
  DATA=$(resolve_directory_input JG_DATA_OVERRIDE "$JG_DATA_OVERRIDE") || exit 1
else
  DATA="$JG_HOME/data"
fi
if [ -n "${JG_STATE_OVERRIDE:-}" ]; then
  STATE=$(resolve_directory_input JG_STATE_OVERRIDE "$JG_STATE_OVERRIDE") || exit 1
else
  STATE="$JG_HOME/state"
fi
CONFIG="${JG_CONFIG_OVERRIDE:-$JG_HOME/config}"
case "$CONFIG" in /*) ;; *) CONFIG="$PWD/$CONFIG" ;; esac
KIND=ship
HERDR_LAB=0
NO_PROJECTS=0
MODE=
MODE_SET=0
BRANCH_PREFIX=fm/
BRANCH_PREFIX_SET=0
BASE_BRANCH=
BASE_BRANCH_SET=0
FORGE=none
FORGE_SET=0
SHAPE=
SHAPE_SET=0
UPSTREAM_CONSENT=
UPSTREAM_CONSENT_SET=0
DESIGN_CALL=
DESIGN_REASON=
DEMO_CALL=
DEMO_REASON=
UI_CHANGE=
RISK=
RISK_SET=0
PROJECT_DIR=
PROJECT_DIR_SET=0
MEDIUM=
POS=()
want_value=
for a in "$@"; do
  if [ -n "$want_value" ]; then
    case "$a" in
      --*) echo "error: --$want_value requires a value" >&2; exit 1 ;;
    esac
    case "$want_value" in
      mode) MODE=$a; MODE_SET=1 ;;
      branch-prefix) BRANCH_PREFIX=$a; BRANCH_PREFIX_SET=1 ;;
      base-branch) BASE_BRANCH=$a; BASE_BRANCH_SET=1 ;;
      forge) FORGE=$a; FORGE_SET=1 ;;
      shape) SHAPE=$a; SHAPE_SET=1 ;;
      upstream-consent) UPSTREAM_CONSENT=$a; UPSTREAM_CONSENT_SET=1 ;;
      project) PROJECT_DIR=$a; PROJECT_DIR_SET=1 ;;
      medium) MEDIUM=$a ;;
      design-call) DESIGN_CALL=$a ;;
      design-reason) DESIGN_REASON=$a ;;
      demo-call) DEMO_CALL=$a ;;
      demo-reason) DEMO_REASON=$a ;;
      ui-change) UI_CHANGE=$a ;;
      risk) RISK=$a; RISK_SET=1 ;;
      *) echo "error: internal parser state for --$want_value" >&2; exit 1 ;;
    esac
    want_value=
    continue
  fi
  case "$a" in
    --scout) KIND=scout ;;
    --squad-lead) KIND=squad_lead ;;
    --herdr-lab) HERDR_LAB=1 ;;
    --no-projects) NO_PROJECTS=1 ;;
    --mode) want_value=mode ;;
    --mode=*) MODE=${a#--mode=}; MODE_SET=1 ;;
    --branch-prefix) want_value="branch-prefix" ;;
    --branch-prefix=*) BRANCH_PREFIX=${a#--branch-prefix=}; BRANCH_PREFIX_SET=1 ;;
    --base-branch) want_value="base-branch" ;;
    --base-branch=*) BASE_BRANCH=${a#--base-branch=}; BASE_BRANCH_SET=1 ;;
    --forge) want_value=forge ;;
    --forge=*) FORGE=${a#--forge=}; FORGE_SET=1 ;;
    --shape) want_value=shape ;;
    --shape=*) SHAPE=${a#--shape=}; SHAPE_SET=1 ;;
    --upstream-consent) want_value="upstream-consent" ;;
    --upstream-consent=*) UPSTREAM_CONSENT=${a#--upstream-consent=}; UPSTREAM_CONSENT_SET=1 ;;
    --project) want_value="project" ;;
    --project=*) PROJECT_DIR=${a#--project=}; PROJECT_DIR_SET=1 ;;
    --medium) want_value=medium ;;
    --medium=*) MEDIUM=${a#--medium=} ;;
    --design-call) want_value="design-call" ;;
    --design-call=*) DESIGN_CALL=${a#--design-call=} ;;
    --design-reason) want_value="design-reason" ;;
    --design-reason=*) DESIGN_REASON=${a#--design-reason=} ;;
    --demo-call) want_value="demo-call" ;;
    --demo-call=*) DEMO_CALL=${a#--demo-call=} ;;
    --demo-reason) want_value="demo-reason" ;;
    --demo-reason=*) DEMO_REASON=${a#--demo-reason=} ;;
    --ui-change) want_value="ui-change" ;;
    --ui-change=*) UI_CHANGE=${a#--ui-change=} ;;
    --risk) want_value=risk ;;
    --risk=*) RISK=${a#--risk=}; RISK_SET=1 ;;
    # yolo never reaches the worker: it is juggernaut's merge authority, not a
    # brief input. Refuse it loudly so it is never silently dropped here and then
    # believed to have been recorded.
    --yolo|--yolo=*) echo "error: --yolo is not a brief input; pass it to bin/jg-spawn.sh, which records the task's merge posture" >&2; exit 1 ;;
    *) POS+=("$a") ;;
  esac
done
[ -z "$want_value" ] || { echo "error: --$want_value requires a value" >&2; exit 1; }

# Ship delivery mode is an explicit per-task decision (AGENTS.md section 7). A
# missing or invalid value stops the scaffold rather than silently defaulting.
if [ "$KIND" = ship ]; then
  [ "$MODE_SET" -eq 1 ] || {
    echo "error: ship briefs require --mode <no-mistakes|direct-PR|local-only>; resolve it at intake from the captain's instruction and the project's registered posture in data/projects.md" >&2
    exit 1
  }
  case "$MODE" in
    no-mistakes|direct-PR|local-only) ;;
    no-mistakes-prod-only)
      echo "error: no-mistakes-prod-only is a registry policy, not a task mode; classify this task's surface and resolve it to no-mistakes or direct-PR at intake" >&2
      exit 1 ;;
    *) echo "error: --mode must be one of no-mistakes, direct-PR, local-only (got '$MODE')" >&2; exit 1 ;;
  esac
elif [ "$MODE_SET" -eq 1 ]; then
  echo "error: --mode applies only to ship briefs; a scout delivers a report and a squad_lead charter is not a delivery contract" >&2
  exit 1
fi

# No-mistakes is for real risk, so a no-mistakes ship brief states that risk with
# --risk; a task that names none takes the direct-PR route with a done-done check
# instead. The local presence flag config/delivery-risk-loose turns the check off.
if [ "$KIND" = ship ]; then
  if [ "$RISK_SET" -eq 1 ]; then
    case "$RISK" in
      release|security|migration|large-change|shared-protocol|fork-repo) ;;
      *) echo "error: --risk must be one of release, security, migration, large-change, shared-protocol, fork-repo (got '$RISK')" >&2; exit 1 ;;
    esac
  fi
  if [ "$MODE" = no-mistakes ] && [ "$RISK_SET" -eq 0 ] && [ ! -e "$CONFIG/delivery-risk-loose" ]; then
    echo "error: a no-mistakes ship brief states its risk with --risk <release|security|migration|large-change|shared-protocol|fork-repo>; a task with no such risk ships as --mode direct-PR with a done-done check" >&2
    exit 1
  fi
elif [ "$RISK_SET" -eq 1 ]; then
  echo "error: --risk applies only to ship briefs; a scout delivers a report and a squad_lead charter is not a delivery contract" >&2
  exit 1
fi

# The design call is a ship-only pair: a call without its reason (or the reverse)
# would record a decision nobody can audit.
if [ -n "$DESIGN_CALL$DESIGN_REASON" ]; then
  [ "$KIND" = ship ] || { echo "error: --design-call and --design-reason apply only to ship briefs" >&2; exit 1; }
  case "$DESIGN_CALL" in
    yes|no) ;;
    *) echo "error: --design-call must be yes or no (got '$DESIGN_CALL')" >&2; exit 1 ;;
  esac
  case "$DESIGN_REASON" in
    ''|*[![:print:]]*|' '*) echo "error: --design-reason needs one printable line stating why (first-draft: $DESIGN_CALL)" >&2; exit 1 ;;
  esac
fi

if [ -n "$DEMO_CALL$DEMO_REASON" ]; then
  [ "$KIND" = ship ] || { echo "error: --demo-call and --demo-reason apply only to ship briefs" >&2; exit 1; }
  case "$DEMO_CALL" in
    yes|no) ;;
    *) echo "error: --demo-call must be yes or no (got '$DEMO_CALL')" >&2; exit 1 ;;
  esac
  case "$DEMO_REASON" in
    ''|*[![:print:]]*|' '*) echo "error: --demo-reason needs one printable line stating why (TakeOne: $DEMO_CALL)" >&2; exit 1 ;;
  esac
fi

if [ -n "$UI_CHANGE" ]; then
  [ "$KIND" = ship ] || { echo "error: --ui-change applies only to ship briefs" >&2; exit 1; }
  case "$UI_CHANGE" in
    yes|no) ;;
    *) echo "error: --ui-change must be yes or no (got '$UI_CHANGE')" >&2; exit 1 ;;
  esac
fi

# A ship branch's prefix is optional per-project cosmetics, not a delivery
# decision, but it still only makes sense where a branch is actually created.
if [ "$KIND" != ship ] && [ "$BRANCH_PREFIX_SET" -eq 1 ]; then
  echo "error: --branch-prefix applies only to ship briefs; a scout makes no branch and a squad_lead charter is not a delivery contract" >&2
  exit 1
fi
case "$BRANCH_PREFIX" in
  *' '*) echo "error: --branch-prefix must not contain a space (got '$BRANCH_PREFIX')" >&2; exit 1 ;;
  -*) echo "error: --branch-prefix must not start with '-' (got '$BRANCH_PREFIX')" >&2; exit 1 ;;
esac
# The forge is validated against the same closed set the renderers enforce, so a
# typo or an impossible mode/forge pair stops here rather than reaching a worker.
if [ "$KIND" = ship ]; then
  jg_forge_valid_for_mode "$FORGE" "$MODE" "jg-brief.sh --forge" || exit 1
  if [ "$FORGE" = gerrit ]; then
    [ "$SHAPE_SET" -eq 1 ] || SHAPE=squash
    case "$SHAPE" in
      squash) ;;
      stack)
        echo "error: --shape stack is refused: a stack is several changes, and it must be watched by its membership pinned when its watch is armed, which this fleet does not yet do - the merge watch follows exactly one change, so a stack's wake could report one change as the whole stack; publish --shape squash" >&2
        exit 1 ;;
      *) echo "error: --shape must be squash (got '$SHAPE')" >&2; exit 1 ;;
    esac
  elif [ "$SHAPE_SET" -eq 1 ]; then
    echo "error: --shape applies only with --forge gerrit, where the worker publishes the change itself" >&2
    exit 1
  fi
  # A Forgejo project's pull requests are handled with tea, so the ship brief's
  # forge-CLI rule names it instead of gh-axi; every other forge keeps gh-axi.
  if [ "$FORGE" = forgejo ]; then
    FORGE_RULE_LINE="Use tea for Forgejo operations and chrome-devtools-axi for browser operations."
  else
    FORGE_RULE_LINE="Use gh-axi for GitHub operations and chrome-devtools-axi for browser operations."
  fi
elif [ "$FORGE_SET" -eq 1 ] || [ "$SHAPE_SET" -eq 1 ]; then
  echo "error: --forge and --shape apply only to ship briefs; a scout delivers a report and a squad_lead charter is not a delivery contract" >&2
  exit 1
fi
if [ "$BASE_BRANCH_SET" -eq 1 ]; then
  if [ "$KIND" = squad_lead ] || [ -z "$BASE_BRANCH" ]; then
    echo "error: --base-branch takes a branch name and applies only to ship and scout briefs" >&2
    exit 1
  fi
  jg_base_branch_valid "$BASE_BRANCH" "$MODE" "$FORGE" "jg-brief.sh --base-branch" || exit 1
fi
if [ "$KIND" != ship ]; then
  [ "$UPSTREAM_CONSENT_SET" -eq 0 ] || {
    echo "error: --upstream-consent applies only to ship briefs; a scout publishes nothing and a charter is not a delivery contract" >&2
    exit 1
  }
  [ "$PROJECT_DIR_SET" -eq 0 ] || {
    echo "error: --project applies only to ship briefs" >&2
    exit 1
  }
fi
if [ "$UPSTREAM_CONSENT_SET" -eq 1 ]; then
  [ -n "$UPSTREAM_CONSENT" ] || {
    echo "error: --upstream-consent requires a non-empty <host>/<owner>/<repo> value" >&2
    exit 1
  }
  jg_role_scope_valid "$UPSTREAM_CONSENT" || {
    echo "error: --upstream-consent must be <host>/<owner>/<repo> (got '$UPSTREAM_CONSENT')" >&2
    exit 1
  }
  UPSTREAM_CONSENT=$(jg_role_scope_norm "$UPSTREAM_CONSENT")
fi
# Self-repository pre-gate for a publishing ship brief: detectable only when
# --project was passed, so the check runs here only then. bin/jg-spawn.sh
# repeats it at launch with the resolved project path.
if [ "$KIND" = ship ] && [ "$MODE" != local-only ] && [ "$PROJECT_DIR_SET" -eq 1 ]; then
  [ -n "$PROJECT_DIR" ] || {
    echo "error: --project requires a non-empty directory" >&2
    exit 1
  }
  gate_rc=0
  jg_role_gate_self_publish "$JG_HOME" "$CONFIG" "$PROJECT_DIR" "$JG_ROOT" "$UPSTREAM_CONSENT" || gate_rc=$?
  case $gate_rc in
    0 | 2) ;;
    *)
      echo "error: $JG_ROLE_PUB_DENIAL" >&2
      echo "error: to let this home publish to ${JG_ROLE_PUB_TARGET:-that repository}, write 'maintainer ${JG_ROLE_PUB_TARGET:-<host>/<owner>/<repo>}' into $CONFIG/juggernaut-role (docs/configuration.md \"Juggernaut role\"), or pass --upstream-consent ${JG_ROLE_PUB_TARGET:-<host>/<owner>/<repo>} for this one task with the captain's explicit approval" >&2
      exit 1
      ;;
  esac
fi
ID=${POS[0]}
BRANCH="$BRANCH_PREFIX$ID"
if ! git check-ref-format --branch "$BRANCH" >/dev/null 2>&1; then
  echo "error: --branch-prefix and task id must form a valid git branch (got '$BRANCH')" >&2
  exit 1
fi
printf -v BRANCH_Q '%q' "$BRANCH"

if [ "$KIND" = squad_lead ] && [ "$HERDR_LAB" -eq 1 ]; then
  echo "error: --herdr-lab applies only to operator ship or scout briefs" >&2
  exit 1
fi

if [ "$NO_PROJECTS" -eq 1 ] && [ "$KIND" != squad_lead ]; then
  echo "error: --no-projects applies only to --squad-lead charters" >&2
  exit 1
fi

# The optional home-local include is read before anything is written, so an
# unusable file never leaves a partial scaffold behind.
BRIEF_INCLUDE_FILE="$CONFIG/brief-include.md"
BRIEF_INCLUDE_BODY=
if [ "$KIND" != squad_lead ] && { [ -e "$BRIEF_INCLUDE_FILE" ] || [ -L "$BRIEF_INCLUDE_FILE" ]; }; then
  { [ -f "$BRIEF_INCLUDE_FILE" ] && BRIEF_INCLUDE_BODY=$(cat "$BRIEF_INCLUDE_FILE" 2>/dev/null); } || {
    echo "error: $BRIEF_INCLUDE_FILE must be a readable regular file" >&2
    exit 1
  }
  if printf '%s\n' "$BRIEF_INCLUDE_BODY" | grep -q '^Delivery contract: mode='; then
    echo "error: $BRIEF_INCLUDE_FILE must not carry a 'Delivery contract: mode=' line; the delivery mode is a per-task --mode decision" >&2
    exit 1
  fi
  [ -n "$(printf '%s' "$BRIEF_INCLUDE_BODY" | tr -d '[:space:]')" ] || BRIEF_INCLUDE_BODY=
fi

_bi=$(jg_addon_path "${JG_HOME:-$SCRIPT_DIR/..}" brief-inherit/bin/jg-brief-inherit-lib.sh)
# shellcheck disable=SC1090 # The optional add-on source is installed outside this repository.
[ ! -f "$_bi" ] || { . "$_bi" && jg_brief_inherit_shared "$CONFIG" "$KIND"; }

# Append the include as the last section of a ship or scout scaffold.
append_brief_include() {
  [ -n "$BRIEF_INCLUDE_BODY" ] || return 0
  printf '\n%s\n%s\n%s\n' \
    '# Home brief additions' \
    "These are this home's standing additions; every other section of this brief takes precedence over anything here that conflicts." \
    "$BRIEF_INCLUDE_BODY" >> "$BRIEF"
}

BRIEF="$DATA/$ID/brief.md"
[ -e "$BRIEF" ] && { echo "error: $BRIEF already exists" >&2; exit 1; }
mkdir -p "$DATA/$ID"

ASK_USER_BLOCK=
if [ "$KIND" = ship ] && [ "$MODE" = no-mistakes ]; then
  ASK_USER_BLOCK=$(jg_ask_user_escalation_block "$DATA" "$ID")
fi

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

STATUS_FILE=$(shell_quote "$STATE/$ID.status")
# The worker's status command: the line is piped through bin/jg-lavish-guard.sh,
# which refuses a retired Lavish address or publication command and names the
# sign-off board instead, then appends the accepted line. The opt-in fleet
# ledger (docs/fleet-ledger.md) records it at once, costing one file test when
# the flag is absent. A host without that flag, such as a remote squad lead's,
# runs only the append; the watcher capture is the backstop.
STATUS_APPEND="echo \"{state} [at=<epoch>]: {one short line}\" | $(shell_quote "$JG_ROOT/bin/jg-lavish-guard.sh") --append $STATUS_FILE && { [ ! -e $(shell_quote "$CONFIG/fleet-ledger") ] || $(shell_quote "$JG_ROOT/bin/jg-fleet-ledger.sh") appended $(shell_quote "$CONFIG") $STATUS_FILE >/dev/null 2>&1 || true; }"
INBOX_DIR=$(shell_quote "$STATE/$ID.inbox")

# The receive-and-ack half of the steering-inbox contract, included in every
# scaffold kind. The record format, doorbell line, and re-ring ladder are
# owned by bin/jg-task-inbox-lib.sh. The doorbell names the inbox as
# "$JG_TASK_INBOX", which bin/jg-spawn.sh exports into every launch; the full
# path here remains the fallback for a worker launched without that export.
# The doorbell itself is self-describing, so this section is reinforcement
# for the natural-checkpoint habit, not the only carrier of the instruction.
# config/wait-no-turns (docs/configuration.md) adds the line that a waiting
# worker does not poll the inbox: checkpoint checks happen during active work,
# so waiting still spends no turns.
IFS= read -r -d '' INBOX_SECTION <<EOF || true
# Juggernaut instruction inbox
Juggernaut steers you through durable message files in $INBOX_DIR.
When a terminal message says an instruction is waiting there - and at any natural checkpoint when you are unsure - list $INBOX_DIR/*.msg, read and act on each message in numeric order, then acknowledge each handled message by moving it: \`mv $INBOX_DIR/NNN.msg $INBOX_DIR/handled/\`.
The move IS the acknowledgement: without it juggernaut rings again and eventually treats you as stuck. An empty or absent inbox needs no action.
EOF
if [ -e "$CONFIG/wait-no-turns" ]; then
  INBOX_SECTION+="Do not poll or list the inbox while waiting; a waiting instruction rings."$'\n'
fi
INBOX_SECTION=${INBOX_SECTION%$'\n'}

# How a operator or scout waits. Every model turn resends the whole context, so
# a wait must cost no turns: a decision wait ends the turn, and an external
# wait sleeps in one bounded blocking shell command sized to the harness.
# Emitted only when config/wait-no-turns is present.
IFS= read -r -d '' WAIT_SECTION <<'EOF' || true
# Waiting
Every turn you take resends your whole context, so a wait must cost no turns.
After you append `needs-decision:` or `blocked:`, end your turn at once: do not check the inbox, the status file, or anything else, because the answer arrives as a terminal message that starts your next turn.
Wait on anything external - a pipeline gate, PR checks, a heavy-test slot - with ONE blocking shell command that returns when the state changes: `no-mistakes axi run` or `respond` with `--wait`, `gh pr checks <pr> --watch`, or `until <condition>; do sleep 30; done` for anything else.
Never spend turns on `sleep` followed by a status check, and never background a command in order to poll it.
In Claude Code that `until` loop in a single Bash call is the sanctioned foreground wait: when the harness refuses a sleep-then-check command and points you at backgrounding instead, reissue the wait as the loop rather than accepting the background.
Bound that command by what your harness lets one command run: in Pi pass the bash tool a `timeout` of at most 2700 seconds, because Pi sets none by default; in Claude Code pass the Bash tool its maximum `timeout` of 600000 ms, because its default is 2 minutes; in Codex keep waiting on a still-running command with empty `write_stdin` polls of up to 300000 ms; elsewhere pass your shell tool its largest timeout and assume at most 10 minutes.
Give any `--wait` a duration a little under that bound.
When the bound passes with nothing changed, run the same blocking command again, with no status check in between.
The one exception is `respond`: it sent its answer before it began waiting, so reattach with `no-mistakes axi run --wait` instead, and never send the same `respond` again, because it would answer whichever gate parks next without you reading it.
A wait your shell can watch this way needs no `paused:` line, except your own pipeline run, a long foreground command, or your own validation round, which you declare once just before its blocking hold: append `paused:` once just before its first blocking command, then stay in the command, and never append it again as you reissue that command.
EOF
WAIT_SECTION=${WAIT_SECTION%$'\n'}
WAIT_BLOCK=
if [ -e "$CONFIG/wait-no-turns" ]; then
  WAIT_BLOCK="$WAIT_SECTION"$'\n\n'
fi

if [ "$KIND" = squad_lead ]; then
SQUAD_LEAD_PROJECTS=""
idx=1
while [ "$idx" -lt "${#POS[@]}" ]; do
  SQUAD_LEAD_PROJECTS="${SQUAD_LEAD_PROJECTS}${SQUAD_LEAD_PROJECTS:+ }${POS[$idx]}"
  idx=$((idx + 1))
done
if [ "$NO_PROJECTS" -eq 1 ]; then
  [ -z "$SQUAD_LEAD_PROJECTS" ] || { echo "error: --no-projects cannot be combined with a project list" >&2; exit 1; }
else
  [ -n "$SQUAD_LEAD_PROJECTS" ] || { echo "error: --squad-lead requires at least one project, or --no-projects for a project-less home" >&2; exit 1; }
fi
SQUAD_LEAD_CHARTER=${JG_SQUAD_LEAD_CHARTER:-"{TASK}"}
SQUAD_LEAD_SCOPE=${JG_SQUAD_LEAD_SCOPE:-${JG_SQUAD_LEAD_CHARTER:-"{TASK}"}}
if [ "$NO_PROJECTS" -eq 1 ]; then
  PROJECT_CLONES_BODY="None. This is a project-less domain: its subject is the juggernaut repo this home lives in, so it needs no separate clones under \`projects/\`; its crews take pooled worktrees of that juggernaut repo."
  PROJECT_CLONES_NOTE="This domain has no separate project clones: its subject is the juggernaut repo this home lives in, and its crews take pooled worktrees of that repo."
else
  PROJECT_CLONES_BODY=$(printf '%s\n' "$SQUAD_LEAD_PROJECTS" | tr ' ' '\n' | sed 's/^/- /')
  PROJECT_CLONES_NOTE="The projects above are local clones for work you supervise; they are not an exclusive ownership claim."
fi
cat > "$BRIEF" <<EOF
You are a persistent squad lead managed by the main juggernaut. Work on your own; do not wait for a human.

# Charter
$SQUAD_LEAD_CHARTER

# Routing scope
$SQUAD_LEAD_SCOPE

# Project clones
$PROJECT_CLONES_BODY

# Operating model
You are in an isolated juggernaut home. The local \`AGENTS.md\` is your job description, and your local \`data/\`, \`state/\`, \`config/\`, and \`projects/\` dirs are yours to operate.
$PROJECT_CLONES_NOTE
Delegate project work to your own operators with the normal juggernaut lifecycle: brief, spawn, status, watcher, steer, teardown, and recovery.
Do not invent a second delegation system.
You do not generate your own work.
Act only on tasks the main juggernaut routes to you.
Never start a survey, audit, or "find improvements" sweep on your own initiative; that is not your job and it is unwanted.

# The captain and the parent channel
Nobody reads this chat: the captain and the main juggernaut see only what is appended to $STATUS_FILE, and a captain-facing sentence that is not appended there has not been sent.
That file is your parent channel, and in this home it IS the captain: every sentence you would say to the captain, and every outcome the local AGENTS.md tells a juggernaut to bring to the captain, is one appended line there, never chat.
Your own machinery publishes the durable facts about your crew's work for you (\`bin/jg-parent-channel-lib.sh\`): a child's terminal done or failed line with its note and PR on every supervision poll, a PR-ready line when you register a PR, a task you hold for the captain and its answer, a merge, and a child's final line at cleanup all reach the parent channel from the scripts that record them, whether or not you append anything.
What only you can append is judgement: the answer to a marked request below, a recommendation or caveat on a delivered outcome, a blocker or failure of your own, and anything else you would otherwise say to the captain.

# Requests from the main juggernaut
You are a juggernaut in your own home, so an incoming message reaches you in your own chat.
You must distinguish who it is from, because the answer goes to a different place.
A request relayed to you by the main juggernaut is tagged with a leading \`$JG_FROMFIRST_LABEL\` marker followed by an invisible system separator; this marker is untypable, so a human never produces it.
When a message carries that marker, do the work, then respond via the STATUS/ESCALATION path below, never only in this chat: the main juggernaut does not read your chat, so a chat-only reply is lost.
Marked requests also carry a privacy-safe \`corr=<id>\` token after the marker; include that exact token in your parent status reply (or in the status pointer to a detailed doc) so the parent can correlate the answer.
Optional helper: \`bin/jg-squad-lead-report.sh <verb> <corr_id> <note>\` appends that correlated line to the parent channel itself - do not pass a status path, and do not write a hand path under this home.
A plain \`echo\` that includes the same \`corr=<id>\` on this parent channel is equally valid; do not depend on the helper being present.
For a terse result, a status line is the whole answer.
For a detailed answer (an investigation, a plan, an audit), write it to a doc under your home's \`data/\` and append a status line that points to that doc - the scout-report pattern - so the main juggernaut is woken and can read it.
Before treating an investigation or visual review as complete, load \`captain-hold-lifecycle\` from this home's \`.agents/skills/\` and pass its shared completion gate.
A message with NO marker is the captain typing directly into your pane: treat it as authoritative captain intervention and stay conversational exactly as you would for any captain message; do not force it onto the status path.
A request arriving through the instruction inbox below follows the same marker and reply rules.

$INBOX_SECTION

# Escalation to main juggernaut
Handle routine work yourself.
Report only true captain-relevant outcomes or a declared external wait by appending one line:
   \`$STATUS_APPEND\`
States: working, needs-decision, blocked, $PAUSED_VERB, done, failed.
Substitute \`<epoch>\` with the current Unix time in seconds - run \`date +%s\` and write the number it printed; a stamp that is not plain digits records no time at all.
Use \`$PAUSED_VERB: {why}\` (never \`blocked:\`) only when your domain is deliberately idling on a known external wait you expect to clear on its own, naming when it clears with \`until <YYYY-MM-DDTHH:MMZ>\` (UTC) when you know; use \`blocked:\` when you are stuck and need juggernaut to act.
Use this only for material phase changes, a captain decision, a real blocker, a failure, work ready for review, or work you landed.
Work you landed includes a merge you performed yourself under standing merge authority and one the captain merged on the forge: under that authority nothing is ever \"ready for review\", so a landed merge that goes unreported reaches the captain as silence.
This is also how you return the answer to a marked from-juggernaut request above.
A marked request requires one correlated answer after the work; it does not require a separate receipt or start acknowledgement.
Never append \`working:\` merely to acknowledge receipt or announce that a marked request has started.
When a routed-work phase has a supervisor-actionable material change worth reporting under the rule above, give that reported phase a stable key.
If its first reportable event is \`working [key=<work-slug>]: {material phase}\`, use the same key on its later \`$PAUSED_VERB\`, \`done\`, \`failed\`, \`needs-decision\`, or \`blocked\` event so the earlier working phase is superseded.
When a keyed phase ends without another reportable state, append \`resolved [key=<work-slug>] [at=<epoch>]: {why it is no longer active}\`.
\`resolved\` separately closes an escalated decision or blocker, and only a \`resolved\` line carrying that decision's exact key closes it: a later \`done\` or \`working\` event never does, even when the answer is what started that work.
The main juggernaut's answer normally writes that closing line at answer time; when a blocker or wait clears WITHOUT an answer from the main juggernaut, append \`resolved [at=<epoch>]: {how it cleared}\` yourself (keyed with \`[key=<slug>]\` if you opened it with one) as your domain resumes.
Routine internal supervision, heartbeats, retries, and operator churn stay inside your own home and must not touch that status file.

# Definition of done
You are persistent by default. Do not exit just because your queue is empty.
On startup and restart, run normal juggernaut bootstrap and recovery through \`bin/jg-session-start.sh\` for your own home, but only to RECONCILE work that is already yours: in-flight operators, tracked backlog items, and durable watches recorded in this home.
When you have no assigned or in-flight work after that reconciliation, go idle and wait silently for the main juggernaut to route you a task.
An empty queue is a healthy resting state, not a cue to invent work: never spawn a survey, audit, or any self-directed "find work" task on your own initiative.
If this charter cannot be carried out, append \`blocked [at=<epoch>]: {why}\` or \`failed [at=<epoch>]: {why}\` to the main status file and stop.
EOF
if [ "$SQUAD_LEAD_CHARTER" = "{TASK}" ]; then
  echo "scaffolded: $BRIEF (squad_lead charter; replace {TASK})"
else
  echo "scaffolded: $BRIEF (squad_lead charter)"
fi
exit 0
fi

REPO=${POS[1]}

if [ "$HERDR_LAB" -eq 1 ]; then
HERDR_LAB_HELPER=$(shell_quote "$JG_ROOT/bin/jg-herdr-lab.sh")
# shellcheck disable=SC2016  # single quotes are deliberate: these lines are literal brief text whose backtick-wrapped $(...) and "$HERDR_LAB_SESSION" snippets must reach the reading agent verbatim, not expand at scaffold time; only the '"$VAR"' break-outs interpolate.
HERDR_SECTION=$(printf '%s\n' \
'# Herdr isolation - HARD SAFETY CONTRACT' \
'This brief was explicitly scaffolded with `--herdr-lab` because the task will drive Herdr lifecycle behavior.' \
'On Herdr 0.7.3 the API socket is not relocatable by `HERDR_CONFIG_PATH`, `XDG_CONFIG_HOME`, or `HOME`.' \
'A named non-`default` session plus an explicit `--session <name>` Herdr option on every call is the only viable local isolation.' \
'' \
'For tmux-based lab primaries, `bin/jg-lab-home.sh` owns the short private socket directory; do not place `TMUX_TMPDIR` under the lab home or worktree.' \
'Use `LAB_HOME_HELPER='"$(shell_quote "$JG_ROOT/bin/jg-lab-home.sh")"'`, then `LAB_TMUX_DIR=$("$LAB_HOME_HELPER" tmux-dir "$JG_HOME")` and launch tmux with `TMUX_TMPDIR="$LAB_TMUX_DIR"`.' \
'Your single EXIT cleanup trap must kill only the server addressed through that `TMUX_TMPDIR`, call `"$LAB_HOME_HELPER" teardown "$JG_HOME"`, and call the Herdr teardown below; do not install a second trap that replaces either cleanup.' \
'' \
'1. Set `HERDR_LAB_HELPER='"$HERDR_LAB_HELPER"'` and generate the session name with `HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name '"$ID"')`.' \
'   Install the combined EXIT cleanup before provisioning, then provision only with `"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION"`.' \
'2. Run every task-specific non-lifecycle Herdr command through `"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" <arguments...>`.' \
'   The helper supplies the required `--session "$HERDR_LAB_SESSION"` as a Herdr option, before any `--` delimiter; `HERDR_SESSION` alone is never accepted as isolation.' \
'3. Teardown only through `"$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION"`.' \
'   It re-checks refuse-default immediately before stop and again immediately before delete, and fails closed on ambiguity.' \
'4. If an experiment requires a deliberate mid-run session stop, use only `"$HERDR_LAB_HELPER" stop "$HERDR_LAB_SESSION"`; it performs the same immediate refuse-default check.' \
'5. Forbidden commands: direct `herdr server stop`, every other server-global operation such as `herdr server live-handoff` or reload/update operations, direct `herdr session stop`, direct `herdr session delete`, and any Herdr call scoped only by ambient or inline `HERDR_SESSION`.' \
'6. The helper records the live default session before provisioning and verifies the identical fleet state after teardown.' \
'   A missing, stopped, or changed default session is a hard tripwire failure, never a cleanup warning to ignore.' \
'' \
'Never bypass the helper, even for a read-only lifecycle probe or cleanup after failure.' \
'The captain fleet uses the running `default` session.')
else
IFS= read -r -d '' HERDR_SECTION <<'EOF' || true
# Herdr lifecycle declaration - NOT ENABLED
**HARD SAFETY GATE:** this scaffold cannot inspect the task text filled in above.
If the task will start, stop, delete, restart, profile, or otherwise drive Herdr lifecycle behavior, stop and regenerate the brief with `--herdr-lab` before dispatch.
Do not add Herdr lifecycle commands to this unguarded brief by hand.
EOF
HERDR_SECTION=${HERDR_SECTION%$'\n'}
fi

IFS= read -r -d '' TASK_SECTION <<'EOF' || true
# Task
## Captain's intent
{TASK}

## Juggernaut spec
{JUGGERNAUT_SPEC}
EOF
TASK_SECTION=${TASK_SECTION%$'\n'}

# One shared string keeps the ship and scout infrastructure rule identical.
# Rule 2 governs file edits, so it does not prohibit pool administration.
# The squad_lead charter deliberately omits this rule because a squad_lead
# legitimately allocates and returns slots for operators in its own home.
IFS= read -r -d '' SHARED_INFRA_RULE <<'EOF' || true
7. Never administer infrastructure that every lane shares. Two things are shared:
   - The `no-mistakes` daemon - one instance serving every lane/home, so stopping, restarting, or
     updating it kills other lanes' in-flight pipeline runs; only juggernaut manages the daemon.
     Before you append `blocked:` about the pipeline, run `no-mistakes daemon status` and
     `no-mistakes axi status`. If the daemon socket refuses connections or is missing, append
     `blocked [at=<epoch>]: {the daemon error}` and stop even when the local run record still says running or
     fixing, because that record can be stale after the daemon exits. A run record failed with a
     daemon error is also a real block.
     Only after ruling out socket refusal, if the run is still running or fixing, reattach and keep
     going. A drive-call error, timeout, slow read, or generic unreachability is NOT a daemon error:
     the daemon accepts `respond` immediately and runs the round in the background, so a killed or
     timed-out call was only waiting for a read while the run kept working.
   - The worktree pool your own worktree came from, and the repository every lane's worktree
     shares. Never create, remove, return, prune, move, or reassign a worktree or pool slot, and
     never write into a sibling slot's directory. Rule 2 does not cover this: removing a worktree
     is administration rather than an edit outside your directory, and it lands on lanes that are
     running right now. The act is the rule and commands are only examples of it - `treehouse`
     get/return/remove/prune, the equivalent operations on any other worktree provider or runtime
     backend, and `git worktree add|remove|move|prune`. A slot that looks unused is not evidence
     that it is free, and returning your own worktree is juggernaut's job at cleanup, not yours.
   If you genuinely need a second checkout, another slot, or the daemon touched, append
   `blocked [at=<epoch>]: {what you need}` and stop; juggernaut arranges it.
EOF
SHARED_INFRA_RULE=${SHARED_INFRA_RULE%$'\n'}

if [ -n "$BASE_BRANCH" ]; then
  SETUP_BASE="You are in a disposable git worktree of $REPO, at a detached HEAD on a clean copy of its base branch.
Base branch: $BASE_BRANCH"
else
  SETUP_BASE="You are in a disposable git worktree of $REPO, at a detached HEAD on a clean default branch."
fi

if [ "$KIND" = scout ]; then
SIGNOFF_LINE='A visual deliverable goes on a sign-off board report, never a retired review surface: publish or update it with sign-off-axi and return the sign-off report link only, in the report and in your done line.'
cat > "$BRIEF" <<EOF
You are a operator: an autonomous worker agent managed by juggernaut. Work on your own; do not wait for a human.

$TASK_SECTION

$HERDR_SECTION

# Setup
$SETUP_BASE
This is a SCOUT task: the deliverable is a written report, not a PR.
The worktree is your laboratory - install, run, edit, and make scratch commits freely; all of it is discarded at teardown.
The report is the only thing that survives, so anything worth keeping must be in it.

# Rules
1. Never push to any remote and never open a PR.
2. Stay inside this worktree; the only files you may write outside it are the report and the status file below.
   Never use git stash: all worktrees of a repo share one stash; commit work in progress on your own branch instead.
3. Use gh-axi for GitHub operations and chrome-devtools-axi for browser operations.
4. Report status by appending one line:
   \`$STATUS_APPEND\`
   States: working, needs-decision, blocked, $PAUSED_VERB, done, failed.
   Substitute \`<epoch>\` with the current Unix time in seconds - run \`date +%s\` and write the number it printed; a stamp that is not plain digits records no time at all.
   Each append wakes juggernaut, so report sparingly: only phase changes a supervisor
   would act on and the needs-decision/blocked/paused/done/failed states. No step-by-step
   FYI progress lines; juggernaut reads your pane for that.
   Whenever you mention a PR anywhere - a status line, your terminal, a summary - write its full
   https:// URL exactly as the forge printed it, never a bare number such as "PR 108"; juggernaut
   copies that URL from your line rather than assembling one.
$OPERATOR_PAUSE_INSTRUCTIONS
5. If you hit the same obstacle twice, append \`blocked [at=<epoch>]: {why}\` and stop; juggernaut will help.
6. If a decision belongs to a human (product choices, destructive actions),
   append \`needs-decision [at=<epoch>]: {summary of options}\` and stop. Juggernaut will reply with the decision.
   A decision or blocker you opened stays open until a \`resolved\` line carrying its exact key lands; a later \`done:\` or \`working:\` line never closes it, even when the answer is what started that work.
   Juggernaut's reply normally writes that closing line at answer time; when a blocker or wait clears WITHOUT a juggernaut reply, append \`resolved [at=<epoch>]: {how it cleared}\` yourself (same \`[key=<slug>]\` if you opened it with one) as you resume.
$SHARED_INFRA_RULE

$WAIT_BLOCK$INBOX_SECTION

# Definition of done
Write your findings to \`$DATA/$ID/report.md\`.
The report must stand alone: what you did, what you found, the evidence (commands run, output, file:line references), and what you recommend.
$SIGNOFF_LINE
Before reporting done, read and follow \`$JG_ROOT/.agents/skills/captain-hold-lifecycle/SKILL.md\` and pass its shared completion gate for the report and any visual review.
When the report is complete, append \`done [at=<epoch>]: {one-line conclusion}\` to the status file and stop.
If your findings reveal work that should ship (e.g. you reproduced a bug and the fix is clear), say so in the report; juggernaut may promote this task in place, and you would then receive mode-specific ship instructions as a follow-up message.
EOF
append_brief_include
echo "scaffolded: $BRIEF (scout; replace {TASK} and {JUGGERNAUT_SPEC})"
exit 0
fi

# Ship task: shape Setup / Rule 1 by this task's explicit delivery mode, validated
# above, and render the Definition of done from its single owner, bin/jg-dod-lib.sh,
# which bin/jg-promote.sh renders too so a promoted scout receives the same contract.
# The block opens with the fixed "Delivery contract: mode=<mode>" line that
# bin/jg-spawn.sh checks against its own explicit --mode and the project's
# registered forge before launching.
case "$MODE" in
  direct-PR)
    SETUP2=""
    ;;
  local-only)
    SETUP2=""
    ;;
  *)  # no-mistakes
    SETUP2="
2. Run \`no-mistakes doctor\`; if it reports the repo is not initialized here, run \`no-mistakes init\`."
    ;;
esac
# Every ship brief carries the prior-art step: new or complex work starts from
# what already exists, and a change that is neither records that in one line.
# bin/jg-prior-art-gate.sh refuses the section left empty or holding this
# scaffold text, so the worker fills it before reporting done.
IFS= read -r -d '' PRIOR_ART_SECTION <<EOF || true
# Prior art
New or complex work starts from what already exists, so survey it before you design or write code.
Load the \`prior-art\` skill for the procedure: search online for similar products and open-source projects, check each candidate's licence and say plainly whether it can be used here, compare three to five real options with their trade-offs, and name the pick and the reasons.
Replace the survey line below with the record, then run \`$JG_ROOT/bin/jg-prior-art-gate.sh $DATA/$ID/brief.md\`; it refuses the section left empty or unreplaced, and passes only with a recorded pick and its licence decision.
Prior art (survey): <replace with \`Prior art pick: <name>\` and \`Licence: <licence - usable here or not>\` lines, or with \`Prior art: none needed - <why this work is neither new nor complex>\`>
EOF
PRIOR_ART_SECTION=$'\n'${PRIOR_ART_SECTION%$'\n'}$'\n'
DESIGN_SECTION=
if [ -n "$DESIGN_CALL" ]; then
  DESIGN_SECTION="
# Design call
Design call (first-draft): $DESIGN_CALL - $DESIGN_REASON"
  if [ "$DESIGN_CALL" = yes ]; then
    DESIGN_SECTION="$DESIGN_SECTION
Make every design option for this task with first-draft (\`first-draft-axi make\` or \`refine\`); never hand-write option HTML.
Save the JSON run record that \`make\` or \`refine\` prints, and put one line \`first-draft receipt: <the run record file>\` in the evidence file of your completion receipt; the gate resolves that reference and reads the record. Name several records comma-separated when more than one run made the options.
A \`first-draft-axi judge\` run is not a receipt: it scores a page and makes none, so a judge-only record, a reference that does not resolve, and an option the record does not list are all refused.
Done is refused while any option you present has no make or refine record (\`bin/jg-merge-gate-lib.sh\`'s jg_design_done_gate), and so is a board post: post design options only after \`bin/jg-design-gate.sh board <run record> <options folder or file>\` passes."
  else
    DESIGN_SECTION="$DESIGN_SECTION
A hand-rolled change stays a small tweak only while its UI files change at most 40 lines and it adds no new UI file; past that, or once it presents design options, every option must be made or refined by first-draft and named by a \`first-draft receipt: <run record file>\` line, exactly as on a yes task (\`bin/jg-design-gate.sh\`).
A small tweak that touches UI files merges only after your lead or Main approves the hand-roll; you never approve it yourself."
  fi
  DESIGN_SECTION="$DESIGN_SECTION
"
fi
DEMO_SECTION=
if [ -n "$DEMO_CALL" ] && [ -e "$CONFIG/takeone-demo" ]; then
  DEMO_SECTION="
# Demo-video call
Demo-video call (TakeOne): $DEMO_CALL - $DEMO_REASON"
  if [ "$DEMO_CALL" = yes ]; then
    DEMO_SECTION="$DEMO_SECTION
Make every product demo video for this task with TakeOne; do not record or edit a separate video path.
Put one line \`takeone receipt: <reference>\` in the evidence file of your completion receipt.
The merge is refused without that line."
  fi
  DEMO_SECTION="$DEMO_SECTION
"
fi
UI_SECTION=
if [ -n "$UI_CHANGE" ]; then
  UI_SECTION="
# UI change
UI change (nav-check): $UI_CHANGE"
  if [ "$UI_CHANGE" = yes ]; then
    UI_SECTION="$UI_SECTION
A UI change never removes or renames an existing menu, tab or screen unless the captain's own words ask for it.
A design option that removes a screen must name each removed screen in plain words.
Put two lines in the PR body: \`Nav before: <item>, <item>\` and \`Nav after: <item>, <item>\`, listing every menu, tab and screen the change touches.
An item in before that is missing from after needs a line \`Removed by captain words: <quote of the captain>\`.
The merge is refused without the two lines, or with a dropped item and no quote."
  fi
  UI_SECTION="$UI_SECTION
"
fi
# The home's stack and layout advice (config/preferred-stack.json and
# config/architecture.json) is a recommendation the brief carries and the worker
# may override; a project that already has its own stack or layout wins. The
# medium comes from intake because a manifest cannot reveal it reliably; the
# language is read from an existing project's manifest.
STACK_SECTION=$(jg_stack_section "$CONFIG" "$MEDIUM" "$PROJECT_DIR")
STACK_BLOCK=
[ -z "$STACK_SECTION" ] || STACK_BLOCK="$STACK_SECTION"$'\n'

RULE1=$(jg_ship_rule_one "$MODE" "$ID" "$BRANCH" "$FORGE" "$BASE_BRANCH") || exit 1
RISK_SECTION=
if [ -n "$RISK" ]; then
  RISK_SECTION="
# Delivery risk
Delivery risk (no-mistakes): $RISK"
fi
DOD=$(jg_dod_block "$MODE" "$ID" "$BRANCH" "$FORGE" "$BASE_BRANCH" "$UPSTREAM_CONSENT") || exit 1

cat > "$BRIEF" <<EOF
You are a operator: an autonomous worker agent managed by juggernaut. Work on your own; do not wait for a human.

$TASK_SECTION
$PRIOR_ART_SECTION$DESIGN_SECTION$DEMO_SECTION$UI_SECTION$RISK_SECTION
$HERDR_SECTION
$STACK_BLOCK

# Setup
$SETUP_BASE

**Verify isolation before anything else.** Run \`pwd -P\` and \`git rev-parse --show-toplevel\`; both must resolve to the disposable task worktree you were launched in, such as a treehouse pool path or an Orca-managed worktree, not the primary checkout juggernaut operates from.
The path check is authoritative: \`git rev-parse --git-dir\` and \`git rev-parse --git-common-dir\` can help inspect the repo, but they do not prove you are outside the primary checkout.
If the top-level path is the primary checkout or not the worktree you were launched in, STOP - do not branch or commit here - append \`blocked [at=<epoch>]: launched in primary checkout, not an isolated worktree\` to the status file and stop.

1. First action: create your branch: \`git checkout -b $BRANCH_Q --\`$SETUP2

# Rules
$RULE1
2. Keep project edits inside this worktree; keep proof and scratch output outside it, under \`$DATA/$ID/\` or a temporary directory.
   Outside the worktree, write only that task material and the status and steering-inbox records authorized below.
   Register disposable temporary directories outside the Juggernaut home, repository, state and data directories with \`JG_HOME='$JG_HOME' JG_STATE_OVERRIDE='$STATE' JG_DATA_OVERRIDE='$DATA' '$JG_ROOT/bin/jg-scratch.sh' register $ID <dir>\` so cleanup reaps them; keep retained evidence under \`$DATA/$ID/\` unregistered.
   Leave the worktree clean before reporting done.
   Never use git stash: all worktrees of a repo share one stash; commit work in progress on your own branch instead.
3. $FORGE_RULE_LINE
4. Report status by appending one line:
   \`$STATUS_APPEND\`
   States: working, needs-decision, blocked, $PAUSED_VERB, done, failed.
   Substitute \`<epoch>\` with the current Unix time in seconds - run \`date +%s\` and write the number it printed; a stamp that is not plain digits records no time at all.
   Each append wakes juggernaut, so report sparingly: only phase changes a supervisor
   would act on (setup done, bug reproduced, fix implemented, validation passed) and the
   needs-decision/blocked/paused/done/failed states. No step-by-step FYI progress lines;
   juggernaut reads your pane for that.
   Whenever you mention a PR anywhere - a status line, your terminal, a summary - write its full
   https:// URL exactly as the forge printed it, never a bare number such as "PR 108"; juggernaut
   copies that URL from your line rather than assembling one.
   A mid-task \`working:\` line (including setup complete) is nonterminal: do not end the
   turn after it; continue the same stage until a defined \`done:\` gate under Definition of done.
$OPERATOR_PAUSE_INSTRUCTIONS
5. If you hit the same obstacle twice, append \`blocked [at=<epoch>]: {why}\` and stop; juggernaut will help.
6. If a decision belongs above the implementation worker (product choices, destructive actions),
   append \`needs-decision [at=<epoch>]: {summary of options}\` and stop. Juggernaut will reply with the decision.
$ASK_USER_BLOCK
   A decision or blocker you opened stays open until a \`resolved\` line carrying its exact key lands; a later \`done:\` or \`working:\` line never closes it, even when the answer is what started that work.
   Juggernaut's reply normally writes that closing line at answer time; when a blocker or wait clears WITHOUT a juggernaut reply, append \`resolved [at=<epoch>]: {how it cleared}\` yourself (same \`[key=<slug>]\` if you opened it with one) as you resume.
$SHARED_INFRA_RULE

8. When the merge gate needs done-done proof, run done-done once at your final head with a clean tree and confirm \`merge-card receipt <id> <head>\` exits 0, where <head> is the commit you will push. Commit nothing afterward, not even the receipt, because any later commit moves the PR head and voids the proof. If you must commit again, rerun done-done at the new head. The PR proof line must name the done-done run and say 'no verify skill'.

$WAIT_BLOCK$INBOX_SECTION

# Project memory
A project's \`AGENTS.md\` or \`CLAUDE.md\` is loaded into every agent session in that project, so edit it only to correct information that is factually wrong - including information your own change made wrong - and never to add knowledge because it is missing.
A correction edits only the wrong text: do not run \`$JG_ROOT/bin/jg-ensure-agents-md.sh\`, create either file, or add sections, headings, or pointers alongside it.

$DOD
EOF
append_brief_include
if [ "$FORGE" = none ]; then
  echo "scaffolded: $BRIEF (ship, mode=$MODE; replace {TASK} and {JUGGERNAUT_SPEC})"
elif [ "$FORGE" = gerrit ]; then
  echo "scaffolded: $BRIEF (ship, mode=$MODE forge=$FORGE shape=$SHAPE; replace {TASK} and {JUGGERNAUT_SPEC})"
else
  echo "scaffolded: $BRIEF (ship, mode=$MODE forge=$FORGE; replace {TASK} and {JUGGERNAUT_SPEC})"
fi
