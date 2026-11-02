#!/usr/bin/env bash
# jg-role-lib.sh - the Juggernaut home role and self-repository publication consent.
#
# Every Juggernaut home runs as a user/operator by default: it may consume
# juggernaut, change its gitignored operational state, and repair the installation
# locally, but nothing it does publishes to the juggernaut repository's upstream.
# Upstream publication - a pushed branch, pull request, issue, comment, or fork -
# requires an explicit, home-local grant: the maintainer opt-in written by the
# operator into config/juggernaut-role, or a bounded per-task consent recorded at
# dispatch. Role is never inferred from gh identity, permissions, remotes,
# environment, or CI. docs/configuration.md "Juggernaut role" owns the
# operator-facing schema; this library owns parsing, repository-identity
# normalization, self-repository detection, and the fail-closed gate the dispatch
# surfaces share. Everything here resolves from files and local git plumbing
# only; nothing calls gh or the network.
#
# Role file: one directive line in config/juggernaut-role (blank lines and
# full-line # comments ignored), either
#   user                                 - the default; may be omitted
#   maintainer <host>/<owner>/<repo>     - this home develops juggernaut for the
#                                          named upstream
# A scope names the publication target repository (where a PR lands), not a push
# destination. In a squad_lead home (marked by .jg-squad-lead-home) a role file
# authorizes nothing on its own: it is trusted only when the existing
# config-inheritance receipt config/.jg-inherit-juggernaut-role.generation proves
# the exact bytes the parent last published there, so a stale or unproven grant
# is dead on arrival. The parent publishes its resolved role
# (jg_role_inherit_payload), never its raw file, so a child never gains through
# supported propagation a grant the parent does not resolve. The receipt proves
# consistency, not provenance: it prevents accidental publication through
# supported paths and is not a security boundary against a process that
# deliberately forges local records.
#
# Self-repository detection compares the task's project dir against the running
# code root by repository lineage, offline: a shared git common dir covers
# linked worktrees and the code root itself, and a project holding a root commit
# of the code root's history covers any fork, the parent, and any clone of
# either. Lineage that cannot be determined (no code root history, or a shallow
# side sharing no root) refuses rather than permits. The publication target is
# compared only against a maintainer scope or task consent: the first remote
# named upstream, github, or origin (the order gh prefers when resolving a
# default repository), reduced to lowercase host/owner/repo; a local-path remote
# is resolved one hop through that repository's own origin, and left as
# path:<abs> when unreadable. An unknown target never permits.
#
# Public functions:
#   jg_role_file <config-dir>            - the role file path
#   jg_role_scope_valid <scope>          - host/owner/repo[/subgroup] shape check
#   jg_role_scope_norm <scope>           - canonical comparison form
#   jg_role_remote_identity <url> [<dir>]- host/owner/repo or path:<abs> or empty
#   jg_role_publication_target <git-dir> - identity a default publication reaches
#   jg_role_self_repo <project> <root>   - 0 juggernaut lineage, 1 not, 2 unknown
#   jg_role_parse_file <file>            - sets JG_ROLE/JG_ROLE_SCOPE/JG_ROLE_DIAG
#   jg_role_resolve <home> <config-dir>  - effective role; adds JG_ROLE_SOURCE
#   jg_role_inherit_payload <home> <config-dir> <out-file>
#                                        - stage the resolved role a parent publishes
#   jg_role_gate_self_publish <home> <config> <project> <root> [consent]
#                                        - 0 authorized, 1 refused, 2 not self-repo
#
# Global outputs: JG_ROLE (user|maintainer), JG_ROLE_SCOPE (maintainer scope),
# JG_ROLE_SOURCE (absent|local|inherited), JG_ROLE_DIAG (narrow refusal or
# malformed-input reason), JG_ROLE_PUB_TARGET, JG_ROLE_PUB_AUTHORITY,
# JG_ROLE_PUB_DENIAL.

# jg_role_file <config-dir>
jg_role_file() {
  jg_compat_pick "${1%/}/juggernaut-role"
}

# jg_role_inherit_receipt <config-dir> - receipt written by the inheritance
# machinery (remote receiver, or the local route's own bookkeeping).
jg_role_inherit_receipt() {
  jg_compat_pick "${1%/}/.jg-inherit-juggernaut-role.generation"
}

# jg_role_scope_valid <scope> - 0 when <scope> is <host>/<owner>/<repo>
# (deeper paths allowed for group-style hosts) over a conservative charset.
jg_role_scope_valid() {
  case $1 in
  */*/*) ;;
  *) return 1 ;;
  esac
  case $1 in
  *[!A-Za-z0-9._/-]* | .* | */ | *//* | *..*) return 1 ;;
  esac
  return 0
}

# jg_role_scope_norm <scope> - canonical comparison form.
jg_role_scope_norm() {
  printf '%s\n' "$1" | tr '[:upper:]' '[:lower:]'
}

# jg_role_abs_norm <path> - physical path when it exists, else a lexical
# collapse of . and .. so a not-yet-existing path still compares determinably.
jg_role_abs_norm() {
  local p=$1 seg out=
  if [ -d "$p" ]; then
    (CDPATH='' cd -- "$p" && pwd -P)
    return
  fi
  case $p in
  /*) ;;
  *) printf '%s\n' "$p"; return ;;
  esac
  local oldifs=$IFS
  IFS='/'
  set -f
  for seg in $p; do
    case $seg in
    '' | .) ;;
    ..) out=${out%/*} ;;
    *) out=$out/$seg ;;
    esac
  done
  IFS=$oldifs
  set +f
  printf '%s\n' "${out:-/}"
}

# jg_role_local_identity <path> [<base-dir>] - a local-path remote resolves one
# hop through that repository's own origin; unreadable or origin-less targets
# stay path:<absolute>. The hop is never transitive: a local origin there is
# itself reported as path:<absolute>, which keeps mutually-referencing local
# clones from resolving each other forever.
jg_role_local_identity() {
  local p=$1 base=${2:-} abs inner
  case $p in
  \~/*) p=$HOME/${p#\~/} ;;
  esac
  case $p in
  /*) abs=$p ;;
  *) abs=${base:+$base/}$p ;;
  esac
  abs=$(jg_role_abs_norm "$abs")
  if inner=$(git -C "$abs" remote get-url origin 2>/dev/null) && [ -n "$inner" ]; then
    jg_role_remote_identity "$inner" "$abs" nolocal
    return
  fi
  printf 'path:%s\n' "$abs"
}

# jg_role_path_identity <path> [<base-dir>] - path:<absolute> for a local-path
# remote with no further resolution (the nolocal reporting form).
jg_role_path_identity() {
  local p=$1 base=${2:-} abs
  case $p in
  /*) abs=$p ;;
  *) abs=${base:+$base/}$p ;;
  esac
  printf 'path:%s\n' "$(jg_role_abs_norm "$abs")"
}

# jg_role_remote_identity <url> [<base-dir>] [<nolocal>] - normalize a remote
# URL to lowercase host/owner/repo. scheme://[user@]host[:port]/owner/repo and
# [user@]host:owner/repo both reduce; .git suffixes drop; a local-path remote
# (absolute, relative, or file://) resolves through jg_role_local_identity,
# except under nolocal, where it reports path:<absolute> directly.
jg_role_remote_identity() {
  local url=$1 base=${2:-} nolocal=${3:-} rest host path
  url=${url#"${url%%[![:space:]]*}"}
  url=${url%"${url##*[![:space:]]}"}
  [ -n "$url" ] || return 0
  case $url in
  file://*)
    if [ -n "$nolocal" ]; then
      jg_role_path_identity "${url#file://}" "$base"
    else
      jg_role_local_identity "${url#file://}" "$base"
    fi
    ;;
  *://*)
    rest=${url#*://}
    rest=${rest%%[?#]*}
    host=${rest%%/*}
    [ "$host" = "$rest" ] && return 0
    host=${host#*@}
    host=${host%%:*}
    path=${rest#*/}
    path=${path%"${path##*[!/]}"}
    path=${path%.git}
    [ -n "$host" ] && [ -n "$path" ] || return 0
    printf '%s/%s\n' "$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')" \
      "$(printf '%s' "$path" | tr '[:upper:]' '[:lower:]')"
    ;;
  *:*)
    # scp-style [user@]host:owner/repo
    host=${url%%:*}
    path=${url#*:}
    case $host in
    *[!A-Za-z0-9._@/-]* | */*)
      if [ -n "$nolocal" ]; then
        jg_role_path_identity "$url" "$base"
      else
        jg_role_local_identity "$url" "$base"
      fi
      return
      ;;
    esac
    host=${host#*@}
    path=${path%"${path##*[!/]}"}
    path=${path%.git}
    [ -n "$host" ] && [ -n "$path" ] || return 0
    printf '%s/%s\n' "$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')" \
      "$(printf '%s' "$path" | tr '[:upper:]' '[:lower:]')"
    ;;
  *)
    if [ -n "$nolocal" ]; then
      jg_role_path_identity "$url" "$base"
    else
      jg_role_local_identity "$url" "$base"
    fi
    ;;
  esac
}

# jg_role_git_common_dir <dir> - physical common git dir or empty.
jg_role_git_common_dir() {
  local common
  common=$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 0
  (CDPATH='' cd -- "$common" 2>/dev/null && pwd -P) || printf '%s\n' "$common"
}

# jg_role_publication_target <git-dir> - the repository a default publication
# (gh pr/issue, a no-mistakes PR) would reach: the first of upstream, github,
# origin that is configured, in the order gh prefers, normalized to
# host/owner/repo or path:<abs>. Empty when the repo has no such remote.
jg_role_publication_target() {
  local dir=$1 remote url=
  for remote in upstream github origin; do
    if url=$(git -C "$dir" remote get-url "$remote" 2>/dev/null) && [ -n "$url" ]; then
      break
    fi
    url=
  done
  [ -n "$url" ] || return 0
  jg_role_remote_identity "$url" "$dir"
}

# jg_role_shallow <dir> - 0 when <dir> is a shallow git repository.
jg_role_shallow() {
  [ "$(git -C "$1" rev-parse --is-shallow-repository 2>/dev/null)" = true ]
}

# jg_role_self_repo <project-dir> <code-root> - rc 0 when the task's project
# shares juggernaut's lineage: a shared git common dir (the code root itself or
# a linked worktree of it), or a project holding a root commit of the code
# root's history. rc 1 when the project is not a git repository or provably
# shares no root. rc 2 when lineage cannot be determined: the code root has no
# history, or either side is shallow and no root matched. Offline only; lazy
# fetching of missing objects is disabled.
jg_role_self_repo() {
  local proj=$1 root=$2 pa pb roots c
  pa=$(jg_role_git_common_dir "$proj")
  [ -n "$pa" ] || return 1
  pb=$(jg_role_git_common_dir "$root")
  [ -n "$pb" ] && [ "$pa" = "$pb" ] && return 0
  roots=$(git -C "$root" rev-list --max-parents=0 HEAD 2>/dev/null) || roots=
  [ -n "$roots" ] || return 2
  for c in $roots; do
    GIT_NO_LAZY_FETCH=1 git -C "$proj" cat-file -e "$c^{commit}" 2>/dev/null && return 0
  done
  if jg_role_shallow "$root" || jg_role_shallow "$proj"; then
    return 2
  fi
  return 1
}

# jg_role_parse_file <file> - parse one role file. Sets JG_ROLE, JG_ROLE_SCOPE,
# JG_ROLE_DIAG. rc 0 valid; rc 1 malformed; rc 2 absent (missing or not a file).
# The whole file is read before any role is accepted, so a second directive
# anywhere makes it malformed.
jg_role_parse_file() {
  local file=$1 line directive=
  JG_ROLE=
  JG_ROLE_SCOPE=
  JG_ROLE_DIAG=
  if [ -L "$file" ]; then
    JG_ROLE_DIAG="role file must not be a symlink"
    return 1
  fi
  if [ ! -f "$file" ]; then
    JG_ROLE_DIAG="role file is missing"
    return 2
  fi
  if [ ! -r "$file" ]; then
    JG_ROLE_DIAG="role file is unreadable"
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line#"${line%%[![:space:]]*}"}
    case $line in
    '' | '#'*) continue ;;
    esac
    if [ -n "$directive" ]; then
      JG_ROLE_DIAG="role file must hold exactly one directive line"
      return 1
    fi
    directive=$line
  done <"$file"
  if [ -z "$directive" ]; then
    JG_ROLE_DIAG="role file holds no directive"
    return 1
  fi
  set -f
  # shellcheck disable=SC2086  # directive tokens are intentionally word-split
  set -- $directive
  set +f
  case $1 in
  user)
    if [ "$#" -ne 1 ]; then
      JG_ROLE_DIAG="the user role takes no repository scope"
      return 1
    fi
    JG_ROLE=user
    ;;
  maintainer)
    if [ "$#" -ne 2 ]; then
      JG_ROLE_DIAG="the maintainer role requires exactly one repository scope"
      return 1
    fi
    if ! jg_role_scope_valid "$2"; then
      JG_ROLE_DIAG="invalid repository scope '$2'"
      return 1
    fi
    JG_ROLE=maintainer
    JG_ROLE_SCOPE=$(jg_role_scope_norm "$2")
    ;;
  *)
    JG_ROLE_DIAG="unknown role '$1' (expected user or maintainer)"
    return 1
    ;;
  esac
  return 0
}

# jg_role_sha256_stdin - hex digest of stdin on either digest tool.
jg_role_sha256_stdin() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 2>/dev/null | awk '{print $1}'
  else
    sha256sum 2>/dev/null | awk '{print $1}'
  fi
}

# jg_role_inherit_check <role-file> <receipt> - 0 when the receipt is well
# formed and proves the destination's current state (a put whose bytes hash to
# the recorded payload, or a recorded absent with no destination file).
# JG_ROLE_DIAG names the narrow failure.
jg_role_inherit_check() {
  local role_file=$1 receipt=$2 gen bytes sha cmd have
  if [ -L "$receipt" ] || [ ! -f "$receipt" ]; then
    JG_ROLE_DIAG="inheritance receipt is missing or unsafe"
    return 1
  fi
  {
    IFS= read -r gen
    IFS= read -r bytes
    IFS= read -r sha
    IFS= read -r cmd
  } <"$receipt" || {
    JG_ROLE_DIAG="inheritance receipt is unreadable"
    return 1
  }
  case $gen in
  '' | *[!0-9]*) JG_ROLE_DIAG="inheritance receipt generation is malformed"; return 1 ;;
  esac
  case $bytes in
  '' | *[!0-9]*) JG_ROLE_DIAG="inheritance receipt byte count is malformed"; return 1 ;;
  esac
  case $sha in
  *[!0-9a-f]*) JG_ROLE_DIAG="inheritance receipt hash is malformed"; return 1 ;;
  esac
  [ "${#sha}" -eq 64 ] || {
    JG_ROLE_DIAG="inheritance receipt hash is malformed"
    return 1
  }
  case $cmd in
  put | absent) ;;
  *)
    JG_ROLE_DIAG="inheritance receipt records an unknown operation '$cmd'"
    return 1
    ;;
  esac
  if [ "$cmd" = absent ]; then
    if [ "$bytes" != 0 ]; then
      JG_ROLE_DIAG="inheritance receipt records an absent payload with a nonzero byte count"
      return 1
    fi
    if [ "$sha" != e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 ]; then
      JG_ROLE_DIAG="inheritance receipt records an absent payload whose digest is not the empty payload"
      return 1
    fi
    if [ -e "$role_file" ] || [ -L "$role_file" ]; then
      JG_ROLE_DIAG="the parent recorded no role grant, but a local role file exists and cannot be verified"
      return 1
    fi
    return 0
  fi
  if [ -L "$role_file" ] || [ ! -f "$role_file" ]; then
    JG_ROLE_DIAG="the inherited role grant is missing or unsafe"
    return 1
  fi
  have=$(wc -c <"$role_file" 2>/dev/null | tr -d '[:space:]')
  if [ "$have" != "$bytes" ]; then
    JG_ROLE_DIAG="the inherited role grant diverges from the receipt"
    return 1
  fi
  have=$(jg_role_sha256_stdin <"$role_file")
  if [ "$have" != "$sha" ]; then
    JG_ROLE_DIAG="the inherited role grant diverges from the receipt"
    return 1
  fi
  return 0
}

# jg_role_resolve <home> <config-dir> - resolve the effective role. Sets
# JG_ROLE, JG_ROLE_SCOPE, JG_ROLE_SOURCE (absent|local|inherited), JG_ROLE_DIAG.
# Always returns 0: every failure resolves to user with the narrow reason in
# JG_ROLE_DIAG. A squad_lead home (its .jg-squad-lead-home marker) requires the
# inheritance receipt for any grant; a file it cannot prove is dead on arrival.
jg_role_resolve() {
  local home=$1 config=$2 role_file receipt cmd
  JG_ROLE=user
  JG_ROLE_SCOPE=
  # shellcheck disable=SC2034 # Output global, read by the sourcing caller.
  JG_ROLE_SOURCE=absent
  JG_ROLE_DIAG=
  role_file=$(jg_role_file "$config")
  if [ -f "$(jg_compat_marker "$home")" ] && [ ! -L "$(jg_compat_marker "$home")" ]; then
    receipt=$(jg_role_inherit_receipt "$config")
    if [ -e "$receipt" ] || [ -L "$receipt" ]; then
      if ! jg_role_inherit_check "$role_file" "$receipt"; then
        JG_ROLE_DIAG="unverified inherited grant: $JG_ROLE_DIAG"
        return 0
      fi
      cmd=$(sed -n '4p' "$receipt" 2>/dev/null)
      # shellcheck disable=SC2034 # Output global, read by the sourcing caller.
      JG_ROLE_SOURCE=inherited
      if [ "$cmd" = absent ]; then
        return 0
      fi
      if ! jg_role_parse_file "$role_file"; then
        JG_ROLE=user
        JG_ROLE_SCOPE=
        JG_ROLE_DIAG="malformed inherited role: $JG_ROLE_DIAG"
      fi
      return 0
    fi
    if [ -e "$role_file" ] || [ -L "$role_file" ]; then
      JG_ROLE_DIAG="unverified inherited grant: a role file exists with no propagation receipt, and a squad_lead gains the role only through propagation"
      return 0
    fi
    return 0
  fi
  if [ -e "$role_file" ] || [ -L "$role_file" ]; then
    # shellcheck disable=SC2034 # Output global, read by the sourcing caller.
    JG_ROLE_SOURCE=local
    if ! jg_role_parse_file "$role_file"; then
      JG_ROLE=user
      JG_ROLE_SCOPE=
      JG_ROLE_DIAG="malformed role file: $JG_ROLE_DIAG"
    fi
    return 0
  fi
  return 0
}

# jg_role_inherit_payload <home> <config-dir> <out-file> - stage the role this
# home publishes to its squad_leads: the resolved maintainer directive, or no
# file at all when the home resolves to user for any reason (absent, user,
# malformed, symlinked, or unproven), so propagation carries revocation rather
# than raw bytes this home's own resolver rejects. Runs in a subshell so the
# caller's JG_ROLE globals are untouched.
jg_role_inherit_payload() (
  rm -f "$3" || exit 1
  jg_role_resolve "$1" "$2"
  [ "$JG_ROLE" = maintainer ] || exit 0
  printf 'maintainer %s\n' "$JG_ROLE_SCOPE" >"$3"
)

# jg_role_gate_self_publish <home> <config-dir> <project-dir> <code-root> [consent]
# Evaluate whether this home may run a publication contract for a task on
# juggernaut's own repository. rc 0 authorized (JG_ROLE_PUB_AUTHORITY names the
# source: maintainer scope or task consent); rc 1 refused (JG_ROLE_PUB_DENIAL
# names the narrow reason); rc 2 the task is not on this juggernaut repository
# and the boundary does not apply. JG_ROLE_PUB_TARGET is the normalized
# publication target when determinable.
jg_role_gate_self_publish() {
  local home=$1 config=$2 proj=$3 root=$4 consent=${5:-} lineage=0
  JG_ROLE_PUB_TARGET=
  # shellcheck disable=SC2034 # Output global, read by the sourcing caller.
  JG_ROLE_PUB_AUTHORITY=
  # shellcheck disable=SC2034 # Output global, read by the sourcing caller.
  JG_ROLE_PUB_DENIAL=
  jg_role_self_repo "$proj" "$root" || lineage=$?
  if [ "$lineage" -eq 1 ]; then
    return 2
  fi
  JG_ROLE_PUB_TARGET=$(jg_role_publication_target "$proj")
  if [ "$lineage" -eq 2 ]; then
    # shellcheck disable=SC2034 # Output global, read by the sourcing caller.
    JG_ROLE_PUB_DENIAL="cannot determine whether $proj shares juggernaut's history (the code root $root has no readable history, or a shallow clone shares no root commit); fetch full history (git fetch --unshallow) before dispatching publishing work"
    return 1
  fi
  jg_role_resolve "$home" "$config"
  if [ -n "$consent" ]; then
    consent=$(jg_role_scope_norm "$consent")
    if ! jg_role_scope_valid "$consent"; then
      # shellcheck disable=SC2034 # Output global, read by the sourcing caller.
      JG_ROLE_PUB_DENIAL="upstream consent '$consent' is not a valid <host>/<owner>/<repo> scope"
      return 1
    fi
  fi
  if [ -z "$JG_ROLE_PUB_TARGET" ]; then
    # shellcheck disable=SC2034 # Output global, read by the sourcing caller.
    JG_ROLE_PUB_DENIAL="this task targets juggernaut's own repository but no publication target can be determined (no upstream, github, or origin remote on $proj)"
    return 1
  fi
  if [ -n "$consent" ] && [ "$consent" = "$JG_ROLE_PUB_TARGET" ]; then
    # shellcheck disable=SC2034 # Output global, read by the sourcing caller.
    JG_ROLE_PUB_AUTHORITY="task consent for $consent"
    return 0
  fi
  if [ "$JG_ROLE" = maintainer ] && [ "$JG_ROLE_SCOPE" = "$JG_ROLE_PUB_TARGET" ]; then
    # shellcheck disable=SC2034 # Output global, read by the sourcing caller.
    JG_ROLE_PUB_AUTHORITY="maintainer scope $JG_ROLE_PUB_TARGET"
    return 0
  fi
  # shellcheck disable=SC2034 # Output global, read by the sourcing caller.
  JG_ROLE_PUB_DENIAL="this home runs as juggernaut user/operator and holds no publication authority for $JG_ROLE_PUB_TARGET"
  return 1
}

# jg-compat (shim, slice S1; deleted by S10): old names still resolve.
_jg_d=${BASH_SOURCE[0]%/*}
[ "$_jg_d" != "${BASH_SOURCE[0]}" ] || _jg_d=.
if [ -r "$_jg_d/jg-compat.sh" ]; then
  # shellcheck source=bin/jg-compat.sh
  . "$_jg_d/jg-compat.sh"
else
  # A copy of this script with no compat file beside it (a test fixture) has no
  # legacy record to read, so every legacy reader answers "nothing legacy here".
  eval 'jg_compat_legacy_of() { printf "%s\n" "${1-}"; }
    jg_compat_legacy_product() { printf "%s\n" "${1-}"; }
    jg_compat_record_ok() { [ "${1-}" = "${2-}" ]; }
    jg_compat_label_ok() { [ -n "${1-}" ] && [ "${1-}" = "${2-}" ]; }
    jg_compat_marker() { printf "%s\n" "${1-}/.jg-squad-lead-home"; }
    jg_compat_parent_marker() { printf "%s\n" "${1-}/.jg-squad-lead-parent"; }
    jg_compat_claims_root() { printf "%s\n" "${1-}"; }
    jg_compat_pick() { printf "%s\n" "${1-}"; }
    jg_compat_kind() { printf "%s\n" "${1-}"; }
    jg_compat_meta_is_squad_lead() { grep -q "^kind=squad_lead\$" "${1-}" 2>/dev/null; }'
fi
unset _jg_d
