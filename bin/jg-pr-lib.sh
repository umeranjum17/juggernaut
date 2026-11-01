#!/usr/bin/env bash
# Shared PR/MR record reads, validation, and atomic artifact helpers for merge
# polling on the supported forges. Callers must validate task IDs and raw PR/MR
# URLs before constructing task paths or performing any side effect.
#
# The stored identity is provider-tagged: provider, url, host, path, number.
# "path" is the full project path, which is owner/repository on GitHub and
# Forgejo, an arbitrarily nested group/subgroup/project namespace on GitLab, and
# an arbitrarily nested project name on Gerrit, where "number" is the change
# number. A GitLab or Gerrit project can sit at any depth, so no
# owner/repository pair can address one and the sidecar carries the whole path
# instead. GitLab, Gerrit, and Forgejo all run on self-hosted instances, and
# Gerrit runs nowhere else, so the host is part of that identity rather than a
# constant. Every consumer re-derives the identity
# from the stored URL and refuses any record whose parts do not reconstruct that
# exact URL.
#
# A validated exact merged result is retired through a private receipt only
# after its durable wake is appended.
# The receipt binds the terminal observation to the canonical registration and
# lets a restart finish fixed-path removal without executing state-file bytes.

JG_PR_PROVIDER=
JG_PR_URL=
JG_PR_HOST=
JG_PR_PATH=
JG_PR_OWNER=
JG_PR_REPO=
JG_PR_NUMBER=
JG_PR_DATA_PROVIDER=
JG_PR_DATA_URL=
JG_PR_DATA_HOST=
JG_PR_DATA_PATH=
JG_PR_DATA_NUMBER=
JG_PR_META_PROVIDER=
JG_PR_META_URL=
JG_PR_META_HOST=
JG_PR_META_PATH=
JG_PR_META_NUMBER=
JG_PR_REG_ID=
JG_PR_REG_PROVIDER=
JG_PR_REG_URL=
JG_PR_REG_HOST=
JG_PR_REG_PATH=
JG_PR_REG_NUMBER=
JG_PR_REG_DATA_HASH=
JG_PR_REG_TEMPLATE_HASH=
JG_PR_REG_DATA_IDENTITY=
JG_PR_REG_CHECK_IDENTITY=
JG_PR_POLL_DATA_TMP=
JG_PR_POLL_CHECK_TMP=
JG_PR_POLL_REG_TMP=
JG_PR_POLL_DATA_DEST=
JG_PR_POLL_CHECK_DEST=
JG_PR_POLL_REG_DEST=
JG_PR_POLL_EXPECT_ID=
JG_PR_POLL_EXPECT_PROVIDER=
JG_PR_POLL_EXPECT_URL=
JG_PR_POLL_EXPECT_HOST=
JG_PR_POLL_EXPECT_PATH=
JG_PR_POLL_EXPECT_NUMBER=
JG_PR_POLL_EXPECT_DATA_HASH=
JG_PR_POLL_EXPECT_TEMPLATE_HASH=
JG_PR_POLL_EXPECT_DATA_IDENTITY=
JG_PR_POLL_EXPECT_CHECK_IDENTITY=
JG_PR_POLL_TEMPLATE=
JG_PR_POLL_STATE_DEVICE=
JG_PR_POLL_SNAPSHOT_ID=
JG_PR_POLL_SNAPSHOT_PROVIDER=
JG_PR_POLL_SNAPSHOT_URL=
JG_PR_POLL_SNAPSHOT_HOST=
JG_PR_POLL_SNAPSHOT_PATH=
JG_PR_POLL_SNAPSHOT_NUMBER=
JG_PR_POLL_SNAPSHOT_DATA_HASH=
JG_PR_POLL_SNAPSHOT_TEMPLATE_HASH=
JG_PR_POLL_SNAPSHOT_DATA_IDENTITY=
JG_PR_POLL_SNAPSHOT_CHECK_IDENTITY=
JG_PR_POLL_SNAPSHOT_REG_HASH=
JG_PR_POLL_SNAPSHOT_REG_IDENTITY=
JG_PR_POLL_REARM_DATA_IDENTITY=
JG_PR_POLL_REARM_CHECK_IDENTITY=
JG_PR_RETIRE_ID=
JG_PR_RETIRE_PROVIDER=
JG_PR_RETIRE_URL=
JG_PR_RETIRE_HOST=
JG_PR_RETIRE_PATH=
JG_PR_RETIRE_NUMBER=
JG_PR_RETIRE_DATA_HASH=
JG_PR_RETIRE_TEMPLATE_HASH=
JG_PR_RETIRE_DATA_IDENTITY=
JG_PR_RETIRE_CHECK_IDENTITY=
JG_PR_RETIRE_REG_HASH=
JG_PR_RETIRE_REG_IDENTITY=
JG_PR_RETIRE_RECEIPT_HASH=
JG_PR_RETIRE_RECEIPT_IDENTITY=
JG_PR_RECORD_STATE=
JG_PR_RECORD_MERGED=
JG_PR_POLL_RETIREMENT_REJECTED=

jg_task_id_path_safe() {
  local id=${1-}
  local LC_ALL=C
  case "$id" in
    ''|.*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
}

jg_pr_task_id_valid() {
  local id=${1-}
  jg_task_id_path_safe "$id"
}

jg_task_id_creation_valid() {
  local id=${1-}
  jg_pr_task_id_valid "$id" || return 1
  [ "${#id}" -le 64 ]
}

# GitLab, Gerrit, and Forgejo all serve self-hosted instances, so the host is part of the
# identity rather than a constant. It is accepted only as a lowercase DNS name
# with no userinfo, port, or trailing dot, which keeps one canonical spelling per
# change. github.com is refused here even though its shape is otherwise valid:
# it is GitHub's own host and never another forge's instance, so a URL like
# https://github.com/o/r/-/merge_requests/1 (a typo'd or spoofed GitHub URL)
# would otherwise be armed as a watch that can never succeed.
jg_pr_forge_host_valid() {
  local host=${1-} label
  local LC_ALL=C
  local -a labels
  [ "${#host}" -ge 1 ] && [ "${#host}" -le 253 ] || return 1
  [ "$host" != github.com ] || return 1
  case "$host" in
    .*|*.|*..*|*[!a-z0-9.-]*) return 1 ;;
  esac
  IFS=. read -ra labels <<< "$host"
  for label in "${labels[@]}"; do
    [ "${#label}" -ge 1 ] && [ "${#label}" -le 63 ] || return 1
    case "$label" in
      -*|*-) return 1 ;;
    esac
  done
}

# A GitLab project path is group[/subgroup...]/project, so at least two
# segments and no fixed depth. GitLab reserves "-" as its route separator and
# forbids a leading hyphen, ".git", and ".atom", so none of those can name a
# real namespace and each is refused here.
jg_pr_gitlab_path_valid() {
  local path=${1-} segment
  local LC_ALL=C
  local -a segments
  [ "${#path}" -ge 3 ] && [ "${#path}" -le 1024 ] || return 1
  case "$path" in
    /*|*/|*//*) return 1 ;;
  esac
  IFS=/ read -ra segments <<< "$path"
  [ "${#segments[@]}" -ge 2 ] && [ "${#segments[@]}" -le 20 ] || return 1
  for segment in "${segments[@]}"; do
    [ "${#segment}" -ge 1 ] && [ "${#segment}" -le 255 ] || return 1
    case "$segment" in
      .|..|-*|*.git|*.atom|*[!A-Za-z0-9._-]*) return 1 ;;
    esac
  done
}

# A Gerrit project name is itself a path at no fixed depth, and it needs no
# enclosing group, so a single segment is canonical here where GitLab needs at
# least two. Gerrit reserves no route segment inside the name, so nothing
# corresponds to GitLab's "-": the change URL's literal "/+/" is what ends the
# project instead. A ".git" suffix is refused because Gerrit strips it and the
# stripped name is the canonical one, and a leading hyphen is refused because a
# project path is what names the project to any CLI that takes one, where a
# leading hyphen reads as an option instead.
jg_pr_gerrit_path_valid() {
  local path=${1-} segment
  local LC_ALL=C
  local -a segments
  [ "${#path}" -ge 1 ] && [ "${#path}" -le 1024 ] || return 1
  case "$path" in
    /*|*/|*//*) return 1 ;;
  esac
  IFS=/ read -ra segments <<< "$path"
  [ "${#segments[@]}" -ge 1 ] && [ "${#segments[@]}" -le 20 ] || return 1
  for segment in "${segments[@]}"; do
    [ "${#segment}" -ge 1 ] && [ "${#segment}" -le 255 ] || return 1
    case "$segment" in
      .|..|-*|*.git|*[!A-Za-z0-9._-]*) return 1 ;;
    esac
  done
}

# Unlike GitLab, a Forgejo/Gitea project has no subgroup nesting: it is always
# exactly owner/repository, so each segment is validated the same way GitHub's
# owner and repo are, minus GitHub's specific hyphen-run and length rules.
jg_pr_forgejo_segment_valid() {
  local segment=${1-}
  local LC_ALL=C
  [ "${#segment}" -ge 1 ] && [ "${#segment}" -le 100 ] || return 1
  case "$segment" in
    .|..|*.git|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
}

# The forge host and owner/repository of a git clone URL, for comparing a
# pull request's repository with a worktree's origin. Accepted forms are the
# remotes git itself accepts: https://, http://, ssh://, and git:// URLs with
# an optional user@, and scp-like [user@]host:path. A .git suffix and a
# trailing slash are dropped. JG_PR_GIT_REPO is set only when the path is
# exactly owner/repository, so a subgroup, nested, or local path and any URL
# whose repository cannot be isolated leave it empty and the caller keeps its
# existing behavior instead of guessing a repository. An explicit port in a
# scheme URL (ssh://host:2222/owner/repo.git) stays in the path, so such a
# remote also leaves JG_PR_GIT_REPO empty and is never isolated.
jg_pr_repo_from_git_url() {  # <url>
  local url=$1 rest path
  JG_PR_GIT_HOST=
  JG_PR_GIT_REPO=
  case $url in
    https://* | http://* | ssh://* | git://*)
      rest=${url#*://}
      rest=${rest##*@}
      JG_PR_GIT_HOST=${rest%%[:/]*}
      case $rest in
        */*) path=${rest#*/} ;;
        *) return 0 ;;
      esac
      ;;
    /*) return 0 ;;
    *:*)
      JG_PR_GIT_HOST=${url%%:*}
      JG_PR_GIT_HOST=${JG_PR_GIT_HOST##*@}
      path=${url#*:}
      ;;
    *) return 0 ;;
  esac
  path=${path%.git}
  path=${path%/}
  case $path in
    '' | /* | */*/*) ;;
    */*) # shellcheck disable=SC2034
      JG_PR_GIT_REPO=$path ;;
  esac
  return 0
}

# Parse a canonical pull request, merge request, or Gerrit change URL into the
# provider-tagged identity. Validation is strict and per provider: the GitHub
# username and repository rules are unchanged, and GitLab, Gerrit, and Forgejo
# each get their own namespace rules rather than a loosened GitHub rule.
#
# JG_PR_OWNER and JG_PR_REPO are additionally set for github and forgejo
# because bin/jg-pr-merge.sh addresses both by owner/repository. A gitlab or
# gerrit URL leaves them empty, and those paths address the project by JG_PR_HOST and
# JG_PR_PATH instead, so a change on any instance resolves without a hardcoded
# host.
jg_pr_url_parse() {
  local raw=${1-} pattern host path
  local LC_ALL=C
  JG_PR_PROVIDER=
  JG_PR_URL=
  JG_PR_HOST=
  JG_PR_PATH=
  JG_PR_OWNER=
  JG_PR_REPO=
  JG_PR_NUMBER=
  pattern='^https://github\.com/([A-Za-z0-9]|[A-Za-z0-9][A-Za-z0-9-]{0,37}[A-Za-z0-9])/([A-Za-z0-9._-]{1,100})/pull/([1-9][0-9]*)$'
  if [[ "$raw" =~ $pattern ]]; then
    [[ "${BASH_REMATCH[1]}" != *--* ]] || return 1
    [ "${BASH_REMATCH[2]}" != . ] && [ "${BASH_REMATCH[2]}" != .. ] || return 1
    JG_PR_PROVIDER=github
    JG_PR_URL=$raw
    JG_PR_HOST=github.com
    JG_PR_PATH="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
    # Consumed by bin/jg-pr-merge.sh, which addresses GitHub by owner/repository.
    # shellcheck disable=SC2034
    JG_PR_OWNER=${BASH_REMATCH[1]}
    # shellcheck disable=SC2034
    JG_PR_REPO=${BASH_REMATCH[2]}
    JG_PR_NUMBER=${BASH_REMATCH[3]}
    return 0
  fi
  # The path class contains "/" and "-", so this match is greedy to the last
  # "/-/merge_requests/". Any earlier separator therefore lands inside the
  # captured path, where the reserved "-" segment is refused.
  pattern='^https://([a-z0-9.-]{1,253})/([A-Za-z0-9._/-]+)/-/merge_requests/([1-9][0-9]*)$'
  if [[ "$raw" =~ $pattern ]]; then
    host=${BASH_REMATCH[1]}
    path=${BASH_REMATCH[2]}
    jg_pr_forge_host_valid "$host" || return 1
    jg_pr_gitlab_path_valid "$path" || return 1
    JG_PR_PROVIDER=gitlab
    JG_PR_URL=$raw
    JG_PR_HOST=$host
    JG_PR_PATH=$path
    JG_PR_NUMBER=${BASH_REMATCH[3]}
    return 0
  fi
  # A Gerrit change URL is https://<host>/c/<project>/+/<number>. "+" is outside
  # the path class, so the project can never contain the "/+/" separator and this
  # match needs no greediness argument: a second "/+/" makes the URL match
  # nothing rather than splitting somewhere else. The project keeps its whole
  # nested path for the same reason GitLab's does, so it is never flattened into
  # an owner/repository pair that cannot address it.
  pattern='^https://([a-z0-9.-]{1,253})/c/([A-Za-z0-9._/-]+)/\+/([1-9][0-9]*)$'
  if [[ "$raw" =~ $pattern ]]; then
    host=${BASH_REMATCH[1]}
    path=${BASH_REMATCH[2]}
    jg_pr_forge_host_valid "$host" || return 1
    jg_pr_gerrit_path_valid "$path" || return 1
    JG_PR_PROVIDER=gerrit
    JG_PR_URL=$raw
    JG_PR_HOST=$host
    JG_PR_PATH=$path
    JG_PR_NUMBER=${BASH_REMATCH[3]}
    return 0
  fi
  # Forgejo/Gitea serve pulls at owner/repo/pulls/<n>: plural "pulls", no "/-/"
  # route separator and no "/+/" change separator, so this shape never collides
  # with the GitLab or Gerrit patterns above.
  pattern='^https://([a-z0-9.-]{1,253})/([A-Za-z0-9._-]{1,100})/([A-Za-z0-9._-]{1,100})/pulls/([1-9][0-9]*)$'
  [[ "$raw" =~ $pattern ]] || return 1
  host=${BASH_REMATCH[1]}
  jg_pr_forge_host_valid "$host" || return 1
  jg_pr_forgejo_segment_valid "${BASH_REMATCH[2]}" || return 1
  jg_pr_forgejo_segment_valid "${BASH_REMATCH[3]}" || return 1
  JG_PR_PROVIDER=forgejo
  JG_PR_URL=$raw
  JG_PR_HOST=$host
  JG_PR_PATH="${BASH_REMATCH[2]}/${BASH_REMATCH[3]}"
  # Consumed by bin/jg-pr-merge.sh, which addresses Forgejo by owner/repository.
  # shellcheck disable=SC2034
  JG_PR_OWNER=${BASH_REMATCH[2]}
  # shellcheck disable=SC2034
  JG_PR_REPO=${BASH_REMATCH[3]}
  JG_PR_NUMBER=${BASH_REMATCH[4]}
}

jg_pr_head_valid() {
  local head=${1-}
  local LC_ALL=C
  [[ "$head" =~ ^[0-9a-f]{40}$|^[0-9a-f]{64}$ ]]
}

# The context name of the commit status that tells a reader what a pull request
# is waiting for, so the question "what is this pull request waiting for?" is
# answered on the pull request itself. It is ONE status carrying ONE short plain
# line in its description; the newest status for the context is the current one.
JG_PR_WAIT_CONTEXT=juggernaut/waiting-for

# Publish the wait, or clear it, as that status on the pull request's current
# head. "pending" means a wait is in progress and "success" means there is no
# wait, so the merge path publishes success before merging and after a proven
# merge rather than leaving pending behind. Only a GitHub pull request carries
# commit statuses; every other provider returns 0 having published nothing, so
# no caller has to branch on provider. The description is one line capped at
# GitHub's 140-character limit. A publish failure returns nonzero and the caller
# decides whether that is fatal: a pull request must never fail to merge because
# its wait line could not be written.
jg_pr_wait_status() {  # <pr-url> <pending|success> <line>
  local url=${1-} state=${2-} line=${3-} head owner repo
  jg_pr_url_parse "$url" || return 1
  [ "$JG_PR_PROVIDER" = github ] || return 0
  case "$state" in
    pending | success) ;;
    *) return 1 ;;
  esac
  owner=$JG_PR_OWNER
  repo=$JG_PR_REPO
  line=$(printf '%s' "$line" | tr '\n\t' '  ' | sed 's/  */ /g; s/^ //; s/ $//' | cut -c1-140)
  [ -n "$line" ] || return 1
  command -v gh >/dev/null 2>&1 || return 1
  head=$(gh pr view "$url" --repo "$owner/$repo" --json headRefOid -q .headRefOid 2>/dev/null) || return 1
  jg_pr_head_valid "$head" || return 1
  gh api -X POST "repos/$owner/$repo/statuses/$head" \
    -f state="$state" \
    -f context="$JG_PR_WAIT_CONTEXT" \
    -f description="$line" \
    -f target_url="$url" >/dev/null 2>&1
}

# The one reading of a GitHub pull request's draft state. Prints "true" or
# "false" for a boolean isDraft and nothing for anything else, so a caller can
# tell a positive draft from an unreadable payload. bin/jg-pr-merge.sh refuses
# a merge unless this prints "false"; bin/jg-pr-check.sh refuses to arm a merge
# poll only when it prints "true".
jg_pr_json_draft_state() {  # <pull-request-json>
  printf '%s' "${1-}" | jq -r '
    if type == "object" and (.isDraft | type) == "boolean" then (.isDraft | tostring) else "" end
  ' 2>/dev/null || true
}

jg_pr_file_mode() {
  if [ "$(uname)" = Darwin ]; then
    /usr/bin/stat -f %Lp "$1" 2>/dev/null
  else
    stat -c %a "$1" 2>/dev/null
  fi
}

jg_pr_file_device() {
  if [ "$(uname)" = Darwin ]; then
    /usr/bin/stat -f %d "$1" 2>/dev/null
  else
    stat -c %d "$1" 2>/dev/null
  fi
}

jg_pr_file_link_count() {
  if [ "$(uname)" = Darwin ]; then
    /usr/bin/stat -f %l "$1" 2>/dev/null
  else
    stat -c %h "$1" 2>/dev/null
  fi
}

jg_pr_file_inode() {
  if [ "$(uname)" = Darwin ]; then
    /usr/bin/stat -f %i "$1" 2>/dev/null
  else
    stat -c %i "$1" 2>/dev/null
  fi
}

# device:inode names one file object, since an inode number is unique only
# within its filesystem. The device part is not stable across a volume remount:
# APFS can renumber st_dev on reboot while every inode and byte is unchanged, so
# an identity persisted before the remount no longer matches the live file
# (jg_pr_poll_registration_rerecord_device).
jg_pr_file_identity() {
  local device inode
  device=$(jg_pr_file_device "$1") || return 1
  inode=$(jg_pr_file_inode "$1") || return 1
  [ -n "$device" ] && [ -n "$inode" ] || return 1
  printf '%s:%s\n' "$device" "$inode"
}

jg_pr_sha256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" 2>/dev/null | awk '{print $1}'
  else
    return 1
  fi
}

# Callers pass the containing directory's device read in the same invocation,
# never a persisted one, so this compares two live readings and survives a
# remount that renumbers the volume. It refuses a file that is not on that
# directory's own filesystem, such as one bind-mounted over the name, which is
# also what keeps same-directory rename publication atomic.
jg_pr_private_file_valid() {
  local path=$1 mode=$2 device=$3
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  [ "$(jg_pr_file_mode "$path")" = "$mode" ] || return 1
  [ "$(jg_pr_file_device "$path")" = "$device" ] || return 1
  [ "$(jg_pr_file_link_count "$path")" = 1 ]
}

jg_pr_regular_destination_or_absent() {
  local path=$1
  [ ! -L "$path" ] || return 1
  if [ -e "$path" ]; then
    [ -f "$path" ] && [ "$(jg_pr_file_link_count "$path")" = 1 ]
  fi
}

jg_pr_regular_destination_on_device_or_absent() {
  local path=$1 device=$2
  jg_pr_regular_destination_or_absent "$path" || return 1
  [ ! -e "$path" ] || [ "$(jg_pr_file_device "$path")" = "$device" ]
}

jg_pr_metadata_identity_parse() {
  local file=$1 line value pr_count=0 seen_pr=0 post_pr_invalid=0
  JG_PR_META_PROVIDER=
  JG_PR_META_URL=
  JG_PR_META_HOST=
  JG_PR_META_PATH=
  JG_PR_META_NUMBER=
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  [ "$(jg_pr_file_link_count "$file")" = 1 ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      pr=*)
        pr_count=$((pr_count + 1))
        [ "$pr_count" -eq 1 ] || continue
        value=${line#pr=}
        if jg_pr_url_parse "$value"; then
          JG_PR_META_PROVIDER=$JG_PR_PROVIDER
          JG_PR_META_URL=$JG_PR_URL
          JG_PR_META_HOST=$JG_PR_HOST
          JG_PR_META_PATH=$JG_PR_PATH
          JG_PR_META_NUMBER=$JG_PR_NUMBER
        fi
        seen_pr=1
        ;;
      pr_head=*)
        if [ "$seen_pr" -eq 1 ]; then
          value=${line#pr_head=}
          jg_pr_head_valid "$value" || post_pr_invalid=1
        fi
        ;;
      # A relaunch after PR registration republishes the record with the
      # control transaction marker as its final row, so that one control key
      # is allowed after pr= like the x_* rows; it carries no PR identity.
      x_request=*|x_request_ts=*|x_followups=*|x_platform=*|x_reply_max_chars=*|control_relaunch_tx=*)
        ;;
      *)
        [ "$seen_pr" -eq 0 ] || post_pr_invalid=1
        ;;
    esac
  done < "$file"
  [ "$pr_count" -eq 1 ] || return 1
  [ "$post_pr_invalid" -eq 0 ] || return 1
  [ -n "$JG_PR_META_URL" ]
}

# Sidecar layout: provider, url, host, path, number, one per line. A sidecar
# written before the provider tag existed has a URL on its first line and one
# line fewer, so it fails both the field count and the provider comparison and
# is refused rather than misread as a provider-tagged record.
jg_pr_poll_data_parse() {
  local file=$1 provider url host path number
  JG_PR_DATA_PROVIDER=
  JG_PR_DATA_URL=
  JG_PR_DATA_HOST=
  JG_PR_DATA_PATH=
  JG_PR_DATA_NUMBER=
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  exec 8< "$file" || return 1
  IFS= read -r provider <&8 || { exec 8<&-; return 1; }
  IFS= read -r url <&8 || { exec 8<&-; return 1; }
  IFS= read -r host <&8 || { exec 8<&-; return 1; }
  IFS= read -r path <&8 || { exec 8<&-; return 1; }
  IFS= read -r number <&8 || { exec 8<&-; return 1; }
  if IFS= read -r _extra <&8; then
    exec 8<&-
    return 1
  fi
  exec 8<&-
  jg_pr_url_parse "$url" || return 1
  [ "$provider" = "$JG_PR_PROVIDER" ] || return 1
  [ "$host" = "$JG_PR_HOST" ] || return 1
  [ "$path" = "$JG_PR_PATH" ] || return 1
  [ "$number" = "$JG_PR_NUMBER" ] || return 1
  JG_PR_DATA_PROVIDER=$JG_PR_PROVIDER
  JG_PR_DATA_URL=$JG_PR_URL
  JG_PR_DATA_HOST=$JG_PR_HOST
  JG_PR_DATA_PATH=$JG_PR_PATH
  JG_PR_DATA_NUMBER=$JG_PR_NUMBER
}

# Registration layout: version tag, task id, then the same provider-tagged
# identity as the sidecar, then the two hashes and the two file identities.
# The version tag moved to v2 with the provider tag, so a registration written
# by the previous release is recognised as old and refused.
jg_pr_poll_registration_parse() {
  local file=$1 version id provider url host path number data_hash template_hash data_identity check_identity
  JG_PR_REG_ID=
  JG_PR_REG_PROVIDER=
  JG_PR_REG_URL=
  JG_PR_REG_HOST=
  JG_PR_REG_PATH=
  JG_PR_REG_NUMBER=
  JG_PR_REG_DATA_HASH=
  JG_PR_REG_TEMPLATE_HASH=
  JG_PR_REG_DATA_IDENTITY=
  JG_PR_REG_CHECK_IDENTITY=
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  exec 7< "$file" || return 1
  IFS= read -r version <&7 || { exec 7<&-; return 1; }
  IFS= read -r id <&7 || { exec 7<&-; return 1; }
  IFS= read -r provider <&7 || { exec 7<&-; return 1; }
  IFS= read -r url <&7 || { exec 7<&-; return 1; }
  IFS= read -r host <&7 || { exec 7<&-; return 1; }
  IFS= read -r path <&7 || { exec 7<&-; return 1; }
  IFS= read -r number <&7 || { exec 7<&-; return 1; }
  IFS= read -r data_hash <&7 || { exec 7<&-; return 1; }
  IFS= read -r template_hash <&7 || { exec 7<&-; return 1; }
  IFS= read -r data_identity <&7 || { exec 7<&-; return 1; }
  IFS= read -r check_identity <&7 || { exec 7<&-; return 1; }
  if IFS= read -r _extra <&7; then
    exec 7<&-
    return 1
  fi
  exec 7<&-
  [ "$version" = jg-pr-poll-registration-v2 ] || return 1
  jg_pr_task_id_valid "$id" || return 1
  jg_pr_url_parse "$url" || return 1
  [ "$provider" = "$JG_PR_PROVIDER" ] || return 1
  [ "$host" = "$JG_PR_HOST" ] || return 1
  [ "$path" = "$JG_PR_PATH" ] || return 1
  [ "$number" = "$JG_PR_NUMBER" ] || return 1
  [[ "$data_hash" =~ ^[0-9a-f]{64}$ ]] || return 1
  [[ "$template_hash" =~ ^[0-9a-f]{64}$ ]] || return 1
  [[ "$data_identity" =~ ^[0-9]+:[0-9]+$ ]] || return 1
  [[ "$check_identity" =~ ^[0-9]+:[0-9]+$ ]] || return 1
  JG_PR_REG_ID=$id
  JG_PR_REG_PROVIDER=$JG_PR_PROVIDER
  JG_PR_REG_URL=$JG_PR_URL
  JG_PR_REG_HOST=$JG_PR_HOST
  JG_PR_REG_PATH=$JG_PR_PATH
  JG_PR_REG_NUMBER=$JG_PR_NUMBER
  JG_PR_REG_DATA_HASH=$data_hash
  JG_PR_REG_TEMPLATE_HASH=$template_hash
  JG_PR_REG_DATA_IDENTITY=$data_identity
  JG_PR_REG_CHECK_IDENTITY=$check_identity
}

jg_pr_poll_cleanup() {
  [ -z "$JG_PR_POLL_DATA_TMP" ] || rm -f -- "$JG_PR_POLL_DATA_TMP"
  [ -z "$JG_PR_POLL_CHECK_TMP" ] || rm -f -- "$JG_PR_POLL_CHECK_TMP"
  [ -z "$JG_PR_POLL_REG_TMP" ] || rm -f -- "$JG_PR_POLL_REG_TMP"
  JG_PR_POLL_DATA_TMP=
  JG_PR_POLL_CHECK_TMP=
  JG_PR_POLL_REG_TMP=
}

jg_pr_poll_revoke_final() {
  local failed=0
  # Neutralize the runnable name first so a failed rearm cannot consume state
  # whose transactional registration did not commit successfully.
  if [ -e "$JG_PR_POLL_CHECK_DEST" ] || [ -L "$JG_PR_POLL_CHECK_DEST" ]; then
    rm -f -- "$JG_PR_POLL_CHECK_DEST" || failed=1
  fi
  if [ -e "$JG_PR_POLL_REG_DEST" ] || [ -L "$JG_PR_POLL_REG_DEST" ]; then
    rm -f -- "$JG_PR_POLL_REG_DEST" || failed=1
  fi
  if [ -e "$JG_PR_POLL_DATA_DEST" ] || [ -L "$JG_PR_POLL_DATA_DEST" ]; then
    rm -f -- "$JG_PR_POLL_DATA_DEST" || failed=1
  fi
  [ ! -e "$JG_PR_POLL_CHECK_DEST" ] && [ ! -L "$JG_PR_POLL_CHECK_DEST" ] || failed=1
  [ ! -e "$JG_PR_POLL_REG_DEST" ] && [ ! -L "$JG_PR_POLL_REG_DEST" ] || failed=1
  [ ! -e "$JG_PR_POLL_DATA_DEST" ] && [ ! -L "$JG_PR_POLL_DATA_DEST" ] || failed=1
  return "$failed"
}

jg_pr_poll_prepare() {
  local state=$1 id=$2 provider=$3 url=$4 host=$5 path=$6 number=$7 template=$8
  jg_pr_task_id_valid "$id" || return 1
  jg_pr_url_parse "$url" || return 1
  [ "$provider" = "$JG_PR_PROVIDER" ] || return 1
  [ "$host" = "$JG_PR_HOST" ] || return 1
  [ "$path" = "$JG_PR_PATH" ] || return 1
  [ "$number" = "$JG_PR_NUMBER" ] || return 1
  [ -f "$template" ] || return 1

  [ ! -L "$state" ] || return 1
  mkdir -p "$state" || return 1
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  umask 077
  JG_PR_POLL_DATA_DEST="$state/$id.pr-poll"
  JG_PR_POLL_CHECK_DEST="$state/$id.check.sh"
  JG_PR_POLL_REG_DEST="$state/$id.pr-poll-registration"
  JG_PR_POLL_EXPECT_ID=$id
  JG_PR_POLL_EXPECT_PROVIDER=$provider
  JG_PR_POLL_EXPECT_URL=$url
  JG_PR_POLL_EXPECT_HOST=$host
  JG_PR_POLL_EXPECT_PATH=$path
  JG_PR_POLL_EXPECT_NUMBER=$number
  JG_PR_POLL_TEMPLATE=$template
  JG_PR_POLL_STATE_DEVICE=$(jg_pr_file_device "$state") || return 1
  [ -n "$JG_PR_POLL_STATE_DEVICE" ] || return 1
  JG_PR_POLL_DATA_TMP=$(mktemp "$state/.jg-pr-poll-data.XXXXXX") || return 1
  JG_PR_POLL_CHECK_TMP=$(mktemp "$state/.jg-pr-poll-check.XXXXXX") || {
    jg_pr_poll_cleanup
    return 1
  }
  JG_PR_POLL_REG_TMP=$(mktemp "$state/.jg-pr-poll-registration.XXXXXX") || {
    jg_pr_poll_cleanup
    return 1
  }

  if ! printf '%s\n%s\n%s\n%s\n%s\n' "$provider" "$url" "$host" "$path" "$number" > "$JG_PR_POLL_DATA_TMP" \
    || ! chmod 0600 "$JG_PR_POLL_DATA_TMP" \
    || ! jg_pr_private_file_valid "$JG_PR_POLL_DATA_TMP" 600 "$JG_PR_POLL_STATE_DEVICE" \
    || ! jg_pr_poll_data_parse "$JG_PR_POLL_DATA_TMP" \
    || [ "$JG_PR_DATA_PROVIDER" != "$provider" ] \
    || [ "$JG_PR_DATA_URL" != "$url" ] \
    || [ "$JG_PR_DATA_HOST" != "$host" ] \
    || [ "$JG_PR_DATA_PATH" != "$path" ] \
    || [ "$JG_PR_DATA_NUMBER" != "$number" ] \
    || ! cp "$template" "$JG_PR_POLL_CHECK_TMP" \
    || ! chmod 0600 "$JG_PR_POLL_CHECK_TMP" \
    || ! jg_pr_private_file_valid "$JG_PR_POLL_CHECK_TMP" 600 "$JG_PR_POLL_STATE_DEVICE" \
    || ! cmp -s "$template" "$JG_PR_POLL_CHECK_TMP"; then
    jg_pr_poll_cleanup
    return 1
  fi
  JG_PR_POLL_EXPECT_DATA_HASH=$(jg_pr_sha256 "$JG_PR_POLL_DATA_TMP") || { jg_pr_poll_cleanup; return 1; }
  JG_PR_POLL_EXPECT_TEMPLATE_HASH=$(jg_pr_sha256 "$JG_PR_POLL_CHECK_TMP") || { jg_pr_poll_cleanup; return 1; }
  JG_PR_POLL_EXPECT_DATA_IDENTITY=$(jg_pr_file_identity "$JG_PR_POLL_DATA_TMP") || { jg_pr_poll_cleanup; return 1; }
  JG_PR_POLL_EXPECT_CHECK_IDENTITY=$(jg_pr_file_identity "$JG_PR_POLL_CHECK_TMP") || { jg_pr_poll_cleanup; return 1; }
  if ! printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n' \
      jg-pr-poll-registration-v2 "$id" "$provider" "$url" "$host" "$path" "$number" \
      "$JG_PR_POLL_EXPECT_DATA_HASH" "$JG_PR_POLL_EXPECT_TEMPLATE_HASH" \
      "$JG_PR_POLL_EXPECT_DATA_IDENTITY" "$JG_PR_POLL_EXPECT_CHECK_IDENTITY" \
      > "$JG_PR_POLL_REG_TMP" \
    || ! chmod 0600 "$JG_PR_POLL_REG_TMP" \
    || ! jg_pr_private_file_valid "$JG_PR_POLL_REG_TMP" 600 "$JG_PR_POLL_STATE_DEVICE" \
    || ! jg_pr_poll_registration_parse "$JG_PR_POLL_REG_TMP" \
    || [ "$JG_PR_REG_ID" != "$id" ] \
    || [ "$JG_PR_REG_DATA_HASH" != "$JG_PR_POLL_EXPECT_DATA_HASH" ] \
    || [ "$JG_PR_REG_TEMPLATE_HASH" != "$JG_PR_POLL_EXPECT_TEMPLATE_HASH" ]; then
    jg_pr_poll_cleanup
    return 1
  fi
}

# The caller holds the task's poll publication lock while publishing this
# prepared generation, so no registration can name another generation's files.
jg_pr_poll_publish_prepared() {
  [ -n "$JG_PR_POLL_DATA_TMP" ] && [ -n "$JG_PR_POLL_CHECK_TMP" ] \
    && [ -n "$JG_PR_POLL_REG_TMP" ] || return 1
  jg_pr_regular_destination_on_device_or_absent "$JG_PR_POLL_DATA_DEST" "$JG_PR_POLL_STATE_DEVICE" || return 1
  jg_pr_regular_destination_on_device_or_absent "$JG_PR_POLL_REG_DEST" "$JG_PR_POLL_STATE_DEVICE" || return 1
  jg_pr_regular_destination_on_device_or_absent "$JG_PR_POLL_CHECK_DEST" "$JG_PR_POLL_STATE_DEVICE" || return 1

  if ! mv -f -- "$JG_PR_POLL_DATA_TMP" "$JG_PR_POLL_DATA_DEST"; then
    jg_pr_poll_revoke_final || true
    return 1
  fi
  JG_PR_POLL_DATA_TMP=
  if ! jg_pr_private_file_valid "$JG_PR_POLL_DATA_DEST" 600 "$JG_PR_POLL_STATE_DEVICE" \
    || [ "$(jg_pr_file_identity "$JG_PR_POLL_DATA_DEST")" != "$JG_PR_POLL_EXPECT_DATA_IDENTITY" ] \
    || [ "$(jg_pr_sha256 "$JG_PR_POLL_DATA_DEST")" != "$JG_PR_POLL_EXPECT_DATA_HASH" ] \
    || ! jg_pr_poll_data_parse "$JG_PR_POLL_DATA_DEST" \
    || [ "$JG_PR_DATA_PROVIDER" != "$JG_PR_POLL_EXPECT_PROVIDER" ] \
    || [ "$JG_PR_DATA_URL" != "$JG_PR_POLL_EXPECT_URL" ] \
    || [ "$JG_PR_DATA_HOST" != "$JG_PR_POLL_EXPECT_HOST" ] \
    || [ "$JG_PR_DATA_PATH" != "$JG_PR_POLL_EXPECT_PATH" ] \
    || [ "$JG_PR_DATA_NUMBER" != "$JG_PR_POLL_EXPECT_NUMBER" ]; then
    jg_pr_poll_revoke_final || true
    return 1
  fi

  if ! mv -f -- "$JG_PR_POLL_REG_TMP" "$JG_PR_POLL_REG_DEST"; then
    jg_pr_poll_revoke_final || true
    return 1
  fi
  JG_PR_POLL_REG_TMP=
  if ! jg_pr_private_file_valid "$JG_PR_POLL_REG_DEST" 600 "$JG_PR_POLL_STATE_DEVICE" \
    || ! jg_pr_poll_registration_parse "$JG_PR_POLL_REG_DEST" \
    || [ "$JG_PR_REG_ID" != "$JG_PR_POLL_EXPECT_ID" ] \
    || [ "$JG_PR_REG_PROVIDER" != "$JG_PR_POLL_EXPECT_PROVIDER" ] \
    || [ "$JG_PR_REG_URL" != "$JG_PR_POLL_EXPECT_URL" ] \
    || [ "$JG_PR_REG_HOST" != "$JG_PR_POLL_EXPECT_HOST" ] \
    || [ "$JG_PR_REG_PATH" != "$JG_PR_POLL_EXPECT_PATH" ] \
    || [ "$JG_PR_REG_NUMBER" != "$JG_PR_POLL_EXPECT_NUMBER" ] \
    || [ "$JG_PR_REG_DATA_HASH" != "$JG_PR_POLL_EXPECT_DATA_HASH" ] \
    || [ "$JG_PR_REG_TEMPLATE_HASH" != "$JG_PR_POLL_EXPECT_TEMPLATE_HASH" ] \
    || [ "$JG_PR_REG_DATA_IDENTITY" != "$JG_PR_POLL_EXPECT_DATA_IDENTITY" ] \
    || [ "$JG_PR_REG_CHECK_IDENTITY" != "$JG_PR_POLL_EXPECT_CHECK_IDENTITY" ]; then
    jg_pr_poll_revoke_final || true
    return 1
  fi

  if ! jg_pr_regular_destination_on_device_or_absent "$JG_PR_POLL_CHECK_DEST" "$JG_PR_POLL_STATE_DEVICE" \
    || ! mv -f -- "$JG_PR_POLL_CHECK_TMP" "$JG_PR_POLL_CHECK_DEST"; then
    jg_pr_poll_revoke_final || true
    return 1
  fi
  JG_PR_POLL_CHECK_TMP=
  if ! jg_pr_poll_artifacts_valid "${JG_PR_POLL_CHECK_DEST%/*}" "$JG_PR_POLL_EXPECT_ID" "$JG_PR_POLL_TEMPLATE"; then
    jg_pr_poll_revoke_final || true
    return 1
  fi
}

jg_pr_poll_artifacts_valid() {
  local state=$1 id=$2 template=$3 data_identity check_identity
  jg_pr_poll_artifacts_content_valid "$state" "$id" "$template" || return 1
  data_identity=$(jg_pr_file_identity "$state/$id.pr-poll") || return 1
  check_identity=$(jg_pr_file_identity "$state/$id.check.sh") || return 1
  # The recorded identities bind the registration to the exact sidecar and
  # check file objects published in its own transaction, so a byte-identical
  # replacement or a torn re-arm pairing one generation's check with another's
  # registration is refused.
  [ "$JG_PR_REG_DATA_IDENTITY" = "$data_identity" ] || return 1
  [ "$JG_PR_REG_CHECK_IDENTITY" = "$check_identity" ]
}

# Everything jg_pr_poll_artifacts_valid proves except that the registration's
# recorded file identities name the live sidecar and check. Success alone is
# never authentication. On success JG_PR_DATA_*, JG_PR_REG_*, and JG_PR_META_*
# hold the parsed records.
jg_pr_poll_artifacts_content_valid() {
  local state=$1 id=$2 template=$3 state_device check data registration meta data_hash template_hash
  jg_pr_task_id_valid "$id" || return 1
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  state_device=$(jg_pr_file_device "$state") || return 1
  check="$state/$id.check.sh"
  data="$state/$id.pr-poll"
  registration="$state/$id.pr-poll-registration"
  meta="$state/$id.meta"
  jg_pr_private_file_valid "$check" 600 "$state_device" || return 1
  jg_pr_private_file_valid "$data" 600 "$state_device" || return 1
  jg_pr_private_file_valid "$registration" 600 "$state_device" || return 1
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  [ "$(jg_pr_file_link_count "$meta")" = 1 ] || return 1
  cmp -s "$template" "$check" || return 1
  jg_pr_poll_data_parse "$data" || return 1
  data_hash=$(jg_pr_sha256 "$data") || return 1
  template_hash=$(jg_pr_sha256 "$check") || return 1
  jg_pr_poll_registration_parse "$registration" || return 1
  [ "$JG_PR_REG_ID" = "$id" ] || return 1
  [ "$JG_PR_REG_PROVIDER" = "$JG_PR_DATA_PROVIDER" ] || return 1
  [ "$JG_PR_REG_URL" = "$JG_PR_DATA_URL" ] || return 1
  [ "$JG_PR_REG_HOST" = "$JG_PR_DATA_HOST" ] || return 1
  [ "$JG_PR_REG_PATH" = "$JG_PR_DATA_PATH" ] || return 1
  [ "$JG_PR_REG_NUMBER" = "$JG_PR_DATA_NUMBER" ] || return 1
  [ "$JG_PR_REG_DATA_HASH" = "$data_hash" ] || return 1
  [ "$JG_PR_REG_TEMPLATE_HASH" = "$template_hash" ] || return 1
  jg_pr_metadata_identity_parse "$meta" || return 1
  [ "$JG_PR_META_PROVIDER" = "$JG_PR_DATA_PROVIDER" ] || return 1
  [ "$JG_PR_META_URL" = "$JG_PR_DATA_URL" ] || return 1
  [ "$JG_PR_META_HOST" = "$JG_PR_DATA_HOST" ] || return 1
  [ "$JG_PR_META_PATH" = "$JG_PR_DATA_PATH" ] || return 1
  [ "$JG_PR_META_NUMBER" = "$JG_PR_DATA_NUMBER" ]
}

# A registration armed before a volume remount can name a device number the
# kernel has since reassigned (jg_pr_file_identity). This proves that is the
# only difference: every artifact passes jg_pr_poll_artifacts_content_valid, so
# the check is byte-identical to the template, both hashes match, and the three
# poll artifacts are private, single-link, and on the state directory's live
# device; both recorded identities name one device; each recorded inode equals
# its live inode; and that recorded device differs from the live one. A
# replaced, altered, re-moded, relinked, or foreign-device artifact fails a proof
# here and stays refused. A pending retirement receipt owns its artifacts, so
# none is re-recorded while one exists. On success
# JG_PR_POLL_REARM_DATA_IDENTITY and JG_PR_POLL_REARM_CHECK_IDENTITY hold the
# live identities.
jg_pr_poll_registration_device_shifted() {  # <state> <id> <template>
  local state=$1 id=$2 template=$3 state_device recorded_device receipt data_identity check_identity
  JG_PR_POLL_REARM_DATA_IDENTITY=
  JG_PR_POLL_REARM_CHECK_IDENTITY=
  jg_pr_task_id_valid "$id" || return 1
  [ -f "$state/$id.pr-poll-registration" ] || return 1
  receipt="$state/$id.pr-poll-retirement"
  [ ! -e "$receipt" ] && [ ! -L "$receipt" ] || return 1
  jg_pr_poll_artifacts_content_valid "$state" "$id" "$template" || return 1
  state_device=$(jg_pr_file_device "$state") || return 1
  data_identity=$(jg_pr_file_identity "$state/$id.pr-poll") || return 1
  check_identity=$(jg_pr_file_identity "$state/$id.check.sh") || return 1
  recorded_device=${JG_PR_REG_DATA_IDENTITY%%:*}
  [ "${JG_PR_REG_CHECK_IDENTITY%%:*}" = "$recorded_device" ] || return 1
  [ "$recorded_device" != "$state_device" ] || return 1
  [ "$data_identity" = "$state_device:${JG_PR_REG_DATA_IDENTITY#*:}" ] || return 1
  [ "$check_identity" = "$state_device:${JG_PR_REG_CHECK_IDENTITY#*:}" ] || return 1
  JG_PR_POLL_REARM_DATA_IDENTITY=$data_identity
  JG_PR_POLL_REARM_CHECK_IDENTITY=$check_identity
}

# Rewrite a device-shifted registration (jg_pr_poll_registration_device_shifted)
# so it names the live device, changing no other line. The caller holds the
# task's control lock and poll publication lock, which serialize this with the
# watcher's validated check and retirement, teardown, bin/jg-pr-merge.sh, and
# direct bin/jg-pr-check.sh publication. The proof is repeated just before the
# rename, which proceeds only while the registration is still the exact file
# object and bytes first proven.
# Success means the strict jg_pr_poll_artifacts_valid accepts the result.
jg_pr_poll_registration_rerecord_device() {  # <state> <id> <template>
  local state=$1 id=$2 template=$3 state_device registration tmp reg_hash reg_identity
  local id_line provider url host path number data_hash template_hash data_identity check_identity
  jg_pr_poll_registration_device_shifted "$state" "$id" "$template" || return 1
  registration="$state/$id.pr-poll-registration"
  id_line=$JG_PR_REG_ID
  provider=$JG_PR_REG_PROVIDER
  url=$JG_PR_REG_URL
  host=$JG_PR_REG_HOST
  path=$JG_PR_REG_PATH
  number=$JG_PR_REG_NUMBER
  data_hash=$JG_PR_REG_DATA_HASH
  template_hash=$JG_PR_REG_TEMPLATE_HASH
  data_identity=$JG_PR_POLL_REARM_DATA_IDENTITY
  check_identity=$JG_PR_POLL_REARM_CHECK_IDENTITY
  state_device=$(jg_pr_file_device "$state") || return 1
  reg_hash=$(jg_pr_sha256 "$registration") || return 1
  reg_identity=$(jg_pr_file_identity "$registration") || return 1
  tmp=$(mktemp "$state/.jg-pr-poll-registration.XXXXXX") || return 1
  if ! printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n' \
      jg-pr-poll-registration-v2 "$id_line" "$provider" "$url" "$host" "$path" "$number" \
      "$data_hash" "$template_hash" "$data_identity" "$check_identity" > "$tmp" \
    || ! chmod 0600 "$tmp" \
    || ! jg_pr_private_file_valid "$tmp" 600 "$state_device" \
    || ! jg_pr_poll_registration_parse "$tmp" \
    || [ "$JG_PR_REG_ID" != "$id" ] \
    || [ "$JG_PR_REG_URL" != "$url" ] \
    || [ "$JG_PR_REG_DATA_HASH" != "$data_hash" ] \
    || [ "$JG_PR_REG_TEMPLATE_HASH" != "$template_hash" ] \
    || [ "$JG_PR_REG_DATA_IDENTITY" != "$data_identity" ] \
    || [ "$JG_PR_REG_CHECK_IDENTITY" != "$check_identity" ] \
    || ! jg_pr_poll_registration_device_shifted "$state" "$id" "$template" \
    || [ "$JG_PR_POLL_REARM_DATA_IDENTITY" != "$data_identity" ] \
    || [ "$JG_PR_POLL_REARM_CHECK_IDENTITY" != "$check_identity" ] \
    || [ "$(jg_pr_sha256 "$registration")" != "$reg_hash" ] \
    || [ "$(jg_pr_file_identity "$registration")" != "$reg_identity" ] \
    || ! jg_pr_regular_destination_on_device_or_absent "$registration" "$state_device" \
    || ! mv -f -- "$tmp" "$registration"; then
    rm -f -- "$tmp"
    return 1
  fi
  jg_pr_poll_artifacts_valid "$state" "$id" "$template"
}

jg_pr_poll_snapshot_capture() {
  local state=$1 id=$2 template=$3 registration
  jg_pr_poll_artifacts_valid "$state" "$id" "$template" || return 1
  registration="$state/$id.pr-poll-registration"
  JG_PR_POLL_SNAPSHOT_REG_HASH=$(jg_pr_sha256 "$registration") || return 1
  JG_PR_POLL_SNAPSHOT_REG_IDENTITY=$(jg_pr_file_identity "$registration") || return 1
  JG_PR_POLL_SNAPSHOT_ID=$id
  JG_PR_POLL_SNAPSHOT_PROVIDER=$JG_PR_DATA_PROVIDER
  JG_PR_POLL_SNAPSHOT_URL=$JG_PR_DATA_URL
  JG_PR_POLL_SNAPSHOT_HOST=$JG_PR_DATA_HOST
  JG_PR_POLL_SNAPSHOT_PATH=$JG_PR_DATA_PATH
  JG_PR_POLL_SNAPSHOT_NUMBER=$JG_PR_DATA_NUMBER
  JG_PR_POLL_SNAPSHOT_DATA_HASH=$JG_PR_REG_DATA_HASH
  JG_PR_POLL_SNAPSHOT_TEMPLATE_HASH=$JG_PR_REG_TEMPLATE_HASH
  JG_PR_POLL_SNAPSHOT_DATA_IDENTITY=$JG_PR_REG_DATA_IDENTITY
  JG_PR_POLL_SNAPSHOT_CHECK_IDENTITY=$JG_PR_REG_CHECK_IDENTITY
}

jg_pr_poll_snapshot_matches() {
  local state=$1 id=$2 template=$3 registration reg_hash reg_identity
  [ -n "$JG_PR_POLL_SNAPSHOT_ID" ] && [ "$id" = "$JG_PR_POLL_SNAPSHOT_ID" ] || return 1
  jg_pr_poll_artifacts_valid "$state" "$id" "$template" || return 1
  registration="$state/$id.pr-poll-registration"
  reg_hash=$(jg_pr_sha256 "$registration") || return 1
  reg_identity=$(jg_pr_file_identity "$registration") || return 1
  [ "$JG_PR_DATA_PROVIDER" = "$JG_PR_POLL_SNAPSHOT_PROVIDER" ] || return 1
  [ "$JG_PR_DATA_URL" = "$JG_PR_POLL_SNAPSHOT_URL" ] || return 1
  [ "$JG_PR_DATA_HOST" = "$JG_PR_POLL_SNAPSHOT_HOST" ] || return 1
  [ "$JG_PR_DATA_PATH" = "$JG_PR_POLL_SNAPSHOT_PATH" ] || return 1
  [ "$JG_PR_DATA_NUMBER" = "$JG_PR_POLL_SNAPSHOT_NUMBER" ] || return 1
  [ "$JG_PR_REG_DATA_HASH" = "$JG_PR_POLL_SNAPSHOT_DATA_HASH" ] || return 1
  [ "$JG_PR_REG_TEMPLATE_HASH" = "$JG_PR_POLL_SNAPSHOT_TEMPLATE_HASH" ] || return 1
  [ "$JG_PR_REG_DATA_IDENTITY" = "$JG_PR_POLL_SNAPSHOT_DATA_IDENTITY" ] || return 1
  [ "$JG_PR_REG_CHECK_IDENTITY" = "$JG_PR_POLL_SNAPSHOT_CHECK_IDENTITY" ] || return 1
  [ "$reg_hash" = "$JG_PR_POLL_SNAPSHOT_REG_HASH" ] || return 1
  [ "$reg_identity" = "$JG_PR_POLL_SNAPSHOT_REG_IDENTITY" ]
}

jg_pr_poll_retirement_parse() {
  local file=$1 version id provider url host path number data_hash template_hash
  local data_identity check_identity reg_hash reg_identity result _extra
  JG_PR_RETIRE_ID=
  JG_PR_RETIRE_PROVIDER=
  JG_PR_RETIRE_URL=
  JG_PR_RETIRE_HOST=
  JG_PR_RETIRE_PATH=
  JG_PR_RETIRE_NUMBER=
  JG_PR_RETIRE_DATA_HASH=
  JG_PR_RETIRE_TEMPLATE_HASH=
  JG_PR_RETIRE_DATA_IDENTITY=
  JG_PR_RETIRE_CHECK_IDENTITY=
  JG_PR_RETIRE_REG_HASH=
  JG_PR_RETIRE_REG_IDENTITY=
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  exec 9< "$file" || return 1
  IFS= read -r version <&9 || { exec 9<&-; return 1; }
  IFS= read -r id <&9 || { exec 9<&-; return 1; }
  IFS= read -r provider <&9 || { exec 9<&-; return 1; }
  IFS= read -r url <&9 || { exec 9<&-; return 1; }
  IFS= read -r host <&9 || { exec 9<&-; return 1; }
  IFS= read -r path <&9 || { exec 9<&-; return 1; }
  IFS= read -r number <&9 || { exec 9<&-; return 1; }
  IFS= read -r data_hash <&9 || { exec 9<&-; return 1; }
  IFS= read -r template_hash <&9 || { exec 9<&-; return 1; }
  IFS= read -r data_identity <&9 || { exec 9<&-; return 1; }
  IFS= read -r check_identity <&9 || { exec 9<&-; return 1; }
  IFS= read -r reg_hash <&9 || { exec 9<&-; return 1; }
  IFS= read -r reg_identity <&9 || { exec 9<&-; return 1; }
  IFS= read -r result <&9 || { exec 9<&-; return 1; }
  if IFS= read -r _extra <&9; then
    exec 9<&-
    return 1
  fi
  exec 9<&-
  [ "$version" = jg-pr-poll-retirement-v1 ] || return 1
  jg_pr_task_id_valid "$id" || return 1
  jg_pr_url_parse "$url" || return 1
  [ "$provider" = "$JG_PR_PROVIDER" ] || return 1
  [ "$host" = "$JG_PR_HOST" ] || return 1
  [ "$path" = "$JG_PR_PATH" ] || return 1
  [ "$number" = "$JG_PR_NUMBER" ] || return 1
  [[ "$data_hash" =~ ^[0-9a-f]{64}$ ]] || return 1
  [[ "$template_hash" =~ ^[0-9a-f]{64}$ ]] || return 1
  [[ "$data_identity" =~ ^[0-9]+:[0-9]+$ ]] || return 1
  [[ "$check_identity" =~ ^[0-9]+:[0-9]+$ ]] || return 1
  [[ "$reg_hash" =~ ^[0-9a-f]{64}$ ]] || return 1
  [[ "$reg_identity" =~ ^[0-9]+:[0-9]+$ ]] || return 1
  [ "$result" = merged ] || return 1
  JG_PR_RETIRE_ID=$id
  JG_PR_RETIRE_PROVIDER=$provider
  JG_PR_RETIRE_URL=$url
  JG_PR_RETIRE_HOST=$host
  JG_PR_RETIRE_PATH=$path
  JG_PR_RETIRE_NUMBER=$number
  JG_PR_RETIRE_DATA_HASH=$data_hash
  JG_PR_RETIRE_TEMPLATE_HASH=$template_hash
  JG_PR_RETIRE_DATA_IDENTITY=$data_identity
  JG_PR_RETIRE_CHECK_IDENTITY=$check_identity
  JG_PR_RETIRE_REG_HASH=$reg_hash
  JG_PR_RETIRE_REG_IDENTITY=$reg_identity
}

jg_pr_poll_retirement_receipt_valid() {
  local state=$1 id=$2 receipt state_device meta
  jg_pr_task_id_valid "$id" || return 1
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  state_device=$(jg_pr_file_device "$state") || return 1
  receipt="$state/$id.pr-poll-retirement"
  jg_pr_private_file_valid "$receipt" 600 "$state_device" || return 1
  jg_pr_poll_retirement_parse "$receipt" || return 1
  [ "$JG_PR_RETIRE_ID" = "$id" ] || return 1
  meta="$state/$id.meta"
  jg_pr_metadata_identity_parse "$meta" || return 1
  [ "$JG_PR_META_PROVIDER" = "$JG_PR_RETIRE_PROVIDER" ] || return 1
  [ "$JG_PR_META_URL" = "$JG_PR_RETIRE_URL" ] || return 1
  [ "$JG_PR_META_HOST" = "$JG_PR_RETIRE_HOST" ] || return 1
  [ "$JG_PR_META_PATH" = "$JG_PR_RETIRE_PATH" ] || return 1
  [ "$JG_PR_META_NUMBER" = "$JG_PR_RETIRE_NUMBER" ] || return 1
  JG_PR_RETIRE_RECEIPT_HASH=$(jg_pr_sha256 "$receipt") || return 1
  JG_PR_RETIRE_RECEIPT_IDENTITY=$(jg_pr_file_identity "$receipt") || return 1
}

jg_pr_github_read_record_with_gh() {  # <owner> <repo> <number>
  local owner=$1 repo=$2 number=$3 fields line total=0 named=0
  local state='' merged=''
  JG_PR_RECORD_STATE=
  JG_PR_RECORD_MERGED=

  # shellcheck disable=SC2016  # GraphQL variables are literal query syntax.
  if ! fields=$(gh api graphql \
    -f query='query($owner:String!,$repo:String!,$number:Int!){repository(owner:$owner,name:$repo){pullRequest(number:$number){state merged}}}' \
    -F "owner=$owner" -F "repo=$repo" -F "number=$number" \
    --jq '.data.repository.pullRequest | "state=" + (.state // ""), "merged=" + (.merged | tostring)' \
    2>/dev/null) || [ -z "$fields" ]; then
    return 1
  fi
  while IFS= read -r line; do
    total=$((total + 1))
    case "$line" in
      state=*) state=${line#state=} ;;
      merged=*) merged=${line#merged=} ;;
      *) continue ;;
    esac
    named=$((named + 1))
  done <<FIELDS
$fields
FIELDS
  if [ "$named" -ne 2 ] || [ "$total" -ne 2 ] || [ -z "$state" ] \
    || { [ "$merged" != true ] && [ "$merged" != false ]; }; then
    return 1
  fi

  # Consumed by bin/jg-crew-state.sh passed_pr_detail.
  # shellcheck disable=SC2034
  JG_PR_RECORD_STATE=$state
  # Consumed by bin/jg-crew-state.sh passed_pr_detail.
  # shellcheck disable=SC2034
  JG_PR_RECORD_MERGED=$merged
}

jg_pr_github_read_record_with_gh_axi() {  # <owner> <repo> <number>
  local owner=$1 repo=$2 number=$3 output state
  JG_PR_RECORD_STATE=
  JG_PR_RECORD_MERGED=
  if ! output=$(gh-axi pr view "$number" --repo "$owner/$repo" 2>/dev/null); then
    return 1
  fi
  if ! state=$(printf '%s\n' "$output" | awk '
    $1 == "state:" { count++; value=$2 }
    END { if (count == 1 && value != "") print value; else exit 1 }
  '); then
    return 1
  fi
  case "$state" in
    MERGED|merged)
      # Consumed by bin/jg-crew-state.sh passed_pr_detail.
      # shellcheck disable=SC2034
      JG_PR_RECORD_STATE=MERGED
      # Consumed by bin/jg-crew-state.sh passed_pr_detail.
      # shellcheck disable=SC2034
      JG_PR_RECORD_MERGED=true
      ;;
    OPEN|open)
      # Consumed by bin/jg-crew-state.sh passed_pr_detail.
      # shellcheck disable=SC2034
      JG_PR_RECORD_STATE=OPEN
      # Consumed by bin/jg-crew-state.sh passed_pr_detail.
      # shellcheck disable=SC2034
      JG_PR_RECORD_MERGED=false
      ;;
    CLOSED|closed)
      # Consumed by bin/jg-crew-state.sh passed_pr_detail.
      # shellcheck disable=SC2034
      JG_PR_RECORD_STATE=CLOSED
      # Consumed by bin/jg-crew-state.sh passed_pr_detail.
      # shellcheck disable=SC2034
      JG_PR_RECORD_MERGED=false
      ;;
    *)
      return 1
      ;;
  esac
}

jg_pr_github_read_record() {  # <owner> <repo> <number>
  if command -v gh >/dev/null 2>&1 && jg_pr_github_read_record_with_gh "$@"; then
    return 0
  fi
  command -v gh-axi >/dev/null 2>&1 || return 1
  jg_pr_github_read_record_with_gh_axi "$@"
}

jg_pr_gitlab_read_record() {  # <host> <path> <number>
  local host=$1 path=$2 number=$3 project_url json fields line
  local total=0 named=0 state='' merged=''
  JG_PR_RECORD_STATE=
  JG_PR_RECORD_MERGED=
  command -v glab >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1
  project_url="https://$host/$path"

  if ! json=$(GITLAB_HOST="$host" glab mr view "$number" -R "$project_url" -F json 2>/dev/null) \
    || [ -z "$json" ]; then
    return 1
  fi
  if ! fields=$(printf '%s' "$json" | jq -r '
      if type == "object" and (.state | type == "string") and .state != "" then
        "state=" + .state,
        "merged=" + (if .state == "merged" then "true" else "false" end)
      else
        error("invalid merge request state")
      end' 2>/dev/null); then
    return 1
  fi
  while IFS= read -r line; do
    total=$((total + 1))
    case "$line" in
      state=*) state=${line#state=} ;;
      merged=*) merged=${line#merged=} ;;
      *) continue ;;
    esac
    named=$((named + 1))
  done <<FIELDS
$fields
FIELDS
  if [ "$named" -ne 2 ] || [ "$total" -ne 2 ] || [ -z "$state" ] \
    || { [ "$merged" != true ] && [ "$merged" != false ]; }; then
    return 1
  fi

  # Consumed by bin/jg-crew-state.sh passed_pr_detail.
  # shellcheck disable=SC2034
  JG_PR_RECORD_STATE=$state
  # Consumed by bin/jg-crew-state.sh passed_pr_detail.
  # shellcheck disable=SC2034
  JG_PR_RECORD_MERGED=$merged
}

# tea addresses a repo by slug only and takes the host from a named login, so
# the one login registered for <host> is printed by name, and zero or several
# matches fail rather than pick one. The list is parsed as JSON with jq rather
# than split on quotes per line, because tea's JSON is not guaranteed to put
# each field on its own line: a login printed as one compact object would hand
# a line-oriented split the name where it expects the url, and arming would
# then refuse every host. A login matches when its url's host - scheme,
# userinfo, port, and path stripped - is exactly <host>. bin/jg-pr-poll.sh keeps
# its own copy of this filter because the watcher body sources nothing.
# shellcheck disable=SC2016 # $h is a jq variable bound by --arg, not a shell one.
JG_PR_FORGEJO_LOGIN_JQ='
  if type == "array" then
    [ .[]
      | select(type == "object" and (.name | type) == "string" and (.name | length) > 0
               and (.url | type) == "string")
      | select((.url
                | sub("^[A-Za-z][A-Za-z0-9+.-]*://"; "")
                | sub("[/?#].*$"; "")
                | sub("^.*@"; "")
                | sub(":[0-9]+$"; "")) == $h)
      | .name ]
    | if length == 1 then .[0] else error("not exactly one matching login") end
  else
    error("login list is not an array")
  end'
jg_pr_forgejo_login() {  # <host>
  command -v tea >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1
  tea login list --output json 2>/dev/null | jq -er --arg h "$1" "$JG_PR_FORGEJO_LOGIN_JQ" 2>/dev/null
}

# The state, merged flag, and head commit of one Forgejo pull request, read
# from the REST record through "tea api" so the credential never leaves tea.
# "tea api" exits 0 on an HTTP error and prints the error body instead, so
# only a record whose state, merged, and head.sha fields all have the expected
# types is accepted; anything else returns 1 for an honest unknown.
jg_pr_forgejo_read_record() {  # <host> <path> <number>
  local host=$1 path=$2 number=$3 login json fields line
  local total=0 named=0 state='' merged='' head=''
  JG_PR_RECORD_STATE=
  JG_PR_RECORD_MERGED=
  JG_PR_RECORD_HEAD=
  command -v jq >/dev/null 2>&1 || return 1
  case "$number" in
    ''|*[!0-9]*) return 1 ;;
  esac
  login=$(jg_pr_forgejo_login "$host") || return 1
  [ -n "$login" ] || return 1
  if ! json=$(tea api --login "$login" --repo "$path" \
      "/repos/{owner}/{repo}/pulls/$number" 2>/dev/null) || [ -z "$json" ]; then
    return 1
  fi
  if ! fields=$(printf '%s' "$json" | jq -r '
      if type == "object" and (.state | type) == "string" and .state != ""
        and (.merged | type) == "boolean" and (.head.sha | type) == "string"
      then
        "state=" + .state,
        "merged=" + (.merged | tostring),
        "head=" + .head.sha
      else
        error("invalid pull request record")
      end' 2>/dev/null); then
    return 1
  fi
  while IFS= read -r line; do
    total=$((total + 1))
    case "$line" in
      state=*) state=${line#state=} ;;
      merged=*) merged=${line#merged=} ;;
      head=*) head=${line#head=} ;;
      *) continue ;;
    esac
    named=$((named + 1))
  done <<FIELDS
$fields
FIELDS
  if [ "$named" -ne 3 ] || [ "$total" -ne 3 ] || [ -z "$state" ] \
    || { [ "$merged" != true ] && [ "$merged" != false ]; }; then
    return 1
  fi

  # Consumed by bin/jg-crew-state.sh passed_pr_detail.
  # shellcheck disable=SC2034
  JG_PR_RECORD_STATE=$state
  # Consumed by bin/jg-crew-state.sh passed_pr_detail and bin/jg-teardown.sh.
  # shellcheck disable=SC2034
  JG_PR_RECORD_MERGED=$merged
  # Consumed by bin/jg-teardown.sh pr_is_merged.
  # shellcheck disable=SC2034
  JG_PR_RECORD_HEAD=$head
}

# gerrit-axi resolves its server from the current directory's origin remote
# first, so the host is passed explicitly from the parsed identity and a read
# outside a clone still reaches the right server. A change number is
# server-global and --host pins the server, so the number alone names the
# change and the project path is not part of the read. Prints the one record
# whose change number is exactly <number> as compact JSON, and fails on any
# other reading. The record's own url field is not compared against the stored
# URL, because Gerrit composes it from gerrit.canonicalWebUrl and omits it when
# that setting is unset, which would turn every read on such a server into a
# permanent unknown.
jg_pr_gerrit_read_change() {  # <host> <number>
  local host=$1 number=$2 json
  command -v gerrit-axi >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1
  case "$number" in
    ''|*[!0-9]*) return 1 ;;
  esac
  if ! json=$(gerrit-axi show "$number" --host "$host" --json 2>/dev/null) \
    || [ -z "$json" ]; then
    return 1
  fi
  printf '%s' "$json" | jq -c --argjson change "$number" '
    if type == "object" and .ok == true and (.changes | type) == "array" then
      [.changes[] | select((.change | type) == "number" and .change == $change)] as $match
      | if ($match | length) == 1 and ($match[0] | type) == "object"
        then $match[0]
        else error("no exact change record")
        end
    else
      error("invalid gerrit record")
    end' 2>/dev/null
}

# The status of one Gerrit change. The status is the only field read: a merged
# change and an approved-but-unsubmitted one report the same submit,
# submittable, and blocked_on values, so only the status separates them.
jg_pr_gerrit_read_record() {  # <host> <number>
  local record state merged=false
  JG_PR_RECORD_STATE=
  JG_PR_RECORD_MERGED=
  record=$(jg_pr_gerrit_read_change "$1" "$2") || return 1
  state=$(printf '%s' "$record" | jq -r '
    if (.status | type) == "string" and .status != "" and (.status | test("\n") | not)
    then .status
    else error("no status")
    end' 2>/dev/null) || return 1
  [ -n "$state" ] || return 1
  [ "$state" != MERGED ] || merged=true

  # Consumed by bin/jg-crew-state.sh passed_pr_detail.
  # shellcheck disable=SC2034
  JG_PR_RECORD_STATE=$state
  # Consumed by bin/jg-crew-state.sh passed_pr_detail.
  # shellcheck disable=SC2034
  JG_PR_RECORD_MERGED=$merged
}

# The current patch set revision of one Gerrit change, read from the same exact
# record as its status above. Consumed by bin/jg-dod-lib.sh's named-head gate,
# which accepts a published change only when this revision carries the worker
# copy's HEAD tree. It is a live read and never a recorded pr_head: the next
# amend replaces it.
jg_pr_gerrit_read_revision() {  # <host> <number>
  local record revision
  JG_PR_RECORD_REVISION=
  record=$(jg_pr_gerrit_read_change "$1" "$2") || return 1
  revision=$(printf '%s' "$record" | jq -r '
    if (.revision | type) == "string" then .revision else error("no revision") end' 2>/dev/null) \
    || return 1
  jg_pr_head_valid "$revision" || return 1
  # Consumed by bin/jg-dod-lib.sh jg_dod_gerrit_change_carries_head.
  # shellcheck disable=SC2034
  JG_PR_RECORD_REVISION=$revision
}

jg_pr_poll_retirement_data_valid() {
  local state=$1 id=$2 state_device data data_hash data_identity
  state_device=$(jg_pr_file_device "$state") || return 1
  data="$state/$id.pr-poll"
  jg_pr_private_file_valid "$data" 600 "$state_device" || return 1
  jg_pr_poll_data_parse "$data" || return 1
  data_hash=$(jg_pr_sha256 "$data") || return 1
  data_identity=$(jg_pr_file_identity "$data") || return 1
  [ "$JG_PR_DATA_PROVIDER" = "$JG_PR_RETIRE_PROVIDER" ] || return 1
  [ "$JG_PR_DATA_URL" = "$JG_PR_RETIRE_URL" ] || return 1
  [ "$JG_PR_DATA_HOST" = "$JG_PR_RETIRE_HOST" ] || return 1
  [ "$JG_PR_DATA_PATH" = "$JG_PR_RETIRE_PATH" ] || return 1
  [ "$JG_PR_DATA_NUMBER" = "$JG_PR_RETIRE_NUMBER" ] || return 1
  [ "$data_hash" = "$JG_PR_RETIRE_DATA_HASH" ] || return 1
  [ "$data_identity" = "$JG_PR_RETIRE_DATA_IDENTITY" ]
}

jg_pr_poll_retirement_registration_valid() {
  local state=$1 id=$2 state_device registration reg_hash reg_identity
  state_device=$(jg_pr_file_device "$state") || return 1
  registration="$state/$id.pr-poll-registration"
  jg_pr_private_file_valid "$registration" 600 "$state_device" || return 1
  jg_pr_poll_registration_parse "$registration" || return 1
  reg_hash=$(jg_pr_sha256 "$registration") || return 1
  reg_identity=$(jg_pr_file_identity "$registration") || return 1
  [ "$JG_PR_REG_ID" = "$id" ] || return 1
  [ "$JG_PR_REG_PROVIDER" = "$JG_PR_RETIRE_PROVIDER" ] || return 1
  [ "$JG_PR_REG_URL" = "$JG_PR_RETIRE_URL" ] || return 1
  [ "$JG_PR_REG_HOST" = "$JG_PR_RETIRE_HOST" ] || return 1
  [ "$JG_PR_REG_PATH" = "$JG_PR_RETIRE_PATH" ] || return 1
  [ "$JG_PR_REG_NUMBER" = "$JG_PR_RETIRE_NUMBER" ] || return 1
  [ "$JG_PR_REG_DATA_HASH" = "$JG_PR_RETIRE_DATA_HASH" ] || return 1
  [ "$JG_PR_REG_TEMPLATE_HASH" = "$JG_PR_RETIRE_TEMPLATE_HASH" ] || return 1
  [ "$JG_PR_REG_DATA_IDENTITY" = "$JG_PR_RETIRE_DATA_IDENTITY" ] || return 1
  [ "$JG_PR_REG_CHECK_IDENTITY" = "$JG_PR_RETIRE_CHECK_IDENTITY" ] || return 1
  [ "$reg_hash" = "$JG_PR_RETIRE_REG_HASH" ] || return 1
  [ "$reg_identity" = "$JG_PR_RETIRE_REG_IDENTITY" ]
}

jg_pr_poll_retirement_check_valid() {
  local state=$1 id=$2 state_device check check_hash check_identity
  state_device=$(jg_pr_file_device "$state") || return 1
  check="$state/$id.check.sh"
  jg_pr_private_file_valid "$check" 600 "$state_device" || return 1
  check_hash=$(jg_pr_sha256 "$check") || return 1
  check_identity=$(jg_pr_file_identity "$check") || return 1
  [ "$check_hash" = "$JG_PR_RETIRE_TEMPLATE_HASH" ] || return 1
  [ "$check_identity" = "$JG_PR_RETIRE_CHECK_IDENTITY" ]
}

jg_pr_poll_retirement_state_valid() {
  local state=$1 id=$2 check data registration has_check=0 has_data=0 has_registration=0
  jg_pr_poll_retirement_receipt_valid "$state" "$id" || return 1
  check="$state/$id.check.sh"
  data="$state/$id.pr-poll"
  registration="$state/$id.pr-poll-registration"
  [ ! -e "$check" ] && [ ! -L "$check" ] || has_check=1
  [ ! -e "$data" ] && [ ! -L "$data" ] || has_data=1
  [ ! -e "$registration" ] && [ ! -L "$registration" ] || has_registration=1
  if [ "$has_check" -eq 1 ]; then
    [ "$has_data" -eq 1 ] && [ "$has_registration" -eq 1 ] || return 1
    jg_pr_poll_retirement_check_valid "$state" "$id" || return 1
    jg_pr_poll_retirement_data_valid "$state" "$id" || return 1
    jg_pr_poll_retirement_registration_valid "$state" "$id" || return 1
    return 0
  fi
  if [ "$has_registration" -eq 1 ]; then
    [ "$has_data" -eq 1 ] || return 1
    jg_pr_poll_retirement_data_valid "$state" "$id" || return 1
    jg_pr_poll_retirement_registration_valid "$state" "$id" || return 1
    return 0
  fi
  [ "$has_data" -eq 0 ] || jg_pr_poll_retirement_data_valid "$state" "$id"
}

jg_pr_poll_retirement_remove_exact() {
  local path=$1 state_device=$2 expected_identity=$3 expected_hash=$4
  jg_pr_private_file_valid "$path" 600 "$state_device" || return 1
  [ "$(jg_pr_file_identity "$path")" = "$expected_identity" ] || return 1
  [ "$(jg_pr_sha256 "$path")" = "$expected_hash" ] || return 1
  rm -f -- "$path" || return 1
  [ ! -e "$path" ] && [ ! -L "$path" ]
}

jg_pr_poll_retirement_discard_obsolete() {
  local state=$1 id=$2 template=$3 receipt registration state_device
  local receipt_hash receipt_identity current_reg_hash current_reg_identity
  jg_pr_task_id_valid "$id" || return 1
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  state_device=$(jg_pr_file_device "$state") || return 1
  receipt="$state/$id.pr-poll-retirement"
  jg_pr_private_file_valid "$receipt" 600 "$state_device" || return 1
  jg_pr_poll_retirement_parse "$receipt" || return 1
  [ "$JG_PR_RETIRE_ID" = "$id" ] || return 1
  receipt_hash=$(jg_pr_sha256 "$receipt") || return 1
  receipt_identity=$(jg_pr_file_identity "$receipt") || return 1
  jg_pr_poll_artifacts_valid "$state" "$id" "$template" || return 1
  registration="$state/$id.pr-poll-registration"
  current_reg_hash=$(jg_pr_sha256 "$registration") || return 1
  current_reg_identity=$(jg_pr_file_identity "$registration") || return 1
  if [ "$current_reg_hash" = "$JG_PR_RETIRE_REG_HASH" ] \
    && [ "$current_reg_identity" = "$JG_PR_RETIRE_REG_IDENTITY" ] \
    && [ "$JG_PR_REG_DATA_IDENTITY" = "$JG_PR_RETIRE_DATA_IDENTITY" ] \
    && [ "$JG_PR_REG_CHECK_IDENTITY" = "$JG_PR_RETIRE_CHECK_IDENTITY" ]; then
    return 1
  fi
  jg_pr_poll_retirement_remove_exact "$receipt" "$state_device" \
    "$receipt_identity" "$receipt_hash"
}

jg_pr_poll_retirement_publish() {
  local state=$1 id=$2 template=$3 result=$4 receipt state_device tmp
  [ "$result" = merged ] || return 1
  jg_pr_poll_snapshot_matches "$state" "$id" "$template" || return 1
  state_device=$(jg_pr_file_device "$state") || return 1
  receipt="$state/$id.pr-poll-retirement"
  jg_pr_regular_destination_on_device_or_absent "$receipt" "$state_device" || return 1
  [ ! -e "$receipt" ] && [ ! -L "$receipt" ] || return 1
  umask 077
  tmp=$(mktemp "$state/.jg-pr-poll-retirement.XXXXXX") || return 1
  if ! printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n' \
      jg-pr-poll-retirement-v1 \
      "$JG_PR_POLL_SNAPSHOT_ID" \
      "$JG_PR_POLL_SNAPSHOT_PROVIDER" \
      "$JG_PR_POLL_SNAPSHOT_URL" \
      "$JG_PR_POLL_SNAPSHOT_HOST" \
      "$JG_PR_POLL_SNAPSHOT_PATH" \
      "$JG_PR_POLL_SNAPSHOT_NUMBER" \
      "$JG_PR_POLL_SNAPSHOT_DATA_HASH" \
      "$JG_PR_POLL_SNAPSHOT_TEMPLATE_HASH" \
      "$JG_PR_POLL_SNAPSHOT_DATA_IDENTITY" \
      "$JG_PR_POLL_SNAPSHOT_CHECK_IDENTITY" \
      "$JG_PR_POLL_SNAPSHOT_REG_HASH" \
      "$JG_PR_POLL_SNAPSHOT_REG_IDENTITY" \
      merged > "$tmp" \
    || ! chmod 0600 "$tmp" \
    || ! jg_pr_private_file_valid "$tmp" 600 "$state_device" \
    || ! jg_pr_poll_retirement_parse "$tmp" \
    || [ "$JG_PR_RETIRE_ID" != "$id" ] \
    || ! jg_pr_poll_snapshot_matches "$state" "$id" "$template" \
    || ! jg_pr_regular_destination_on_device_or_absent "$receipt" "$state_device" \
    || [ -e "$receipt" ] || [ -L "$receipt" ] \
    || ! mv -f -- "$tmp" "$receipt"; then
    rm -f -- "$tmp"
    return 1
  fi
  jg_pr_poll_retirement_receipt_valid "$state" "$id" || return 1
}

jg_pr_poll_retirement_recover_one() {
  local state=$1 id=$2 template=$3 receipt state_device check data registration
  local receipt_hash receipt_identity
  jg_pr_task_id_valid "$id" || return 1
  receipt="$state/$id.pr-poll-retirement"
  if [ ! -e "$receipt" ] && [ ! -L "$receipt" ]; then
    return 0
  fi
  if ! jg_pr_poll_retirement_state_valid "$state" "$id"; then
    jg_pr_poll_retirement_discard_obsolete "$state" "$id" "$template" && return 0
    return 1
  fi
  state_device=$(jg_pr_file_device "$state") || return 1
  check="$state/$id.check.sh"
  data="$state/$id.pr-poll"
  registration="$state/$id.pr-poll-registration"
  receipt_hash=$JG_PR_RETIRE_RECEIPT_HASH
  receipt_identity=$JG_PR_RETIRE_RECEIPT_IDENTITY
  if [ -e "$check" ] || [ -L "$check" ]; then
    jg_pr_poll_retirement_remove_exact "$check" "$state_device" \
      "$JG_PR_RETIRE_CHECK_IDENTITY" "$JG_PR_RETIRE_TEMPLATE_HASH" || return 1
  fi
  if [ -e "$registration" ] || [ -L "$registration" ]; then
    jg_pr_poll_retirement_remove_exact "$registration" "$state_device" \
      "$JG_PR_RETIRE_REG_IDENTITY" "$JG_PR_RETIRE_REG_HASH" || return 1
  fi
  if [ -e "$data" ] || [ -L "$data" ]; then
    jg_pr_poll_retirement_remove_exact "$data" "$state_device" \
      "$JG_PR_RETIRE_DATA_IDENTITY" "$JG_PR_RETIRE_DATA_HASH" || return 1
  fi
  jg_pr_poll_retirement_remove_exact "$receipt" "$state_device" \
    "$receipt_identity" "$receipt_hash" || return 1
  [ ! -e "$check" ] && [ ! -L "$check" ] \
    && [ ! -e "$registration" ] && [ ! -L "$registration" ] \
    && [ ! -e "$data" ] && [ ! -L "$data" ] \
    && [ ! -e "$receipt" ] && [ ! -L "$receipt" ]
}

jg_pr_poll_retirement_recover_all() {
  local state=$1 template=$2 receipt id
  JG_PR_POLL_RETIREMENT_REJECTED=
  for receipt in "$state"/*.pr-poll-retirement; do
    [ -e "$receipt" ] || [ -L "$receipt" ] || continue
    id=$(basename "$receipt" .pr-poll-retirement)
    if ! jg_pr_task_id_valid "$id" \
      || ! jg_pr_poll_retirement_recover_one "$state" "$id" "$template"; then
      JG_PR_POLL_RETIREMENT_REJECTED="$JG_PR_POLL_RETIREMENT_REJECTED $receipt"
    fi
  done
  [ -z "$JG_PR_POLL_RETIREMENT_REJECTED" ]
}

# --- merge-notification canonical-identity marker ----------------------------
# A merged-PR poll retires (jg_pr_poll_retirement_recover_one) in the same
# watcher cycle that detects it, which is normally enough on its own to stop a
# duplicate detection: the check.sh is gone, so nothing re-polls it. The
# exception is the same poll re-registered after its merge was already
# surfaced. Its retirement state is scoped to one registration, so this marker
# carries the canonical PR identity across registrations for the task. Only a
# matching identity is a no-op; a different PR for the same task reaches its
# role-routed supervision destination and replaces the marker when its first
# outcome is published.
jg_pr_poll_merge_marker_matches() {  # <marker> <device> <provider> <host> <path> <number>
  local marker=$1 device=$2 expected_provider=$3 expected_host=$4 expected_path=$5 expected_number=$6
  local version provider host path number
  jg_pr_private_file_valid "$marker" 600 "$device" || return 1
  exec 8< "$marker" || return 1
  IFS= read -r version <&8 || { exec 8<&-; return 1; }
  IFS= read -r provider <&8 || { exec 8<&-; return 1; }
  IFS= read -r host <&8 || { exec 8<&-; return 1; }
  IFS= read -r path <&8 || { exec 8<&-; return 1; }
  IFS= read -r number <&8 || { exec 8<&-; return 1; }
  if IFS= read -r _extra <&8; then
    exec 8<&-
    return 1
  fi
  exec 8<&-
  [ "$version" = jg-pr-poll-merge-notified-v1 ] \
    && [ "$provider" = "$expected_provider" ] \
    && [ "$host" = "$expected_host" ] \
    && [ "$path" = "$expected_path" ] \
    && [ "$number" = "$expected_number" ]
}

jg_pr_poll_merge_already_notified() {  # <state> <id> <provider> <host> <path> <number>
  local state=$1 id=$2 provider=$3 host=$4 path=$5 number=$6 marker state_device
  jg_pr_task_id_valid "$id" || return 1
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  state_device=$(jg_pr_file_device "$state") || return 1
  marker="$state/$id.pr-poll-merge-notified"
  jg_pr_poll_merge_marker_matches "$marker" "$state_device" \
    "$provider" "$host" "$path" "$number"
}

jg_pr_poll_merge_mark_notified() {  # <state> <id> <provider> <host> <path> <number>
  local state=$1 id=$2 provider=$3 host=$4 path=$5 number=$6 marker tmp state_device
  jg_pr_task_id_valid "$id" || return 1
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  state_device=$(jg_pr_file_device "$state") || return 1
  marker="$state/$id.pr-poll-merge-notified"
  jg_pr_regular_destination_on_device_or_absent "$marker" "$state_device" || return 1
  umask 077
  tmp=$(mktemp "$state/.jg-pr-poll-merge-notified.XXXXXX") || return 1
  if ! printf '%s\n%s\n%s\n%s\n%s\n' \
      jg-pr-poll-merge-notified-v1 "$provider" "$host" "$path" "$number" > "$tmp" \
    || ! chmod 0600 "$tmp" \
    || ! jg_pr_poll_merge_marker_matches "$tmp" "$state_device" \
      "$provider" "$host" "$path" "$number" \
    || ! jg_pr_regular_destination_on_device_or_absent "$marker" "$state_device" \
    || ! mv -f -- "$tmp" "$marker" \
    || ! jg_pr_poll_merge_marker_matches "$marker" "$state_device" \
      "$provider" "$host" "$path" "$number"; then
    rm -f -- "$tmp"
    return 1
  fi
}

# Removed at teardown alongside the other per-task PR-poll artifacts
# (bin/jg-teardown.sh) so a retired task id leaves no residue behind.
jg_pr_poll_merge_notified_remove() {  # <state> <id>
  local state=$1 id=$2 marker
  jg_pr_task_id_valid "$id" || return 1
  marker="$state/$id.pr-poll-merge-notified"
  [ -e "$marker" ] || [ -L "$marker" ] || return 0
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
  rm -f -- "$marker"
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
    jg_compat_marker_ok() { [ "${1-}" = JUGGERNAUT_OP ]; }
    jg_compat_marker() { printf "%s\n" "${1-}/.jg-squad-lead-home"; }
    jg_compat_parent_marker() { printf "%s\n" "${1-}/.jg-squad-lead-parent"; }
    jg_compat_claims_root() { printf "%s\n" "${1-}"; }
    jg_compat_pick() { printf "%s\n" "${1-}"; }
    jg_compat_kind() { printf "%s\n" "${1-}"; }
    jg_compat_meta_is_squad_lead() { grep -q "^kind=squad_lead\$" "${1-}" 2>/dev/null; }'
fi
unset _jg_d
