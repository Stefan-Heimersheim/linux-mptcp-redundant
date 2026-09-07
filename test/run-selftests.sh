#!/usr/bin/env bash
# test/run-selftests.sh — upstream MPTCP selftests as a regression gate.
#
# Runs, inside the vng guest (or on any host running the patched kernel):
#   1. tools/testing/selftests/net/mptcp/mptcp_connect.sh   (scheduler: default)
#   2. tools/testing/selftests/net/mptcp/mptcp_join.sh      (scheduler: default)
#   3. a subset of mptcp_join.sh with net.mptcp.scheduler=redundant set
#      globally (correctness/teardown groups); failures here are reported
#      but only the groups listed in REDUNDANT_MUST_PASS make the script fail.
#
# Exit 0 iff 1., 2. and the must-pass part of 3. succeed.
#
# Environment:
#   SELFTESTS       directory with the selftests (default: <repo>/linux-rpi/tools/testing/selftests/net/mptcp)
#   SKIP_CONNECT=1  skip mptcp_connect.sh
#   SKIP_JOIN=1     skip mptcp_join.sh (default scheduler)
#   SKIP_REDUNDANT=1 skip the redundant-scheduler subset
#   JOIN_ARGS       extra args for mptcp_join.sh (e.g. test ids)

set -u
set -o pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SELFTESTS="${SELFTESTS:-$ROOT/linux-rpi/tools/testing/selftests/net/mptcp}"
OUT="${OUT:-$ROOT/out/selftests}"
mkdir -p "$OUT"

# mptcp_join.sh groups (letters from all_tests_sorted in the script):
#   f subflows        e subflows_error   s signal_address   l link_failure
#   t add_addr_timeout r remove          a add              6 ipv6
#   4 v4mapped        M mixed            b backup           p add_addr_ports
#   k syncookies      S checksum         d deny_join_id0    m fullmesh
#   z fastclose       F fail             u userspace        I endpoint
# With the redundant scheduler every subflow carries every byte, so groups
# that measure per-link usage or expect a particular distribution (link
# failure, backup, fullmesh, ...) may legitimately differ. The must-pass set
# is about join handling, integrity, checksums and connection teardown; the
# rest runs for information and is reported.
REDUNDANT_MUST_PASS="${REDUNDANT_MUST_PASS:-f e s d z k S}"
REDUNDANT_INFO="${REDUNDANT_INFO:-l t r a 6 4 M b p m F u I}"

[ "$(id -u)" = 0 ] || { echo "must run as root" >&2; exit 2; }
[ -x "$SELFTESTS/mptcp_connect" ] || { echo "selftest binaries not built in $SELFTESTS" >&2; exit 2; }
cd "$SELFTESTS" || exit 2

sysctl -q -w net.mptcp.scheduler=default
rc=0

run() { # name log cmd...
	local name="$1" log="$2"; shift 2
	local t0 t1 r
	printf '\n#### %s: %s\n' "$name" "$*"
	t0=$(date +%s)
	"$@" > "$log" 2>&1; r=$?
	t1=$(date +%s)
	tail -n 15 "$log"
	printf '#### %s: exit %d after %ds (full log: %s)\n' "$name" "$r" "$((t1 - t0))" "$log"
	return $r
}

if [ "${SKIP_CONNECT:-0}" != 1 ]; then
	run "mptcp_connect.sh (default)" "$OUT/mptcp_connect.log" ./mptcp_connect.sh || rc=1
fi

if [ "${SKIP_JOIN:-0}" != 1 ]; then
	# shellcheck disable=SC2086
	run "mptcp_join.sh (default)" "$OUT/mptcp_join.log" ./mptcp_join.sh ${JOIN_ARGS:-} || rc=1
fi

if [ "${SKIP_REDUNDANT:-0}" != 1 ]; then
	if grep -qw redundant /proc/sys/net/mptcp/available_schedulers; then
		# mptcp_join.sh creates fresh namespaces; they inherit the *initial*
		# netns defaults, not the current value, so the scheduler is set via
		# a wrapper that patches the value into every new netns.
		export MPTCP_SCHED_OVERRIDE=redundant
		for g in $REDUNDANT_MUST_PASS; do
			run "mptcp_join.sh -$g (redundant, must pass)" "$OUT/mptcp_join-redundant-$g.log" \
				"$ROOT/test/join-with-sched.sh" -"$g" || rc=1
		done
		for g in $REDUNDANT_INFO; do
			run "mptcp_join.sh -$g (redundant, informational)" "$OUT/mptcp_join-redundant-$g.log" \
				"$ROOT/test/join-with-sched.sh" -"$g" || echo "#### (informational group -$g failed; not fatal)"
		done
	else
		echo "redundant scheduler not available in this kernel; skipping redundant subset"
		rc=1
	fi
fi

echo
[ $rc = 0 ] && echo "SELFTESTS PASSED" || echo "SELFTESTS FAILED"
exit $rc
