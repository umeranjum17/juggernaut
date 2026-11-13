#!/usr/bin/env bash
# Behavior test for the runner registry and probe (H30a): the probe goes through the real jg-on.sh and
# the real doctor's protocol; only the SSH process boundary is a stand-in.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(jg_test_tmproot jg-runner-probe)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
trap 'rm -rf -- "$TMP_ROOT"' EXIT
HOME_DIR="$TMP_ROOT/home"
FAKEBIN=$(jg_fakebin "$TMP_ROOT/fakebin")
mkdir -p "$HOME_DIR/config" "$HOME_DIR/state"

# The SSH stand-in answers as the doctor of each lab host; the host alias picks the story.
cat > "$FAKEBIN/fake-ssh" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do case "$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac; done
host=$1
printf 'mode=check\nplatform=linux\n'
case "$host" in
  lab-own)   printf 'arch=x86_64\ncores=8\nload1=1.50\nok: ready\n' ;;
  lab-cloud) printf 'arch=x86_64\ncores=4\nload1=0.10\nok: ready\n' ;;
  lab-arch)  printf 'arch=arm64\ncores=8\nload1=0.00\nok: ready\n' ;;
  lab-tool)  printf 'arch=x86_64\ncores=8\nload1=0.00\nrequired git=MISSING\n'; exit 1 ;;
  lab-busy)  printf 'arch=x86_64\ncores=2\nload1=5.00\nok: ready\n' ;;
  lab-down)  exit 255 ;;
  *) exit 91 ;;
esac
SH
chmod +x "$FAKEBIN/fake-ssh"

record() { # <id> <alias> <cost>
  printf '%s ssh=%s root=/srv/jg home=/srv/jg-home arch=x86_64 cores=8 mem_gb=16 slots=2 cost_per_hour=%s private_ok=%s\n' \
    "$1" "$2" "$3" "$([ "$3" = 0 ] && echo yes || echo no)"
}
reg() { "$ROOT/core/runners/registry.sh" "$@"; }
probe() { JG_SSH_BIN="$FAKEBIN/fake-ssh" "$ROOT/core/runners/probe.sh" "$HOME_DIR" "$1"; }

# An empty registry places nothing: every run stays on this host.
[ -z "$(reg usable "$HOME_DIR")" ] || fail "an empty registry named a usable runner"
out=$(probe nope 2>&1); rc=$?
[ "$rc" -eq 1 ] || fail "a probe of an unregistered runner did not fail (rc $rc)"
assert_contains "$out" "no valid runner record for 'nope'" "the unregistered runner's cause was not named"
pass "with no runner registered nothing is usable and a probe names the missing record"

{
  echo '# registered runners'
  record cloud1 lab-cloud 0.40
  record own1 lab-own 0
  record arch1 lab-arch 0
  record tool1 lab-tool 0
  record busy1 lab-busy 0
  record down1 lab-down 0
  echo 'bad1 ssh=lab-own root=relative home=/h arch=x86_64 cores=1 mem_gb=1 slots=1 cost_per_hour=0 private_ok=yes'
} > "$HOME_DIR/config/runners"
[ "$(reg list "$HOME_DIR" | wc -l)" -eq 6 ] || fail "list did not name exactly the six valid records: $(reg list "$HOME_DIR")"
reg get "$HOME_DIR" bad1 >/dev/null 2>&1 && fail "a record with a relative root was accepted"
[ -z "$(reg usable "$HOME_DIR")" ] || fail "an unprobed runner was usable"
pass "the registry lists valid records, refuses a malformed one, and no runner is usable before a probe"

out=$(probe own1) || fail "the healthy own runner failed its probe: $out"
[ "$out" = "ok own1 free_cores=6" ] || fail "free cores were not cores minus load: $out"
out=$(probe cloud1) || fail "the healthy cloud runner failed its probe: $out"
out=$(probe busy1) || fail "a busy runner failed instead of passing with no free core: $out"
assert_contains "$out" "free_cores=0" "a busy runner did not report 0 free cores"
for r in arch1 tool1 down1; do
  out=$(probe "$r") && fail "runner $r passed its probe"
  case "$r" in
    arch1) assert_contains "$out" "arch is 'arm64', the record says x86_64" "the arch mismatch was not named" ;;
    tool1) assert_contains "$out" "the doctor exited 1" "the doctor gap was not named" ;;
    down1) assert_contains "$out" "no connection" "the lost connection was not named" ;;
  esac
done
usable=$(reg usable "$HOME_DIR" | tr '\n' ' ')
[ "$usable" = "busy1 own1 cloud1 " ] || fail "usable was not the probed-ok runners, own machines first: '$usable'"
pass "a passing probe makes a runner usable, own machines first; a wrong arch, a doctor gap or a lost link gets no work"

# A later failed probe withdraws a runner that passed before.
sed -i 's|lab-own)   printf .*|lab-own)   exit 255 ;;|' "$FAKEBIN/fake-ssh"
probe own1 >/dev/null && fail "a lost runner passed"
case " $(reg usable "$HOME_DIR" | tr '\n' ' ')" in *" own1 "*) fail "a runner whose latest probe failed stayed usable" ;; esac
pass "a runner whose latest probe failed is no longer usable"

# The real doctor reports the three figures the probe reads.
doc=$(HOME="$TMP_ROOT" "$ROOT/bin/jg-remote-doctor.sh" 2>/dev/null)
for key in arch cores load1; do
  printf '%s\n' "$doc" | grep -q "^$key=[A-Za-z0-9_.]*$" || fail "the real doctor printed no $key= line"
done
pass "the real doctor prints arch, cores and load1"

echo "ALL TESTS PASSED"
