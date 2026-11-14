#!/usr/bin/env bash
# jg-home-shape-lib.sh - the shape of a home a go-live skipped, recorded in its data/trunk-in-use.tsv row and replayed.
#
# A skipped row gains a sixth column, the shape of the home as it stood against the target:
#   ancestry=<equal|behind|ahead|diverged>;index=<target|path:<n>|head|other>;dirty=<XY>:<path>,...
#     ancestry  HEAD against the target commit (behind = HEAD is an ancestor of the target)
#     index     the index tree: equal to the target's, to the tree of the n-th commit (oldest first) on the path
#               from HEAD to the target, to HEAD's own, or to none of those
#     dirty     every `git status --porcelain` entry, its two status letters with a space written `.`, and its path
#               (`,` `;` and control characters in a path become `?`); more than 20 end with `+<n>`
# A reader takes the fields it knows and ignores the rest: extra columns of a row, and keys of the shape it does not know.
#
#   jg_home_shape_record <dir> <target-commit>      print the shape of <dir> now
#   jg_home_shape_field <shape> <key>               print one key's value (nothing when absent)
#   jg_home_shape_from_row <tsv> <row-key> [sha]    print the shape column of the last skipped row of <row-key> (at <sha> when given)
#   jg_home_shape_apply <dir> <target-commit> <shape>   stage <dir>'s index and its untracked and edited files to match <shape>;
#                                                    HEAD stays where the caller put it. Returns 1 for a code it cannot rebuild.

jg_home_shape_record() { # <dir> <target-commit>
  local dir=$1 target=$2 head tgt anc idx want n tree entry xy path dirty="" count=0
  head=$(git -C "$dir" rev-parse HEAD 2>/dev/null) || return 1
  tgt=$(git -C "$dir" rev-parse --verify -q "$target^{commit}") || return 1
  if [ "$head" = "$tgt" ]; then anc=equal
  elif git -C "$dir" merge-base --is-ancestor "$head" "$tgt" 2>/dev/null; then anc=behind
  elif git -C "$dir" merge-base --is-ancestor "$tgt" "$head" 2>/dev/null; then anc=ahead
  else anc=diverged; fi
  idx=other
  if want=$(git -C "$dir" write-tree 2>/dev/null); then
    if [ "$want" = "$(git -C "$dir" rev-parse "$tgt^{tree}")" ]; then idx=target
    else
      n=0
      while read -r tree; do
        n=$((n + 1))
        [ "$tree" = "$want" ] && { idx="path:$n"; break; }
      done < <(git -C "$dir" log --reverse --format=%T "$tgt" --not "$head" 2>/dev/null)
      [ "$idx" != other ] || [ "$want" != "$(git -C "$dir" rev-parse "$head^{tree}")" ] || idx='head'
    fi
  fi
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    count=$((count + 1))
    [ "$count" -le 20 ] || continue
    xy=$(printf '%s' "${entry:0:2}" | tr ' ' '.')
    path=$(printf '%s' "${entry:3}" | LC_ALL=C tr ',;\t\r\n' '?????')
    dirty="${dirty:+$dirty,}$xy:$path"
  done < <(git -C "$dir" status --porcelain 2>/dev/null)
  [ "$count" -le 20 ] || dirty="$dirty,+$((count - 20))"
  printf 'ancestry=%s;index=%s;dirty=%s\n' "$anc" "$idx" "$dirty"
}

jg_home_shape_field() { # <shape> <key>
  printf '%s\n' "$1" | tr ';' '\n' | sed -n "s/^$2=//p" | head -n 1
}

jg_home_shape_from_row() { # <tsv> <row-key> [sha]
  awk -F'\t' -v k="$2" -v s="${3:-}" '$1 == k && $4 ~ /^skipped/ && $6 != "" && (s == "" || $2 == s) { l = $6 } END { print l }' "$1" 2>/dev/null
}

jg_home_shape_apply() { # <dir> <target-commit> <shape>
  local dir=$1 target=$2 shape=$3 idx dirty entry xy path n
  idx=$(jg_home_shape_field "$shape" index); dirty=$(jg_home_shape_field "$shape" dirty)
  case $idx in
    target) git -C "$dir" read-tree -u -m HEAD "$target" || return 1 ;;
    path:*)
      n=${idx#path:}
      git -C "$dir" read-tree -u -m HEAD "$(git -C "$dir" log --reverse --format=%H "$target" --not HEAD | sed -n "${n}p")" || return 1 ;;
  esac
  while [ -n "$dirty" ]; do
    entry=${dirty%%,*}; dirty=${dirty#"$entry"}; dirty=${dirty#,}
    xy=${entry%%:*}; path=${entry#*:}
    case $xy in
      '??') [ -e "$dir/$path" ] || printf 'untracked\n' > "$dir/$path" ;;
      .M) printf 'edit\n' >> "$dir/$path" ;;
      [MADRC].|+*|'') : ;; # a staged change is what the index step above rebuilt
      *) echo "jg_home_shape_apply: cannot rebuild status $xy for $path" >&2; return 1 ;;
    esac
  done
}
