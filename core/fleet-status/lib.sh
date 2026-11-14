# shellcheck shell=bash
# lib.sh - what the board and the readings share: the environment a lister and an observer run in, the machine's record
# lister and freshness lifetime from records.tsv, and the seconds of a limit. Source it; it prints nothing and writes nothing.
FS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)

fs_secs() { case "$1" in *s) echo "${1%s}" ;; *m) echo $((${1%m} * 60)) ;; *h) echo $((${1%h} * 3600)) ;; *d) echo $((${1%d} * 86400)) ;; esac; }

# fs_env <home>: point the observers, the listers and the machine tables at one home.
fs_env() {
  local home=$1
  export JG_HOME=$home JG_STATE_OVERRIDE=$home/state JG_DATA_OVERRIDE=$home/data JG_MACHINES_TABLES=$home/core/machines/tables
  [ ! -d "$home/config" ] || export JG_CONFIG_OVERRIDE=$home/config
  STATE=$home/state DATA=$home/data CONFIG=$home/config FS=$FS_DIR
  export STATE DATA CONFIG FS
}

# fs_record <machine> <column>: column 2 of records.tsv is the lister command, column 3 how long a reading stays fresh (seconds).
fs_record() { awk -F'\t' -v m="$1" -v c="$2" '$1 == m { print $c; exit }' "$FS_DIR/records.tsv"; }
