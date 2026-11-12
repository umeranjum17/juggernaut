#!/usr/bin/env bash
# Live check 10 (stop 9, at the fleet's start and daily): an approval signed in the main home verifies in each lead home. A lead home
# verifies with Main's public key (core/owner-rules): its parent record must reach a home that holds a readable config/owner-rules-proof.pub.
# Lead homes come from data/squad_leads.md (`home: <path>;`).
# shellcheck source=tests/live/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
pub=$CONFIG/owner-rules-proof.pub; n=0; bad=''
[ -f "$pub" ] || live_red "main home has no public key at $pub"
openssl pkey -pubin -in "$pub" -noout 2>/dev/null || live_red "main home public key at $pub is unreadable"
while read -r home; do
  [ -d "$home" ] || continue
  n=$((n + 1)); h=$home; hops=0
  while [ -e "$h/.jg-squad-lead-parent" ] && [ "$hops" -lt 8 ]; do
    p=$(sed -n 's/^home=//p;s/^parent_home=//p' "$h/.jg-squad-lead-parent" | head -n 1)
    [ -d "$p" ] || break; h=$p; hops=$((hops + 1))
  done
  if [ "$h" = "$home" ] || ! cmp -s "$h/config/owner-rules-proof.pub" "$pub"; then bad="$bad ${home##*/}"; fi
done < <(sed -n 's/.*(.*home: \([^;)]*\);.*/\1/p' "$DATA/squad_leads.md" 2>/dev/null)
[ -z "$bad" ] || live_red "approval does not verify in:$bad"
live_pass "$n lead home(s) reach Main's key"
