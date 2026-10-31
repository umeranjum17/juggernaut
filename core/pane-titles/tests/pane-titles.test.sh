#!/usr/bin/env bash
# Hermetic launch-hook journey: fixture task/home records, prior hook chaining, title export, and reversible install.
# jg-compat shim (slice S4, deleted by S10): an old FM_* name still resolves
# here, so an unmigrated shell, unit, pane or record keeps this script working.
for _jg_old in $(compgen -v FM_ 2>/dev/null || true); do
  _jg_new="JG_${_jg_old#FM_}"
  declare -p "$_jg_new" >/dev/null 2>&1 && continue
  export "$_jg_new=${!_jg_old}"
done
unset _jg_old _jg_new 2>/dev/null || true

set -euo pipefail
ADDON=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
T=$(mktemp -d); trap 'rm -rf -- "$T"' EXIT
HOME=$T/user; FMH=$T/home; LEAD=$T/lead; XDG_DATA_HOME=$HOME/.local/share
mkdir -p "$HOME/bin" "$FMH/bin" "$FMH/config" "$FMH/state" "$FMH/data" "$LEAD/data" "$T/bin"
cat > "$FMH/state/muxr.meta" <<'EOF'
id=muxr
kind=ship
EOF
cat > "$FMH/data/backlog.md" <<'EOF'
- [ ] muxr - Scroll fix
EOF
cat > "$FMH/bin/jg-tasks-axi.sh" <<'EOF'
#!/usr/bin/env bash
[ "$1" = show ] && [ "$2" = muxr ] || exit 2
title=$(awk -F ' - ' '$1 == "- [ ] muxr" { print $2; exit }' "$JG_HOME/data/backlog.md")
printf '  title: %s\n' "$title"
EOF
chmod +x "$FMH/bin/jg-tasks-axi.sh"
cat > "$FMH/config/launch-env-hook" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "export KEEP_VALUE='chain'" > "$1"
EOF
chmod +x "$FMH/config/launch-env-hook"
cp "$FMH/config/launch-env-hook" "$T/original-hook"
printf '%s\n' '- crewhouse (home: '"$LEAD"'; scope: fixture)' > "$LEAD/data/squad_leads.md"
cat > "$T/bin/herdr" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$HERDR_LOG"
if [ "$1 $2 $3" = '--session fixture pane' ] && [ "$4" = current ]; then printf '{"result":{"pane":{"tab_id":"w1:t1"}}}\n'; fi
EOF
chmod +x "$T/bin/herdr"
export HOME XDG_DATA_HOME HERDR_SESSION=fixture HERDR_LOG=$T/herdr.log
export PATH="$T/bin:$PATH"
"$ADDON/wiring.sh" --dry-run "$FMH" >/dev/null
"$ADDON/wiring.sh" "$FMH" >/dev/null
"$ADDON/wiring.sh" "$FMH" >/dev/null
[ -f "$FMH/state/muxr.meta" ] || { echo 'worker metadata fixture missing' >&2; exit 1; }
JG_HOME="$FMH" JG_TASK_ID=muxr "$FMH/config/launch-env-hook" "$T/worker.exports" > "$T/worker.osc"
[ "$(bash -c '. "$1"; printf "%s|%s" "$KEEP_VALUE" "$CLAUDE_CODE_DISABLE_TERMINAL_TITLE"' _ "$T/worker.exports")" = 'chain|1' ]
grep -Fq $'\033]0;muxr: Scroll fix\007' "$T/worker.osc"
grep -Fq -- '--session fixture tab rename w1:t1 muxr: Scroll fix' "$HERDR_LOG"
env -u JG_TASK_ID JG_HOME="$LEAD" "$FMH/config/launch-env-hook" "$T/lead.exports" > "$T/lead.osc"
[ "$(bash -c '. "$1"; printf "%s" "$CLAUDE_CODE_DISABLE_TERMINAL_TITLE"' _ "$T/lead.exports")" = '1' ]
grep -Fq $'\033]0;Crewhouse lead\007' "$T/lead.osc"
grep -Fq -- '--session fixture tab rename w1:t1 Crewhouse lead' "$HERDR_LOG"
"$ADDON/unwiring.sh" --dry-run "$FMH" >/dev/null
"$ADDON/unwiring.sh" "$FMH" >/dev/null
"$ADDON/unwiring.sh" "$FMH" >/dev/null
cmp "$T/original-hook" "$FMH/config/launch-env-hook"
echo 'PASS: worker and lead titles, Claude switch, Herdr tab rename, chained hook, idempotence, uninstall'
