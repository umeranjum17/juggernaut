#!/usr/bin/env bash
# Model-error observation, called by jg-watch.sh before stale suppression.
# OpenCode lanes use explicit provider banners in the visible viewport,
# never scrollback or worker-printed "Error:" lines. Unchanged error observations
# alert at the next scan even if retrying. Unknown/dead endpoints are not
# restarted by this observer. Existing waiting timers own overdue escalation.
# Scans run at most once per 60s, so an idle failure alerts at the first scan
# after it appears, up to 60s later. Each scan reads every recorded lane's
# liveness serially, bounded to 3s each, before the stale checks in the same
# poll, so a slow endpoint can delay them. Mid-turn OpenCode lanes are read
# for the persistent usage-limit banner only; every other error is named
# once the lane is idle.
# Each normalized error is one durable episode; a lane joining an alerted episode
# sends one updated grouped wake naming the lanes failing in that scan.
# The wake queue owns delivery; restart does not repeat an already queued alert.
# No settings/model changes or recovery. The existing blocked/wait escalation
# owns subsequent attention. Each scan reads only this home's recorded lanes.

# Sibling libraries live in the fork's bin/, not beside this feature file: the
# watcher sets SCRIPT_DIR, other callers JG_HOME.
# jg-compat shim (slice S4, deleted by S10): an old FM_* name still resolves
# here, so an unmigrated shell, unit, pane or record keeps this script working.
for _jg_old in $(compgen -v FM_ 2>/dev/null || true); do
  _jg_new="JG_${_jg_old#FM_}"
  declare -p "$_jg_new" >/dev/null 2>&1 && continue
  export "$_jg_new=${!_jg_old}"
done
unset _jg_old _jg_new 2>/dev/null || true

_JG_MODEL_ERROR_DIR="${SCRIPT_DIR:-$JG_HOME/bin}"
# shellcheck source=bin/jg-timeout-lib.sh
. "$_JG_MODEL_ERROR_DIR/jg-timeout-lib.sh"
# Parked-home reader (juggernaut-addons/parked-homes): the watcher defines it;
# without it nothing is ever parked.
declare -F jg_parked_meta >/dev/null || jg_parked_meta() { return 1; }
# The usage-limit banner pattern has one owner, bin/jg-composer-lib.sh; this
# observer reads that variable so the outage alert cannot drift from the
# staleness furniture the banner was captured with.
# shellcheck source=bin/jg-composer-lib.sh
. "$_JG_MODEL_ERROR_DIR/jg-composer-lib.sh"

jg_model_outage_text() {
  LC_ALL=C tr -c '[:print:]' ' ' | awk '{$1=$1; print}' | cut -c1-1000
}

jg_model_outage_tick() {
  local meta id backend target harness gen error hash old verdict rows groups mid line key lanes alert kept floor n row trimmed
  # shellcheck disable=SC2153 # STATE is set by the watcher (jg-watch.sh); the sourced composer lib's lowercase `state` is unrelated.
  local dir="$STATE/.model-outages" now batch last current
  now=$(date +%s) || return 1
  # The singleton watcher owns these records; never start a second monitor.
  [ ! -L "$dir" ] || return 1
  (umask 077; mkdir -p "$dir") || return 1
  last=$(cat "$dir/.scan-at" 2>/dev/null) || last=0
  [ $((now - last)) -ge 60 ] || [ $((now - last)) -lt 0 ] || return 0
  printf '%s\n' "$now" > "$dir/.scan-at" || return 1
  batch=$(mktemp -d "$dir/.scan.XXXXXX") || return 1
  trap 'rm -rf "$batch"; trap - RETURN' RETURN
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    id=${meta##*/}; id=${id%.meta}
    jg_busy_token_valid "$id" || continue
    # Parked-home guard (juggernaut-addons/parked-homes): a parked home's lane
    # is never scanned and never alerts. No-op without the feature checkout.
    if jg_parked_meta "$meta" "$id"; then continue; fi
    target=$(jg_backend_target_of_meta "$meta")
    [ -n "$target" ] || continue
    backend=$(jg_backend_of_meta "$meta")
    harness=$(jg_meta_get "$meta" harness)
    gen=$(jg_busy_current_gen "$STATE" "$id") || gen=unarmed
    error=; key=; line=
    [ "$harness" = opencode ] || continue
    # shellcheck disable=SC2016 # The child expands its own positional arguments.
    verdict=$(jg_run_timed 3 bash -c '. "$1/jg-backend.sh"; . "$1/jg-busy-lib.sh"; jg_busy_classify_semantic "$2" "$3" "$4" "$5" "$6"' \
      model-error "$_JG_MODEL_ERROR_DIR" "$backend" "$target" "$harness" "$id" "$STATE") \
      || continue
    mid=0
    if [ "${verdict%% *}" = busy ]; then mid=1; fi
    # Bound reads on every backend; a vanished/slow endpoint cannot hang the
    # rest of the fleet scan. Never discover another home's unrecorded panes.
    # shellcheck disable=SC2016 # The child expands its own positional arguments.
    rows=$(jg_run_timed 3 bash -c '. "$1/jg-backend.sh"; jg_backend_agent_state "$2" "$3" "$4" "$5"' \
      model-error "$_JG_MODEL_ERROR_DIR" "$backend" "$target" "$meta" "$id") || continue
    case "$rows" in alive) ;; dead|missing) rm -f "$dir/lane-$id"; continue ;; *) continue ;; esac
    if jg_backend_visible_capture_supported "$backend"; then
      # shellcheck disable=SC2016 # The child expands its own positional arguments.
      rows=$(jg_run_timed 3 bash -c '. "$1/jg-backend.sh"; jg_backend_visible_capture "$2" "$3"' \
        model-error "$_JG_MODEL_ERROR_DIR" "$backend" "$target") || continue
      # Only explicit provider/harness banners, never worker-printed output; a
      # wrapped banner keeps up to two continuation lines. The provider-error
      # read stays idle-only: a mid-turn lane is matched against the
      # usage-limit banner alone, the one outage that persists for hours while
      # a limited lane sits mid-turn retrying. The banner is read only directly
      # below the composer floor, OpenCode's own status area, so a banner-shaped
      # line printed above the composer never counts.
      if [ "$mid" = 0 ]; then
        line=$(printf '%s\n' "$rows" | grep -Ein '^[[:space:]│┃]*(Upstream request failed|Model .+ is not supported|rate.?limit exceeded|insufficient quota|authentication failed)' | tail -1 | cut -d: -f1)
      fi
      if [ -n "$line" ]; then
        key=$(printf '%s\n' "$rows" | sed -n "${line}p")
      else
        floor=0; n=0
        while IFS= read -r row; do
          n=$((n + 1)); trimmed=$row
          jg_composer_normalize_trim_var trimmed
          if _jg_composer_leftbar_floor_row "$trimmed"; then floor=$n; fi
        done <<< "$rows"
        if [ "$floor" -gt 0 ] && printf '%s\n' "$rows" | sed -n "$((floor + 1))p" | grep -Eq "$JG_COMPOSER_OPENCODE_LIMIT_BANNER_RE_DEFAULT"; then
          line=$((floor + 1))
        fi
        # The banner's reset and retry clocks tick every scan; digits fold
        # out of the episode key so one limit event stays one episode while
        # the displayed error keeps the live countdown.
        if [ -n "$line" ]; then
          key=$(printf '%s\n' "$rows" | sed -n "${line}p" | sed 's/[0-9][0-9]*/#/g')
        fi
      fi
      if [ -n "$line" ]; then
        error=$(printf '%s\n' "$rows" | sed -n "${line},$((line + 2))p")
      fi
    fi
    error=$(printf '%s' "$error" | jg_model_outage_text)
    if [ -z "$error" ]; then rm -f "$dir/lane-$id"; continue; fi
    key=$(printf '%s' "${key:-$error}" | jg_model_outage_text)
    hash=$(printf '%s' "$key" | hash_pane)
    old=$(cat "$dir/lane-$id" 2>/dev/null) || old=
    printf '%s\n' "$target|$gen|$hash" > "$dir/lane-$id" || return 1
    printf '%s\n' "$id" >> "$batch/$hash.lanes"
    printf '%s\n' "$error" > "$batch/$hash.error"
    if [ "${verdict%% *}" = idle ] || [ "$old" = "$target|$gen|$hash" ]; then touch "$batch/$hash.ready"; fi
  done
  for file in "$dir"/lane-*; do
    [ -f "$file" ] || continue
    id=${file##*/lane-}
    [ -f "$STATE/$id.meta" ] || rm -f "$file"
  done
  # Forget episodes only after the whole scan, and only when no lane read failing.
  for file in "$dir"/alert-*; do
    [ -f "$file" ] || continue
    hash=${file##*/alert-}
    [ -f "$batch/$hash.lanes" ] || rm -f "$file"
  done
  groups=
  for lanes in "$batch"/*.lanes; do
    [ -f "$lanes" ] || continue
    hash=${lanes##*/}; hash=${hash%.lanes}
    alert="$dir/alert-$hash"
    [ -f "$alert" ] || : > "$alert" || return 1
    # The alert record holds the lanes named and still failing. A recovered lane
    # leaves it, so its later failure with the same error names it again.
    if [ -f "$batch/$hash.ready" ] && grep -qvxFf "$alert" "$lanes"; then
      current=$(sort -u "$lanes")
      rows=$(printf '%s\n' "$current" | paste -sd ',' -)
      error=$(cat "$batch/$hash.error")
      verdict="check: model outage affected=[$rows]: $error"
      jg_wake_append check "model-outage-$hash" "$verdict" || return 1
      groups="${groups}${verdict}"$'\n'
      kept=$current
    else
      kept=$(grep -Fxf "$alert" "$lanes" | sort -u)
    fi
    if [ -n "$kept" ]; then printf '%s\n' "$kept" > "$alert" || return 1; else : > "$alert" || return 1; fi
  done
  rm -rf "$batch"
  # All groups were queued before the first wake can exit the watcher.
  [ -z "$groups" ] || wake "${groups%$'\n'}"
  return 0
}

# Push-transition suppression, called by the fork's handle_push_transition: a
# cursor-harness task or one with an open captain call is committed without
# escalating. Returns 0 to suppress; non-zero (never suppress) when the
# watcher's helpers are not in scope.
jg_alerts_push_suppress() {  # <task>
  declare -F jg_meta_get >/dev/null && declare -F task_captain_call_open >/dev/null || return 1
  [ "$(jg_meta_get "$STATE/$1.meta" harness)" = cursor ] || task_captain_call_open "$1"
}
