#!/usr/bin/env bash
# jg-lavish-session-check.sh - end this home's own Lavish sessions whose
# artifact has not changed for a day, and print one line per session closed.
#
# Usage:
#   jg-lavish-session-check.sh [--root <dir>]... [--min-age <seconds>] [--list-only]
#   jg-lavish-session-check.sh --install
#
# Lavish is retired. The binary stays installed on machines that have it, so a
# session left open on an old board keeps a browser page and a server lease
# alive. This check closes those sessions and reports each close on one line:
#
#   closed: <url> (idle <hours>h, <path>)
#
# Scope is deliberately narrow. Only sessions whose artifact lives under one of
# --root (default: this home) are touched, because Lavish's session store is
# shared by every home and project on the machine and closing another lane's
# page would be an uninvited act on work this home does not own. A session is
# "older than a day" when its artifact's mtime is older than --min-age
# (default 86400 seconds); the store itself carries no timestamps.
#
# With nothing to close it prints nothing and exits 0, so it is quiet as a
# watcher check. --list-only reports without ending anything. --install writes
# state/lavish-session.check.sh and binds it with bin/jg-check-register.sh, so
# the watcher sweeps it on its ordinary cadence.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JG_ROOT="${JG_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
JG_HOME="${JG_HOME:-${JG_ROOT_OVERRIDE:-$JG_ROOT}}"
STATE="${JG_STATE_OVERRIDE:-$JG_HOME/state}"
STORE="${LAVISH_AXI_STATE_DIR:-$HOME/.lavish-axi}/state.json"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }

list_only=0
min_age=86400
roots=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --root)
      [ "$#" -ge 2 ] || die "--root needs a directory"
      roots+=("$2")
      shift 2
      ;;
    --min-age)
      [ "$#" -ge 2 ] || die "--min-age needs whole seconds"
      case "$2" in ''|*[!0-9]*) die "--min-age needs whole seconds: $2" ;; esac
      min_age=$2
      shift 2
      ;;
    --list-only) list_only=1; shift ;;
    --install) install=1; shift ;;
    -h|--help)
      sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) die "unknown argument: $1" ;;
  esac
done
install=${install:-0}
[ "${#roots[@]}" -gt 0 ] || roots=("$JG_HOME")

if [ "$install" = 1 ]; then
  [ -d "$STATE" ] || die "state directory is unavailable: $STATE"
  check="$STATE/lavish-session.check.sh"
  [ ! -e "$check" ] || [ ! -L "$check" ] || die "refusing a symlinked check path: $check"
  printf '#!/usr/bin/env bash\n# Registered sweep: %s/jg-lavish-session-check.sh\nJG_HOME=%q exec %q --root %q\n' \
    "$SCRIPT_DIR" "$JG_HOME" "$SCRIPT_DIR/jg-lavish-session-check.sh" "$JG_HOME" > "$check" \
    || die "cannot write $check"
  chmod 0700 "$check" || die "cannot make $check executable"
  "$SCRIPT_DIR/jg-check-register.sh" lavish-session || die "cannot register the check"
  printf 'registered: lavish-session\n'
  exit 0
fi

[ -f "$STORE" ] || exit 0
command -v lavish-axi >/dev/null 2>&1 || exit 0

# Resolve the roots once, physically, so a symlinked home still matches.
resolved_roots=$(for r in "${roots[@]}"; do
  [ -d "$r" ] && (cd "$r" && pwd -P)
done)

now=$(date +%s)
closed=0
while IFS=$'\t' read -r file url; do
  [ -n "$file" ] || continue
  owned=0
  while IFS= read -r root; do
    [ -n "$root" ] || continue
    case "$file" in "$root"/*) owned=1; break ;; esac
  done <<EOF
$resolved_roots
EOF
  [ "$owned" = 1 ] || continue
  [ -f "$file" ] || continue
  mtime=$(perl -e 'my @s = stat $ARGV[0] or exit 1; print "$s[9]\n"' "$file" 2>/dev/null) || continue
  age=$((now - mtime))
  [ "$age" -ge "$min_age" ] || continue
  hours=$((age / 3600))
  if [ "$list_only" = 1 ]; then
    printf 'open: %s (idle %sh, %s)\n' "$url" "$hours" "$file"
    continue
  fi
  if lavish-axi end "$file" >/dev/null 2>&1; then
    printf 'closed: %s (idle %sh, %s)\n' "$url" "$hours" "$file"
    closed=$((closed + 1))
  fi
done < <(perl -MJSON::PP -MEncode=decode -e '
  use strict; use warnings;
  my $path = shift;
  open my $fh, "<", $path or exit 1;
  local $/;
  my $state = eval { decode_json(<$fh>) };
  exit 1 unless ref($state) eq "HASH" && ref($state->{sessions}) eq "HASH";
  for my $session (values %{$state->{sessions}}) {
    next unless ref($session) eq "HASH";
    my $status = defined $session->{status} ? $session->{status} : "";
    next unless $status eq "open";
    my $file = defined $session->{file} ? eval { decode("UTF-8", $session->{file}, 0) } : undef;
    my $url = defined $session->{url} ? $session->{url} : "";
    next unless defined $file && length $file;
    $file =~ s/\t/ /g;
    $url =~ s/\t/ /g;
    print "$file\t$url\n";
  }
' "$STORE")
exit 0
