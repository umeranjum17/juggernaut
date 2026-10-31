# shellcheck shell=bash
# jg-alias-lib.sh - the one owner of the pre-rename alias shim (slice S3).
#
# Slice S3 put a shim at every bin/fm-*.sh, so a caller that resolved a
# pre-rename path still works: executed it runs the renamed script, and sourced
# it loads the renamed library and then owes the caller the old function names.
# Every one of those files was that same shim with one line changed.
#
# This library is that file. A shim now names its own path and nothing else.
# Slice S10 deletes the shims and this library together.
#
# A shim runs this, from the directory it lives in:
#   . "$_jg_alias_dir/jg-alias-lib.sh"
#   jg_alias_shim "${BASH_SOURCE[0]}" "$0" "$@"

# <old basename>: prints the renamed file the same alias stands in for. The
# nested-supervisor word moved in the same rename, so the substitution mirrors
# the reverse one jg_compat_legacy_of owns.
jg_alias_target() {  # <old basename>
  local old=${1-} new
  case $old in
  fm-*) new=jg-${old#fm-} ;;
  *)
    printf 'jg-alias-lib: %s is not an fm- alias and names no target\n' "$old" >&2
    return 2
    ;;
  esac
  printf '%s\n' "${new//secondmate/squad-lead}"
}

# <shim path as BASH_SOURCE[0]> <shim $0> [the shim's own arguments...].
# Sourced it loads the renamed library into the caller's shell; executed it
# hands the shim's arguments to the renamed script.
jg_alias_shim() {
  local alias_source=$1 shim_argv0=$2 alias_dir
  shift 2
  case $alias_source in
  */*) alias_dir=${alias_source%/*} ;;
  *) alias_dir=. ;;
  esac
  # Not local, and not renamed: a shim that is sourced has always left these
  # two names visible to its caller, and this change is a removal, not a
  # change. Nothing in the tree reads either one.
  _jg_alias_new=$(jg_alias_target "${alias_source##*/}") || return
  _jg_alias_new=$alias_dir/$_jg_alias_new
  if [ "$alias_source" != "$shim_argv0" ]; then
    # Sourced. A library that does not load the compatibility layer itself
    # still owes an old caller its old function names.
    # shellcheck source=/dev/null
    . "$_jg_alias_new"
    if ! declare -F jg_compat_function_aliases >/dev/null 2>&1 && [ -r "$alias_dir/jg-compat.sh" ]; then
      # shellcheck source=bin/jg-compat.sh
      . "$alias_dir/jg-compat.sh"
    fi
    if declare -F jg_compat_function_aliases >/dev/null 2>&1; then jg_compat_function_aliases; fi
    return 0
  fi
  # Executed. An old caller may run a library as `bash <old path>`, and the
  # renamed library need not be executable.
  [ -x "$_jg_alias_new" ] || exec bash "$_jg_alias_new" "$@"
  exec "$_jg_alias_new" "$@"
}
