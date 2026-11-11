#!/usr/bin/env bash
# jg-fleet-view.sh - human renderer over jg-fleet-snapshot.sh.
#
# This command intentionally does not parse fleet state itself.
# It shells out to jg-fleet-snapshot.sh --json and renders that stable
# structured contract for humans. Its Overwatch KPI section comes from the
# local scorecard in bin/jg-overwatch-kpi.sh, so a render makes no network call.
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
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
usage: jg-fleet-view.sh [--json]

Render a human fleet view from jg-fleet-snapshot.sh.
Use --json to print the underlying snapshot.
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  --json) "$SCRIPT_DIR/jg-fleet-snapshot.sh" --json; exit $? ;;
  "") ;;
  *) usage >&2; exit 2 ;;
esac

command -v jq >/dev/null 2>&1 || { echo "jg-fleet-view: jq not found" >&2; exit 1; }

SNAPSHOT=$("$SCRIPT_DIR/jg-fleet-snapshot.sh" --json) || exit $?
# The Overwatch KPI reads the local ledger only, so it renders without a network
# call; the per-miss landed verdict stays in `jg-overwatch-kpi.sh scorecard --landed`.
KPI=$("$SCRIPT_DIR/jg-overwatch-kpi.sh" scorecard --json 2>/dev/null) || KPI='{}'

printf '%s\n' "$SNAPSHOT" | jq -r --argjson kpi "$KPI" '
  def kpi_n($v): if $v == null then 0 else $v end;
  def dash($v): if $v == null or $v == "" then "-" else $v end;
  def endpoint_exists($t):
    if $t.endpoint.exists == null then "unknown"
    elif $t.endpoint.exists then "present"
    else "absent" end;
  def endpoint_of($t):
    if $t.kind == "squad_lead" then "\(endpoint_exists($t)) / \($t.endpoint.agent_alive)"
    else endpoint_exists($t) end;
  def artifact($t):
    if $t.pr.url != null then $t.pr.url
    elif $t.paths.report.present then $t.paths.report.path
    else "-" end;
  def path_of($t):
    if $t.paths.home.present then $t.paths.home.path
    elif $t.paths.home.path != null then $t.paths.home.path + " (absent)"
    elif $t.paths.worktree.present then $t.paths.worktree.path
    elif $t.paths.worktree.path != null then $t.paths.worktree.path + " (absent)"
    else "-" end;
  def action_of($t):
    if $t.kind == "squad_lead" then "\($t.actions.send) - \($t.actions.watch)"
    else $t.actions.watch end;
  def task_row($t):
    "| \($t.id) | \($t.current_state.state) / \($t.current_state.source) | \($t.kind) | \(dash($t.backlog.repo // $t.project)) | \($t.backend) | \(endpoint_of($t)) | \(artifact($t)) | \(path_of($t)) | \(action_of($t)) |";
  def blocker($r):
    if ($r.blocked_by // "") == "" then "-"
    elif ($r.blocked_reason // "") == "" then $r.blocked_by
    else "\($r.blocked_by) - \($r.blocked_reason)" end;
  def backlog_row($r):
    "| \($r.id // "-") | \(dash($r.title // $r.raw)) | \(dash($r.repo)) | \(dash($r.kind)) | \(blocker($r)) | \(dash($r.pr_url // $r.report_path // $r.local_note)) |";

  "# Fleet View",
  "",
  "Schema: \(.schema)",
  "Home: \(.jg_home)",
  "",
  "## Overwatch KPI (target 0 misses)",
  "Day \($kpi.day.date // "-"): \(kpi_n($kpi.day.feedback)) feedback, \(kpi_n($kpi.day.micromanagement)) micromanagement.",
  "Week \($kpi.week.start // "-") to \($kpi.week.end // "-"): \(kpi_n($kpi.week.feedback)) feedback, \(kpi_n($kpi.week.micromanagement)) micromanagement.",
  (if (($kpi.misses // []) | length) == 0 then "No miss in the last week."
   else ([$kpi.misses[] | "miss #\(.seq) \(.date) \(.kind) \(.link)"] | join("; ")) end),
  "",
  "## Under Way",
  (if (.tasks | length) == 0 then
    "No live task metadata found."
   else
    "| ID | Current | Kind | Repo/Project | Backend | Endpoint | Artifact | Path | Watch / return channel |",
    "| --- | --- | --- | --- | --- | --- | --- | --- | --- |",
    (.tasks[] | task_row(.))
   end),
  "",
  "## Queued",
  (if ([.backlog.records[]? | select(.state == "queued")] | length) == 0 then
    "No queued backlog records found."
   else
    "| ID | Title | Repo | Kind | Blocked By | Artifact |",
    "| --- | --- | --- | --- | --- | --- |",
    (.backlog.records[] | select(.state == "queued") | backlog_row(.))
   end),
  "",
  "## Done",
  (if ([.backlog.records[]? | select(.state == "done")] | length) == 0 then
    "No done backlog records found."
   else
    "| ID | Title | Repo | Kind | Blocked By | Artifact |",
    "| --- | --- | --- | --- | --- | --- |",
    (.backlog.records[] | select(.state == "done") | backlog_row(.))
   end),
  "",
  "## SquadLeads",
  ([.squad_lead_current.records[]? | select(.idle_with_ready_work)]
   | if length == 0 then empty
     else (.[] | "IDLE WITH READY WORK: \(.id) has \(.ready_work) ready backlog item(s) and no worker running; it should be dispatching them (P0 first)."), "" end),
  .squad_lead_guidance.note,
  (if ((.prompt_approvals // []) | length) == 0 then empty
   else "", "## Permission Prompts Auto-Approved",
     "| At | ID | Window | Path | Root |",
     "| --- | --- | --- | --- | --- |",
     (.prompt_approvals[] | "| \(.at | todate) | \(.task) | \(.window) | \(.path) | \(.root) |")
   end)
' | bash "$SCRIPT_DIR/../core/machines/observers/task.sh" columns
