#!/usr/bin/env bash
# merge-gate-lib.sh - the single config/merge-gate entry point, owned in one place.
# Sourced by owner-guard/install.sh, owner-guard/uninstall.sh, owner-rules/install.sh and
# owner-rules/uninstall.sh. Usage: . <core>/lib/merge-gate-lib.sh
#
# The home's merge gate is ONE file, config/merge-gate, which runs in this order: the
# owner-details scan (owner-guard), the owner-rules proof gate, then the home's own previous
# gate, kept at config/merge-gate.pre-chain. config/merge-gate.steps records which features are
# wired in, one `<name><TAB><command>` line per step, so an installer only adds or drops its own
# line and rewrites the file. Both installers call jgmg_install; both uninstallers jgmg_remove,
# and the last one out gives the home its own gate back.
#
# An older install chained three files (merge-gate -> merge-gate.pre-owner-rules ->
# merge-gate.pre-owner-guard); jgmg_collapse folds such a chain into the steps record and the
# kept gate, so a home that upgrades in place keeps both checks. For one release the two old
# chain paths stay behind as symlinks to the single file, so a script or note that still calls
# either one keeps working.

JG_MG_MARK='# juggernaut merge gate: one entry point'
JG_MG_OLD_LINK='^# (jg|fm)-owner-(rules|guard) merge gate$'
JG_MG_LINKS='pre-owner-guard pre-owner-rules'
JG_MG_FOLDED=()

jgmg_gate() { printf '%s/config/merge-gate\n' "$1"; }
jgmg_steps_file() { printf '%s/config/merge-gate.steps\n' "$1"; }
jgmg_prev_file() { printf '%s/config/merge-gate.pre-chain\n' "$1"; }
jgmg_guard_bin() { printf '%s/jg-owner-guard/owner-guard\n' "${XDG_DATA_HOME:-$HOME/.local/share}"; }
jgmg_present() { [ -e "$1" ] || [ -L "$1" ]; }

jgmg_is_ours() { [ -f "$1" ] && grep -qxF -- "$JG_MG_MARK" "$1" 2>/dev/null; }
jgmg_is_old_link() { [ -f "$1" ] && grep -qxE -- "$JG_MG_OLD_LINK" "$1" 2>/dev/null; }
# A gate this library or an older install of these two features wrote.
jgmg_owned() { jgmg_is_ours "$(jgmg_gate "$1")" || jgmg_is_old_link "$(jgmg_gate "$1")"; }
jgmg_in_folded() { # <path>: already absorbed by this collapse, so it is not the home's own gate
  local f
  [ "${#JG_MG_FOLDED[@]}" -gt 0 ] || return 1
  for f in "${JG_MG_FOLDED[@]}"; do [ "$f" != "$1" ] || return 0; done
  return 1
}

# The command an older chain link runs, read off the line its installer generated.
jgmg_cmd_of() { # <file> guard|rules
  case $2 in
  guard) sed -n 's/^\(.*\) merge-gate "\$@" || exit \$?$/\1/p' "$1" ;;
  *) sed -n 's/^\(.*\) "\$@" || exit \$?$/\1/p' "$1" ;;
  esac | head -n 1
}
# A path the installer wrote with printf %q comes back shell-quoted; the record keeps it bare.
jgmg_unquote() {
  case ${1-} in
  \'*\') printf '%s\n' "${1:1:${#1}-2}" ;;
  \"*\") printf '%s\n' "${1:1:${#1}-2}" ;;
  *) printf '%s\n' "${1-}" ;;
  esac
}

jgmg_step_get() { # <home> <name>: the recorded command, or nothing
  local file
  file=$(jgmg_steps_file "$1")
  [ -f "$file" ] || return 0
  awk -F'\t' -v n="$2" 'NF > 1 && $1 == n { print $2; exit }' "$file"
}
jgmg_steps_write() { # <home> <name> [<command>]: rewrite the record with this step set or (no command) dropped
  local home=$1 name=$2 cmd=${3-} file tmp
  file=$(jgmg_steps_file "$home")
  tmp=$file.tmp
  mkdir -p "$home/config" && {
    printf '# juggernaut merge gate steps: one <name><TAB><command> line per step, run in a fixed order.\n'
    printf '# Written by the feature installers; rerun one instead of editing this file.\n'
    [ ! -f "$file" ] || awk -F'\t' -v n="$name" 'NF > 1 && $1 != n' "$file"
    [ -z "$cmd" ] || printf '%s\t%s\n' "$name" "$cmd"
  } >"$tmp" || return 1
  mv -f -- "$tmp" "$file"
}
jgmg_names() { # <home>: the steps it runs, in order, as one readable phrase
  local guard rules out=''
  guard=$(jgmg_step_get "$1" guard)
  rules=$(jgmg_step_get "$1" rules)
  [ -z "$guard" ] || out='the owner-details scan'
  if [ -n "$rules" ]; then
    [ -z "$out" ] || out="$out, then "
    out="${out}the owner-rules proof gate"
  fi
  printf '%s\n' "$out"
}

# Fold an older install into the steps record: absorb each of our chain links, and keep the home's
# own gate, the first file in the chain that is not ours, at config/merge-gate.pre-chain. A gate
# that is not ours at all is that kept gate too, which is how a hand-written gate survives install.
jgmg_collapse() { # <home>
  local home=$1 gate prev_file file next cmd depth=0
  gate=$(jgmg_gate "$home")
  prev_file=$(jgmg_prev_file "$home")
  jgmg_present "$gate" || return 0
  jgmg_is_ours "$gate" && return 0
  file=$gate
  while [ "$depth" -lt 8 ] && jgmg_is_old_link "$file"; do
    if grep -qxE '^# (jg|fm)-owner-rules merge gate$' "$file"; then
      cmd=$(jgmg_cmd_of "$file" rules)
      [ -z "$cmd" ] || jgmg_steps_write "$home" rules "$(jgmg_unquote "$cmd")" || return 1
    elif grep -qxE '^# (jg|fm)-owner-guard merge gate$' "$file"; then
      cmd=$(jgmg_cmd_of "$file" guard)
      [ -z "$cmd" ] || jgmg_steps_write "$home" guard "$(jgmg_unquote "$cmd")" || return 1
    fi
    JG_MG_FOLDED+=("$file")
    next=$(sed -n 's/^prev=//p' "$file" | head -n 1)
    [ -n "$next" ] || { file=''; break; }
    file=$(jgmg_unquote "$next")
    depth=$((depth + 1))
  done
  [ -n "$file" ] && jgmg_present "$file" || return 0
  [ "$file" != "$prev_file" ] || return 0
  jgmg_in_folded "$file" && return 0
  if jgmg_present "$prev_file"; then
    if cmp -s "$file" "$prev_file"; then
      # The kept gate rewritten over ours: the same gate, so it is already chained.
      JG_MG_FOLDED+=("$file")
      return 0
    fi
    echo "error: $file is not ours and $prev_file exists; move one aside and rerun" >&2
    return 1
  fi
  mv -- "$file" "$prev_file" || return 1
  echo "kept: previous merge gate chained ($prev_file)"
}

# Drop the folded chain links once the single file is written. The gate and the kept gate stay.
jgmg_unfold() { # <home>
  local home=$1 f gate prev_file
  [ "${#JG_MG_FOLDED[@]}" -gt 0 ] || return 0
  gate=$(jgmg_gate "$home")
  prev_file=$(jgmg_prev_file "$home")
  for f in "${JG_MG_FOLDED[@]}"; do
    [ "$f" != "$gate" ] && [ "$f" != "$prev_file" ] || continue
    rm -f -- "$f"
  done
  JG_MG_FOLDED=()
}

# The two one-release symlinks, so an old script or note calling a chain path still works.
jgmg_links() { # <home>
  local home=$1 name path
  for name in $JG_MG_LINKS; do
    path=$home/config/merge-gate.$name
    jgmg_present "$path" && continue
    ln -s merge-gate "$path" || return 1
  done
}

jgmg_restore() { # <home>: no step left, so give the home its own previous gate back
  local home=$1 gate prev_file name path
  gate=$(jgmg_gate "$home")
  prev_file=$(jgmg_prev_file "$home")
  rm -f -- "$(jgmg_steps_file "$home")"
  jgmg_unfold "$home"
  for name in $JG_MG_LINKS; do
    path=$home/config/merge-gate.$name
    [ ! -L "$path" ] || [ "$(readlink -- "$path")" != merge-gate ] || rm -f -- "$path"
  done
  if jgmg_present "$prev_file"; then
    mv -f -- "$prev_file" "$gate" && echo "restored: previous merge gate $gate"
  elif jgmg_present "$gate"; then
    rm -f -- "$gate" && echo "removed: $gate (no previous gate)"
  fi
}

jgmg_write() { # <home>: write the one gate file, or give the home its own gate back
  local home=$1 gate prev_file guard rules tmp
  gate=$(jgmg_gate "$home")
  prev_file=$(jgmg_prev_file "$home")
  guard=$(jgmg_step_get "$home" guard)
  rules=$(jgmg_step_get "$home" rules)
  if [ -z "$guard" ] && [ -z "$rules" ]; then
    jgmg_restore "$home"
    return 0
  fi
  mkdir -p "$home/config" || return 1
  tmp=$home/config/.merge-gate.$$
  {
    printf '#!/usr/bin/env bash\n%s\n' "$JG_MG_MARK"
    printf '# One entry point: it runs the owner-details scan, the owner-rules proof gate, then the\n'
    printf "# home's own previous gate in config/merge-gate.pre-chain. Written by the feature\n"
    printf '# installers (core/lib/merge-gate-lib.sh); rerun owner-guard/install.sh or\n'
    printf '# owner-rules/install.sh instead of editing it.\n'
    if [ -n "$guard" ]; then
      printf '[[ -x %q ]] || { echo "merge refused: owner-guard is missing from this home; reinstall the owner-guard feature before merging: %s" >&2; exit 1; }\n' \
        "$guard" "$guard"
      printf '%q merge-gate "$@" || exit $?\n' "$guard"
    fi
    [ -z "$rules" ] || printf '%q "$@" || exit $?\n' "$rules"
    printf 'prev=%q\n' "$prev_file"
    # shellcheck disable=SC2016 # This is emitted code; $prev expands in the generated gate.
    printf '%s\n' '[ -e "$prev" ] || [ -L "$prev" ] || exit 0' \
      '[ -x "$prev" ] || { echo "merge refused: $prev is not executable"; exit 1; }' \
      'exec "$prev" "$@"'
  } >"$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 755 "$tmp" || { rm -f -- "$tmp"; return 1; }
  if cmp -s "$tmp" "$gate"; then
    rm -f -- "$tmp"
    echo "kept: $gate already runs: $(jgmg_names "$home") in order"
  else
    mv -f -- "$tmp" "$gate" || return 1
    echo "installed: $gate runs: $(jgmg_names "$home") in order"
  fi
  jgmg_unfold "$home"
  jgmg_links "$home"
}

jgmg_install() { # <home> <name> <command>: wire one feature's step in and write the gate
  local home=$1
  jgmg_collapse "$home" || return 1
  jgmg_steps_write "$home" "$2" "$3" || return 1
  jgmg_write "$home"
}

jgmg_remove() { # <home> <name>: drop one feature's step, rewriting or giving back the gate
  local home=$1
  jgmg_collapse "$home" || return 1
  jgmg_steps_write "$home" "$2" || return 1
  jgmg_write "$home"
}

jgmg_dry_run() { # <home>: print what an install would write, in the same words
  local home=$1 gate prev_file
  gate=$(jgmg_gate "$home")
  prev_file=$(jgmg_prev_file "$home")
  echo "would write: $gate (one entry point: the owner-details scan, then the owner-rules proof gate, then the home's own previous gate)"
  echo "would keep: $prev_file (the home's own previous gate, when the home has one)"
  echo "would link: $gate.pre-owner-guard and $gate.pre-owner-rules -> merge-gate (one release)"
}

jgmg_dry_run_remove() { # <home>: print what an uninstall would give back
  local home=$1 gate prev_file
  gate=$(jgmg_gate "$home")
  prev_file=$(jgmg_prev_file "$home")
  if ! jgmg_owned "$home"; then
    echo "would keep: $gate merge gate (not ours)"
  elif jgmg_present "$prev_file"; then
    echo "would restore: $prev_file -> $gate"
  else
    echo "would remove: $gate (no previous gate)"
  fi
}
