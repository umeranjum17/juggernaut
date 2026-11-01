#!/usr/bin/env bash
# jg-compat shim (slice S4, deleted by S10): an old FM_* name still resolves
# here, so an unmigrated shell, unit, pane or record keeps this script working.
for _jg_old in $(compgen -v FM_ 2>/dev/null || true); do
  _jg_new="JG_${_jg_old#FM_}"
  declare -p "$_jg_new" >/dev/null 2>&1 && continue
  export "$_jg_new=${!_jg_old}"
done
unset _jg_old _jg_new 2>/dev/null || true
# install.sh - Juggernaut's one command for a clean machine.
#
#   curl -fsSL https://raw.githubusercontent.com/umeranjum17/juggernaut/main/install.sh | bash
#   bash install.sh [--home DIR] [--dry-run]
#
# It clones this repo into the home, writes our defaults and rules into the home once, installs every
# tool at the exact version in toolchain.versions (npm builds exactly, and the two curl-installed tools
# through bin/jg-bootstrap.sh's own installer), and names the logins only you can type.
# Installs stay user-local, in ~/.local/bin, the same prefix bin/jg-bootstrap.sh installs into, so nothing
# needs sudo, nothing touches a system prefix, and a tool installed here is the one a later bootstrap
# install replaces rather than a second copy in another directory.
# The one user-level default, learn-from-mistakes' account_picker, merges into ~/.learn-from-mistakes/config.yaml by key.
# A second run changes nothing: a tool already at its pinned version and a defaults file that already
# exists are reported and left alone. --dry-run prints the same plan and writes nothing.
set -euo pipefail

REPO_URL=${JG_INSTALL_REPO:-https://github.com/umeranjum17/juggernaut}
HOME_DIR='' DRY=no
while [ $# -gt 0 ]; do
  case $1 in
    --home) HOME_DIR=${2:?--home needs a directory}; shift 2 ;;
    --dry-run) DRY=yes; shift ;;
    -h|--help) awk 'NR > 1 && /^#/ { print; next } NR > 1 { exit }' "$0"; exit 0 ;;
    *) printf 'install: unknown argument %s\n' "$1" >&2; exit 2 ;;
  esac
done
HOME_DIR=${HOME_DIR:-$HOME/juggernaut}
say() { printf '%s\n' "$*"; }

# 1. Land the repo. Piped from curl there is no clone yet, so clone once and continue from it.
here=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd -P || true)
if [ ! -f "${here:-/nonexistent}/bin/jg-pin-lib.sh" ]; then
  if [ -f "$HOME_DIR/bin/jg-pin-lib.sh" ]; then
    say "repo: reusing the clone at $HOME_DIR"
  else
    say "repo: cloning $REPO_URL into $HOME_DIR"
    [ "$DRY" = no ] || exit 0
    git clone "$REPO_URL" "$HOME_DIR"
  fi
  args=(--home "$HOME_DIR"); [ "$DRY" = no ] || args+=(--dry-run)
  exec bash "$HOME_DIR/install.sh" "${args[@]}"
fi

root=$here
export JG_HOME=$HOME_DIR
# The same default prefix bin/jg-bootstrap.sh installs into, so one tool never ends up installed twice in
# two directories with PATH deciding which version runs. The directory is created and put on PATH before
# any install, because the two curl-installed tools write to a system prefix with sudo unless they find
# ~/.local/bin on PATH - which is how a clean machine ends up asking for a password this command promises
# never to need.
export NPM_CONFIG_PREFIX=${NPM_CONFIG_PREFIX:-$HOME/.local}
mkdir -p "$NPM_CONFIG_PREFIX/bin"
export PATH=$NPM_CONFIG_PREFIX/bin:$PATH
# shellcheck source=bin/jg-pin-lib.sh disable=SC1091
. "$root/bin/jg-pin-lib.sh"
say "home: $HOME_DIR"

# 2. Prerequisites only the user's own package manager can supply.
missing=
for t in node git gh; do command -v "$t" >/dev/null 2>&1 || missing="$missing $t"; done
if [ -n "$missing" ]; then
  say "needs you: install$missing first, then run this command again (node and git carry everything else)"
  exit 1
fi

# 3. Our defaults and rules, written once into a new home and never over another copy.
# This runs before the installs below, not after: installing done-done makes bin/jg-bootstrap.sh wire
# its own managed block into config/brief-include.md, and a file that already exists is one this step
# leaves alone, so writing afterwards would silently drop our rules from every fresh home.
# A template's name is its destination inside the home, spelled out here because the home's own
# config/ and data/ directories are gitignored and must never hold the template itself.
for src in "$root"/defaults/*.md; do
  [ -e "$src" ] || continue
  case ${src##*/} in
    brief-include.md) rel=config/brief-include.md ;;
    owner-rules.md) rel=data/owner-rules.md ;;
    *) say "defaults: skipped ${src##*/}, which names no destination"; continue ;;
  esac
  if [ -e "$HOME_DIR/$rel" ]; then
    say "defaults: kept the existing $rel"
    continue
  fi
  say "defaults: wrote $rel"
  [ "$DRY" = no ] || continue
  mkdir -p "$(dirname "$HOME_DIR/$rel")"
  cp "$src" "$HOME_DIR/$rel"
done

# 3b. learn-from-mistakes reads one user-level config, so its account picker merges in by key: a missing
# key is appended, a key the user already set (any value) is left alone, so a second run changes nothing.
ljg_cfg=$HOME/.learn-from-mistakes/config.yaml
ljg_tpl=$root/defaults/learn-from-mistakes.yaml
if [ -f "$ljg_tpl" ]; then
  if [ -f "$ljg_cfg" ] && grep -q '^account_picker:' "$ljg_cfg"; then
    say "defaults: kept the existing account_picker in $ljg_cfg"
  else
    say "defaults: wrote account_picker to $ljg_cfg"
    if [ "$DRY" = no ]; then
      mkdir -p "$(dirname "$ljg_cfg")"
      [ ! -s "$ljg_cfg" ] || [ -z "$(tail -c 1 "$ljg_cfg")" ] || printf '\n' >> "$ljg_cfg"
      sed "s|@ROOT@|$root|g" "$ljg_tpl" | grep -v '^#' >> "$ljg_cfg"
    fi
  fi
fi

# 4. Install every pinned tool: npm at exactly its row, curl-installed tools at or above their floor.
changed=0
while read -r tool spec _; do
  case "$tool" in ''|'#'*) continue ;; esac
  [ -n "${spec:-}" ] || continue
  want=$(jg_pin_version "$tool")
  have=$(bash "$root/bin/jg-bootstrap.sh" version "$tool" 2>/dev/null || true)
  if [ "$want" = not-yet-published ]; then
    say "$tool: skipped, not published as a versioned artifact yet"
    continue
  fi
  if [ "$have" = "$want" ]; then
    say "$tool: have $want"
    continue
  fi
  if ! jg_pin_npm "$tool" >/dev/null 2>&1 && [ -n "$have" ] \
     && [ "$(printf '%s\n%s\n' "$have" "$want" | sort -V | head -n 1)" = "$want" ]; then
    say "$tool: have $have (at least the $want floor)"
    continue
  fi
  if [ "$DRY" = yes ]; then
    say "$tool: would install the pinned $want (had ${have:-none})"
    continue
  fi
  bash "$root/bin/jg-bootstrap.sh" install "$tool"
  changed=$((changed + 1))
done < "$(jg_pin_file)"

# 4b. The services: the bus, the sidecar and ntfy, installed, enabled and started by the one command.
if [ "$DRY" = yes ]; then
  say "stack: would run bin/jg-stack.sh up"
else
  bash "$root/bin/jg-stack.sh" up || say "needs you: fix the line above, then run: bash $root/bin/jg-stack.sh up"
fi

# 5. Only the user can type these; this installer never holds or copies a login.
gh auth status >/dev/null 2>&1 || say "needs you: gh auth login   (GitHub access for projects and pull requests)"
say "needs you: sign in to your harness the way you normally do; the installer never keeps a login"

if [ "$DRY" = yes ]; then
  say "dry run: nothing was installed or written"
else
  if [ ! -f "$HOME_DIR/config/ai-engine.json" ]; then
    node "$root/bin/jg-ai-engine.mjs" setup
  fi
  say "done: $changed install(s) in $NPM_CONFIG_PREFIX/bin; add it to PATH if it is not there already"
  say "launch with: cd $HOME_DIR && claude"
  say "other harnesses: grok --trust | pi | omp | codex | opencode | cursor-agent --trust"
fi
