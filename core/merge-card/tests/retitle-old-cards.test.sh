#!/usr/bin/env bash
# Fixture integration journey for the legacy merge-card retitle command.
# The producer's generic sentence reaches a card bare and qualified ("keyrepo #34: ..."); both are
# legacy, both are retitled from the pull request's own title, and a card that is already an outcome
# or whose PR title cannot be read is left alone.
set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d /var/tmp/retitle-old-cards.XXXXXX)
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/bin"
board=$work/board.json

cat >"$work/bin/sign-off-axi" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
cmd=$1
shift
case $cmd in
  list)
    file=$1
    jq -n --arg file "$file" --slurpfile board "$file" '{board:$file,decisions:$board[0].items}'
    ;;
  post)
    file=$1
    shift
    message=''
    while [ "$#" -gt 0 ]; do
      case $1 in --from) message=$2; shift 2 ;; *) shift ;; esac
    done
    jq --slurpfile msg "$message" '.items += [($msg[0] + {type:"evidence",filer:"juggernaut-merge",dismissed:false,evidence:$msg[0].run} | del(.run))]' "$file" >"$file.tmp"
    mv "$file.tmp" "$file"
    ;;
  dismiss)
    key=$1
    file=$2
    jq --arg key "$key" '.items |= map(if .key == $key then .dismissed=true else . end)' "$file" >"$file.tmp"
    mv "$file.tmp" "$file"
    ;;
  *) echo "unexpected sign-off-axi command: $cmd" >&2; exit 2 ;;
esac
STUB
chmod +x "$work/bin/sign-off-axi"

# The forge's own title for the pull request, as `gh pr view --json title --jq .title` prints it.
cat >"$work/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
case " $* " in
  *" --jq .title "*)
    case $* in
      *pull/12*) echo 'Cards say what shipped' ;;
      *pull/34*) echo '[feature] Refresh keeps the session alive (repo: app)' ;;
      *) exit 1 ;;
    esac
    ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$work/bin/gh"

jq -n '{schema:2,items:[
  {key:"merge-owner-linkrepo-pull-12",title:"Internal change passed its checks",about:"legacy one",link:"https://github.com/acme/linkrepo/pull/12",evidence:{run_id:"run-one",commit:"1111111111111111111111111111111111111111",outcome:"one",repro:"one",proof:"run one",evidence:"one"},type:"evidence",filer:"juggernaut-merge",dismissed:false},
  {key:"merge-north-keyrepo-pull-34",title:"keyrepo #34: internal change passed its checks",about:"legacy two",evidence:{run_id:"run-two",commit:"2222222222222222222222222222222222222222",outcome:"two",repro:"two",proof:"run two",evidence:"two"},type:"evidence",filer:"juggernaut-merge",dismissed:false},
  {key:"merge-north-keyrepo-pull-99",title:"keyrepo #99: internal change passed its checks",about:"no readable title",evidence:{run_id:"run-three",commit:"3333333333333333333333333333333333333333",outcome:"three",repro:"three",proof:"run three",evidence:"three"},type:"evidence",filer:"juggernaut-merge",dismissed:false},
  {key:"merge-owner-linkrepo-pull-13",title:"Ship the retitle dry run",about:"already an outcome",evidence:{run_id:"run-four",commit:"4444444444444444444444444444444444444444",outcome:"four",repro:"four",proof:"run four",evidence:"four"},type:"evidence",filer:"juggernaut-merge",dismissed:false},
  {key:"misc-card",title:"Internal change passed its checks",about:"unknown",type:"evidence",filer:"juggernaut-merge",dismissed:false}
]}' >"$board"

before=$(sha256sum "$board")
dry=$(PATH="$work/bin:$PATH" "$here/retitle-old-cards" "$board")
[[ "$dry" == *$'\tInternal change passed its checks -> Cards say what shipped'* ]]
[[ "$dry" == *$'keyrepo #34: internal change passed its checks -> Refresh keeps the session alive'* ]]
[[ "$dry" == *'would retitle 2 card(s); skipped 2'* ]]
[[ $(sha256sum "$board") == "$before" ]]

applied=$(PATH="$work/bin:$PATH" "$here/retitle-old-cards" --apply "$board")
[[ "$applied" == *'retitled 2 card(s); skipped 2'* ]]
jq -e '
  ([.items[] | select(.dismissed == true and .title == "Internal change passed its checks")] | length) == 1
  and ([.items[] | select(.dismissed == true and .title == "keyrepo #34: internal change passed its checks")] | length) == 1
  and ([.items[] | select(.dismissed != true and .title == "Cards say what shipped")] | length) == 1
  and ([.items[] | select(.dismissed != true and .title == "Refresh keeps the session alive")] | length) == 1
  and ([.items[] | select(.key == "misc-card" and .dismissed != true and .title == "Internal change passed its checks")] | length) == 1
  and ([.items[] | select(.key == "merge-north-keyrepo-pull-99" and .dismissed != true)] | length) == 1
  and ([.items[] | select(.key | startswith("merge-acme-linkrepo-pull-12-")) | .evidence.run_id] | sort) == ["run-one"]
  and ([.items[] | select(.key | startswith("merge-north-keyrepo-pull-34-")) | .evidence.run_id] | sort) == ["run-two"]
  and ([.items[] | select(.key | startswith("merge-acme-linkrepo-pull-12-")) | .link] == ["https://github.com/acme/linkrepo/pull/12"])
' "$board" >/dev/null
# The refusal check reads both forms: an outcome sentence is not generic, the qualified one is.
if bash "$here/merge-card" generic-title 'Refresh keeps the session alive'; then
  echo 'the refusal called an outcome sentence generic' >&2
  exit 1
fi
bash "$here/merge-card" generic-title 'keyrepo #34: internal change passed its checks'

again=$(PATH="$work/bin:$PATH" "$here/retitle-old-cards" --apply "$board")
[[ "$again" == *'retitled 0 card(s); skipped 2'* ]]
[[ $(jq '[.items[] | select(((.key | startswith("merge-acme-linkrepo-pull-")) or (.key | startswith("merge-north-keyrepo-pull-"))) and (.key | test("-[[:xdigit:]]{12}$")))] | length' "$board") == 2 ]]
echo 'all retitle-old-cards tests passed'
