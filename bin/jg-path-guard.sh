#!/usr/bin/env bash
# jg-path-guard.sh - refuse a captain-facing line that carries a raw file path.
#
# Usage: jg-path-guard.sh [--mask] [<text>...]
#
# The captain reads on his phone and cannot open a file path. A line he reads
# must carry a board link or an attached picture instead. The text comes from
# the arguments, or from stdin when there are none, one line per check.
# Exit 0 when every line is clean; exit 1 with one refusal on stderr when a
# line carries a path and no way to open it.
#
# A path glued to a key (report=data/x.md) is a machine pointer that the
# channel readers resolve, not prose the captain reads, so it is not refused.
#
# A path is an absolute path (/home/..., /tmp/...), a home path (~/...), or a
# home-relative path (data/, state/, .treehouse/). A URL is not a path: it is
# removed before the check. A line is exempt when it also carries a board key
# (#reports/, #decide/, #designs/) or the marker "picture attached".
#
# --mask never refuses: it prints each line with every path token replaced by
# "[file path withheld]", and leaves a line that carries a board key or the
# picture marker unchanged. An automatic publisher uses it so a worker's
# evidence path cannot block delivery of a final outcome.
#
# The parent channel owner (bin/jg-parent-channel-lib.sh) runs this at write
# time, so the mistake is caught before the captain sees it.
set -u

MASK=0
if [ "${1-}" = --mask ]; then
  MASK=1
  shift
fi
if [ "$#" -gt 0 ]; then
  text=$(printf '%s\n' "$*")
else
  text=$(cat)
fi

path_re='(^|[^[:alnum:]_./:~=-])(/[[:alnum:]_.-]+/[^[:space:]]|~/|(\.treehouse|data|state)/[[:alnum:]_.-])'
key_re='#(reports|decide|designs)/|picture attached'

if [ "$MASK" = 1 ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    if printf '%s\n' "$line" | grep -Eiq -- "$key_re"; then
      printf '%s\n' "$line"
    else
      printf '%s\n' "$line" | sed -E \
        -e 's#(^|[[:space:]("'"'"'])(/[[:alnum:]_.-]+/[^[:space:]]*|~/[^[:space:]]*|(\.treehouse|data|state)/[[:alnum:]_.-][^[:space:]]*)#\1[file path withheld]#g'
    fi
  done <<EOT2
$text
EOT2
  exit 0
fi

bad=''
while IFS= read -r line || [ -n "$line" ]; do
  if printf '%s\n' "$line" | grep -Eiq -- "$key_re"; then
    continue
  fi
  stripped=$(printf '%s\n' "$line" | sed -E 's#[A-Za-z][A-Za-z0-9+.-]*://[^[:space:]]*#URL#g')
  if printf '%s\n' "$stripped" | grep -Eq -- "$path_re"; then
    bad=$line
    break
  fi
done <<EOT
$text
EOT

if [ -n "$bad" ]; then
  echo 'owner-rules: raw file path refused; the captain cannot open it on his phone - give a board link (#reports/, #decide/, #designs/) or write "picture attached"' >&2
  exit 1
fi
exit 0
