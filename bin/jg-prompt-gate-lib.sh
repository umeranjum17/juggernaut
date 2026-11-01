#!/usr/bin/env bash
# jg-prompt-gate-lib.sh - the supervision safety net for a worker or squad_lead
# pane parked on a harness permission or trust prompt. Sourced by
# bin/jg-watch.sh, which owns when it runs and what it does with a verdict.
#
# A visible prompt is stuck at once: it never clears without an answer.
# bin/jg-prompt-gate.py owns the matcher. It approves only an OpenCode read
# whose resolved path is inside this fleet's own roots, the ones
# jg_prompt_gate_verdict passes below: the task's steering inbox, its own
# state/<id>.<ext> files, state/pending-replies, its recorded worktree and home,
# the home and state/ folders themselves (not what is below them), and the
# home's read-only tooling (bin/, docs/, .agents/skills/, AGENTS.md).
# It rejects any OpenCode dialog naming a secrets path: a .env file, ~/.config,
# or the data/ or config/ folder of this home, the task's recorded home, or a
# local parent home. Every other prompt, including Claude, Pi, omp and Gemini
# trust dialogs (jg_busy_launch_prompt_parked), is left unanswered and rides the
# wait-timers escalation chain (core/wait-timers/README.md).
# config/prompt-approve-off turns approval off; rejection stays on.
# Every approval is one JSON line in state/prompt-approvals.jsonl, which
# bin/jg-fleet-snapshot.sh publishes and bin/jg-fleet-view.sh renders.

_jg_prompt_gate_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=bin/jg-harness-quirks-lib.sh
. "$_jg_prompt_gate_dir/jg-harness-quirks-lib.sh"

# jg_prompt_gate_harness: 0 when <harness> renders a prompt this gate reads. The
# runtime's table answers it: `read` for a dialog that names the tool and the path it
# resolves, `card` for one no key may answer, `none` for no such dialog at all.
jg_prompt_gate_harness() {  # <harness>
  case "$(jg_hq_value "${1:-}" trust_dialog)" in read | card) return 0 ;; esac
  return 1
}

# jg_prompt_gate_verdict: read a pane capture on stdin and print the gate's
# verdict line (approve|reject|card <TAB> ...), or nothing when no prompt is
# visible. A matcher that cannot run is a card, never silence.
jg_prompt_gate_verdict() {  # <harness> <home> <state> <config> <task> <meta>
  local harness=$1 home=$2 state=$3 config=$4 task=$5 meta=$6 buf out wt lead parent h path prompt
  local secrets=()
  buf=$(cat)
  case "$(jg_hq_value "$harness" trust_dialog)" in
    read)
      printf '%s' "$buf" | grep -q 'Permission required' || return 0
      wt=$(grep '^worktree=' "$meta" 2>/dev/null | cut -d= -f2- || true)
      lead=$(grep '^home=' "$meta" 2>/dev/null | cut -d= -f2- || true)
      parent=$(grep '^parent_home=' "$home/.jg-squad-lead-parent" 2>/dev/null | cut -d= -f2- || true)
      [ -z "${HOME:-}" ] || secrets+=(--secret "$HOME/.config")
      for h in "$home" "$lead" "$parent"; do
        case "$h" in /*) secrets+=(--secret "$h/data" --secret "$h/config") ;; esac
      done
      out=$(printf '%s\n' "$buf" | python3 "$_jg_prompt_gate_dir/jg-prompt-gate.py" "$harness" "${secrets[@]}" \
        --dir "inbox=$state/$task.inbox" --state-files "state=$state/$task" \
        --dir "pending-replies=$state/pending-replies" \
        ${wt:+--dir "worktree=$wt"} ${lead:+--dir "lead-home=$lead"} \
        --file "home-dir=$home" --file "state-dir=$state" \
        --dir "tooling=$home/bin" --dir "tooling=$home/docs" \
        --dir "tooling=$home/.agents/skills" --file "tooling=$home/AGENTS.md" 2>/dev/null | head -1) || out=
      [ -n "$out" ] || out=$(printf 'card\tthe prompt matcher could not run\t-\tPermission required')
      [ "$out" != none ] || return 0
      if [ "${out%%$'\t'*}" = approve ] && [ -e "$config/prompt-approve-off" ]; then
        IFS=$'\t' read -r _ _ path prompt <<< "$out"
        out=$(printf 'card\tauto-approval is off (config/prompt-approve-off)\t%s\t%s' "$path" "$prompt")
      fi
      printf '%s\n' "$out"
      ;;
    *)
      printf '%s' "$buf" | jg_busy_launch_prompt_parked "$harness" || return 0
      printf 'card\ta trust dialog is never auto-approved\t-\t%s launch trust dialog\n' "$harness"
      ;;
  esac
}

# jg_prompt_gate_log: append one approval record.
jg_prompt_gate_log() {  # <state> <task> <window> <harness> <root> <path> <prompt>
  jq -nc --arg task "$2" --arg window "$3" --arg harness "$4" --arg root "$5" \
    --arg path "$6" --arg prompt "$7" --argjson at "$(date +%s)" \
    '{at:$at,task:$task,window:$window,harness:$harness,tool:"read",path:$path,root:$root,prompt:$prompt}' \
    >> "$1/prompt-approvals.jsonl"
}
