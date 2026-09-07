#!/usr/bin/env bash
# test/mptcp-redundant.sh — netns test for the MPTCP "redundant" scheduler.
#
# Builds a two-path topology between two network namespaces, transfers a
# random payload over one MPTCP connection with two subflows and measures how
# many bytes each path carried and how many duplicate segments the receiver
# discarded. Case 2 is a negative control with the stock "default" scheduler
# and must show that the per-path assertions of case 1 are NOT met.
#
#   ns "cli"                              ns "srv"
#     veth0  10.0.1.1/24  <---------->  10.0.1.2/24  veth0p     path 0
#     veth1  10.0.2.1/24  <---------->  10.0.2.2/24  veth1p     path 1
#
# The client connects 10.0.1.1 -> 10.0.1.2 (initial subflow, path 0). The
# in-kernel path manager in "cli" has a "subflow" endpoint for 10.0.2.1 and
# opens a second subflow 10.0.2.1 -> 10.0.1.2; a source-based policy route
# sends everything from 10.0.2.1 out of veth1, so that subflow uses path 1
# end to end (this mirrors the Pi's per-modem routing tables and the VPS's
# single public address).
#
# Must run as root (inside the vng guest or on a real host). Exit 0 iff all
# selected cases pass. Nothing here is VM specific.
#
# Environment:
#   PAYLOAD_MB     payload size in MiB (default 8; use 2 without KVM)
#   MPTCP_CONNECT  path to the selftests' mptcp_connect binary
#                  (default: <repo>/linux-rpi/tools/testing/selftests/net/mptcp/mptcp_connect)
#   CASES          space separated list of cases to run (default "1 2 3 4 5 6")
#   KEEP_NS=1      leave the namespaces of the last case in place (debugging)
#   WORK           scratch directory for payload/output files (default: mktemp -d)
#   PATH_DELAY_MS  one-way netem delay added to every veth (default 10 -> 20 ms RTT)
#   PATH_RATE      netem rate limit per veth (default 100mbit); 0 disables shaping
#   DEBUG=1        dump MPTCP counters of both namespaces after every transfer
#   MPTCP_REDUNDANT_LIB=1  only define the functions (for debugging scripts that
#                  source this file), do not run the cases

set -u
set -o pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PAYLOAD_MB="${PAYLOAD_MB:-8}"
PAYLOAD=$((PAYLOAD_MB * 1024 * 1024))
MPTCP_CONNECT="${MPTCP_CONNECT:-$ROOT/linux-rpi/tools/testing/selftests/net/mptcp/mptcp_connect}"
CASES="${CASES:-1 2 3 4 5 6 7}"
KEEP_NS="${KEEP_NS:-0}"
WORK="${WORK:-$(mktemp -d /tmp/mptcp-redundant.XXXXXX)}"
PATH_DELAY_MS="${PATH_DELAY_MS:-10}"
PATH_RATE="${PATH_RATE:-100mbit}"
PORT=10000
# Segment size used to turn the payload into an expected duplicate-segment
# count. Offloads are disabled on the veths, so on-wire segments are MSS sized
# (~1400 bytes for a 1500 MTU with MPTCP options); 1500 is deliberately
# generous.
SEG=1500

NS_CLI=cli
NS_SRV=srv

declare -a TABLE=()
FAILED=0

msg()  { printf '%s\n' "$*"; }
info() { printf '\n== %s\n' "$*"; }
pass() { printf '  PASS: %s\n' "$*"; }
fail() { printf '  FAIL: %s\n' "$*"; FAILED=1; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 2; }

# ---------------------------------------------------------------- topology

cleanup_ns() {
	ip netns del "$NS_CLI" 2>/dev/null || true
	ip netns del "$NS_SRV" 2>/dev/null || true
}

# setup_topology <with_second_endpoint:0|1> [path1_mtu]
setup_topology() {
	local second="$1" mtu1="${2:-}" ns dev

	cleanup_ns
	ip netns add "$NS_CLI" || die "cannot create netns (need root and CONFIG_NET_NS)"
	ip netns add "$NS_SRV"
	ip link add veth0 netns "$NS_CLI" type veth peer name veth0p netns "$NS_SRV" ||
		die "cannot create veth (CONFIG_VETH)"
	ip link add veth1 netns "$NS_CLI" type veth peer name veth1p netns "$NS_SRV"

	ip -n "$NS_CLI" addr add 10.0.1.1/24 dev veth0
	ip -n "$NS_CLI" addr add 10.0.2.1/24 dev veth1
	ip -n "$NS_SRV" addr add 10.0.1.2/24 dev veth0p
	ip -n "$NS_SRV" addr add 10.0.2.2/24 dev veth1p
	for dev in lo veth0 veth1; do ip -n "$NS_CLI" link set "$dev" up; done
	for dev in lo veth0p veth1p; do ip -n "$NS_SRV" link set "$dev" up; done
	if [ -n "$mtu1" ]; then
		# different MSS on the two paths: the copies then have shifted
		# segment boundaries and the receiver sees partially overlapping
		# segments (LTE modems commonly have MTUs of 1400-1500)
		ip -n "$NS_CLI" link set veth1 mtu "$mtu1"
		ip -n "$NS_SRV" link set veth1p mtu "$mtu1"
	fi

	# Traffic sourced from 10.0.2.1 (the second subflow) leaves via veth1 even
	# though the destination 10.0.1.2 is on veth0's subnet.
	ip -n "$NS_CLI" rule add from 10.0.2.1 lookup 102
	ip -n "$NS_CLI" route add 10.0.2.0/24 dev veth1 table 102
	ip -n "$NS_CLI" route add 10.0.1.0/24 via 10.0.2.2 dev veth1 table 102
	# The server must accept packets for 10.0.1.2 arriving on veth1p.
	for ns in "$NS_CLI" "$NS_SRV"; do
		ip netns exec "$ns" sysctl -q -w net.ipv4.conf.all.rp_filter=0 \
			net.ipv4.conf.default.rp_filter=0 net.mptcp.enabled=1
	done

	# Real links segment to the MSS; make the veths do the same so that
	# MPTcpExtDuplicateData counts MSS-sized segments and tx_bytes reflect
	# on-wire framing.
	for dev in veth0 veth1; do
		ip netns exec "$NS_CLI" ethtool -K "$dev" tso off gso off gro off >/dev/null 2>&1 || true
	done
	for dev in veth0p veth1p; do
		ip netns exec "$NS_SRV" ethtool -K "$dev" tso off gso off gro off >/dev/null 2>&1 || true
	done

	# Make the paths look like real links rather than a memory bus: without
	# a realistic RTT the peer acks a copy before the other subflow has send
	# buffer space to duplicate it (redundancy is best effort under memory
	# pressure), and without a rate limit an 8 MB transfer finishes in tens
	# of milliseconds, too fast to cut a link "mid-transfer".
	if [ "$PATH_DELAY_MS" != 0 ] || [ "$PATH_RATE" != 0 ]; then
		local opts=""
		[ "$PATH_DELAY_MS" != 0 ] && opts="$opts delay ${PATH_DELAY_MS}ms"
		[ "$PATH_RATE" != 0 ] && opts="$opts rate $PATH_RATE"
		for dev in veth0 veth1; do
			# shellcheck disable=SC2086
			tc -n "$NS_CLI" qdisc add dev "$dev" root netem $opts || die "tc netem failed (CONFIG_NET_SCH_NETEM)"
		done
		for dev in veth0p veth1p; do
			# shellcheck disable=SC2086
			tc -n "$NS_SRV" qdisc add dev "$dev" root netem $opts || die "tc netem failed"
		done
	fi

	ip -n "$NS_CLI" mptcp limits set subflows 4 add_addr_accepted 4
	ip -n "$NS_SRV" mptcp limits set subflows 4 add_addr_accepted 4
	if [ "$second" = 1 ]; then
		ip -n "$NS_CLI" mptcp endpoint add 10.0.2.1 dev veth1 subflow ||
			die "cannot add MPTCP endpoint (iproute2 without mptcp support?)"
	fi

	# connectivity sanity
	ip netns exec "$NS_CLI" ping -q -c1 -W2 10.0.1.2 >/dev/null || die "path 0 down"
	ip netns exec "$NS_CLI" ping -q -c1 -W2 -I 10.0.2.1 10.0.1.2 >/dev/null || die "path 1 (policy routed) down"
}

# ---------------------------------------------------------------- helpers

set_scheduler() { # ns name
	ip netns exec "$1" sh -c "echo $2 > /proc/sys/net/mptcp/scheduler" 2>/dev/null
}

tx_bytes() { # ns dev
	ip netns exec "$1" cat "/sys/class/net/$2/statistics/tx_bytes"
}

counter() { # ns MIB-name (nstat name), prints 0 when absent
	local v
	v=$(ip netns exec "$1" nstat -asz "$2" 2>/dev/null | awk 'NR==1 {next} {print $2}')
	printf '%s\n' "${v:-0}"
}

# copied from tools/testing/selftests/net/net_helper.sh
wait_local_port_listen() { # ns port
	local ns="$1" port="$2" pattern _i
	pattern=":$(printf '%04X' "$port") "
	pattern="${pattern}0A"
	for _i in $(seq 50); do
		# grep -c, not -q: with pipefail an early exit would kill awk with SIGPIPE
		if [ "$(ip netns exec "$ns" awk '{print $2" "$4}' /proc/net/tcp /proc/net/tcp6 2>/dev/null |
			grep -c "$pattern")" -gt 0 ]; then
			return 0
		fi
		sleep 0.1
	done
	return 1
}

now_ms() { date +%s%3N; }

PRELUDE=100
feed_payload() { head -c "$PRELUDE" "$1"; sleep 1.2; tail -c "+$((PRELUDE + 1))" "$1"; }

fmt_bytes() { awk -v b="$1" 'BEGIN { printf "%.2fM", b / 1048576 }'; }
pct() { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.0f", 100 * a / b }'; }
ge() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a >= b) }'; }
lt() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a < b) }'; }

# ---------------------------------------------------------------- transfer

# Results of the last transfer (globals)
T_MS=0 T_XFER=0 T_TX0=0 T_TX1=0 T_DUP=0 T_JOINS=0 T_STALL=0 T_CUT_AT=- T_RETRANS=0

# run_transfer <sender: cli|srv> <scheduler> <pre-hook fn or -> <mid-hook fn or ->
#
# The listener always lives in srv and the connecting client in cli; only the
# direction of the payload changes with <sender>.
run_transfer() {
	local sender="$1" sched="$2" pre="$3" mid="$4"
	local rcv sdev0 sdev1 sin cin sout cout rout
	local tx0_a tx1_a dup_a ja_a js_a rt_a tx0_b tx1_b dup_b ja_b js_b rt_b
	local spid cpid mpid monpid rets retc t0 t1

	T_MS=0 T_XFER=0 T_TX0=0 T_TX1=0 T_DUP=0 T_JOINS=0 T_STALL=0 T_CUT_AT=- T_RETRANS=0
	if [ "$sender" = cli ]; then
		rcv=$NS_SRV; sdev0=veth0; sdev1=veth1
		cin="$WORK/payload"; sin=/dev/null; rout="$WORK/srv.out"
	else
		rcv=$NS_CLI; sdev0=veth0p; sdev1=veth1p
		sin="$WORK/payload"; cin=/dev/null; rout="$WORK/cli.out"
	fi
	sout="$WORK/srv.out"; cout="$WORK/cli.out"
	rm -f "$sout" "$cout"; : > "$rout"

	# scheduler: set on the sender, default on the receiver, before the
	# sockets are created (msk->sched is fixed at socket creation).
	# Written via /proc directly: `sysctl -q -w` of this string key fails
	# with "No such file or directory" on procps-ng 4.x.
	set_scheduler "$NS_CLI" default
	set_scheduler "$NS_SRV" default
	if ! set_scheduler "$([ "$sender" = cli ] && echo "$NS_CLI" || echo "$NS_SRV")" "$sched"; then
		msg "  cannot set net.mptcp.scheduler=$sched (available: $(cat /proc/sys/net/mptcp/available_schedulers))"
		return 1
	fi

	[ "$pre" != - ] && "$pre"

	local sns
	sns="$([ "$sender" = cli ] && echo "$NS_CLI" || echo "$NS_SRV")"
	tx0_a=$(tx_bytes "$sns" "$sdev0"); tx1_a=$(tx_bytes "$sns" "$sdev1")
	dup_a=$(counter "$rcv" MPTcpExtDuplicateData)
	ja_a=$(counter "$NS_SRV" MPTcpExtMPJoinAckRx); js_a=$(counter "$NS_CLI" MPTcpExtMPJoinSynAckRx)
	rt_a=$(counter "$sns" TcpRetransSegs)

	# The side with nothing to send would shut down its write side right
	# away; the resulting DATA_FIN moves the connection out of ESTABLISHED
	# and the kernel then refuses new subflows (mptcp_finish_join()), so the
	# MP_JOIN would race with it. "-w 1" makes mptcp_connect sleep 1 s
	# before that shutdown. The sleep is synchronous, so the idle side does
	# not read for the first second either: the sender fills the receive
	# window and stalls until then. wall_ms includes that second; xfer_ms
	# and the stall metric start with the first received byte and do not.
	# The sender's stdin is a pipe that delivers a 100-byte prelude at once,
	# then nothing for 1.2 s, then the rest. The prelude makes the peer send
	# a DSS ack, which is what marks the client's connection "fully
	# established" and lets its path manager open the second subflow (the
	# same trick as mptcp_connect's -j). The pause keeps the timing metrics
	# honest: the bulk only starts once the idle side is reading again, and
	# xfer_ms/stall ignore everything up to the prelude size.
	#
	# The listener always gets "-j": without it mptcp_connect closes its
	# listening socket after accept() (maybe_close()), and an MP_JOIN SYN
	# arriving later is answered with a plain RST because it needs a
	# listener to land on (the upstream MPJ selftests rely on -j for the
	# same reason; a real server such as ssserver keeps listening anyway).
	local sargs cargs
	if [ "$sender" = cli ]; then sargs="-j -w 1"; cargs=""; else sargs="-j"; cargs="-w 1"; fi
	# shellcheck disable=SC2086
	if [ "$sender" = srv ]; then
		feed_payload "$sin" | timeout 120 ip netns exec "$NS_SRV" "$MPTCP_CONNECT" $sargs -t 30 -l -p "$PORT" -s MPTCP 10.0.1.2 \
			> "$sout" 2> "$WORK/srv.err" &
	else
		timeout 120 ip netns exec "$NS_SRV" "$MPTCP_CONNECT" $sargs -t 30 -l -p "$PORT" -s MPTCP 10.0.1.2 \
			< "$sin" > "$sout" 2> "$WORK/srv.err" &
	fi
	spid=$!
	wait_local_port_listen "$NS_SRV" "$PORT" || { msg "  listener did not come up"; kill $spid 2>/dev/null; return 1; }

	# progress monitor: log receiver file size every 50 ms
	: > "$WORK/progress"
	( while :; do printf '%s %s\n' "$(now_ms)" "$(stat -c %s "$rout" 2>/dev/null || echo 0)"; sleep 0.05; done ) \
		>> "$WORK/progress" &
	monpid=$!

	t0=$(now_ms)
	# shellcheck disable=SC2086
	if [ "$sender" = cli ]; then
		feed_payload "$cin" | timeout 120 ip netns exec "$NS_CLI" "$MPTCP_CONNECT" $cargs -t 30 -p "$PORT" -s MPTCP 10.0.1.2 \
			> "$cout" 2> "$WORK/cli.err" &
	else
		timeout 120 ip netns exec "$NS_CLI" "$MPTCP_CONNECT" $cargs -t 30 -p "$PORT" -s MPTCP 10.0.1.2 \
			< "$cin" > "$cout" 2> "$WORK/cli.err" &
	fi
	cpid=$!

	mpid=
	if [ "$mid" != - ]; then
		"$mid" "$rout" &
		mpid=$!
	fi

	wait $cpid; retc=$?
	wait $spid; rets=$?
	t1=$(now_ms)
	kill $monpid 2>/dev/null; wait $monpid 2>/dev/null
	[ -n "$mpid" ] && { wait $mpid; T_CUT_AT=$(cat "$WORK/cut_at" 2>/dev/null || echo '?'); }

	tx0_b=$(tx_bytes "$sns" "$sdev0"); tx1_b=$(tx_bytes "$sns" "$sdev1")
	dup_b=$(counter "$rcv" MPTcpExtDuplicateData)
	ja_b=$(counter "$NS_SRV" MPTcpExtMPJoinAckRx); js_b=$(counter "$NS_CLI" MPTcpExtMPJoinSynAckRx)
	rt_b=$(counter "$sns" TcpRetransSegs)

	if [ "${DEBUG:-0}" = 1 ]; then
		msg "  --- $NS_CLI MPTcp counters:"; ip netns exec "$NS_CLI" nstat -a 2>/dev/null | grep MPTcp | sed 's/^/      /'
		msg "  --- $NS_SRV MPTcp counters:"; ip netns exec "$NS_SRV" nstat -a 2>/dev/null | grep MPTcp | sed 's/^/      /'
		msg "  --- exit codes client=$retc server=$rets; stderr:"; sed 's/^/      cli: /' "$WORK/cli.err"; sed 's/^/      srv: /' "$WORK/srv.err"
	fi

	T_MS=$((t1 - t0))
	T_TX0=$((tx0_b - tx0_a)); T_TX1=$((tx1_b - tx1_a))
	T_DUP=$((dup_b - dup_a)); T_RETRANS=$((rt_b - rt_a))
	# both counters must agree for the join to count
	if [ $((ja_b - ja_a)) -eq $((js_b - js_a)) ]; then T_JOINS=$((ja_b - ja_a)); else T_JOINS="$((ja_b - ja_a))/$((js_b - js_a))"; fi
	# longest gap (ms) between two samples where the received size grew, and
	# the duration of the data phase (first growth -> last growth); the wall
	# time also contains the handshakes and the deliberate 1 s close delay
	T_STALL=$(awk -v pre="$PRELUDE" 'BEGIN { last=0; size=pre; max=0 }
		$2 > size { if (last) { gap=$1-last; if (gap>max) max=gap }; last=$1; size=$2 }
		END { print max+0 }' "$WORK/progress")
	T_XFER=$(awk -v pre="$PRELUDE" 'BEGIN { first=0; last=0; size=pre }
		$2 > size { if (!first) first=$1; last=$1; size=$2 }
		END { print (last-first)+0 }' "$WORK/progress")

	if [ $retc -ne 0 ] || [ $rets -ne 0 ]; then
		msg "  mptcp_connect exit codes: client=$retc server=$rets"
		sed 's/^/    cli: /' "$WORK/cli.err" | head -5
		sed 's/^/    srv: /' "$WORK/srv.err" | head -5
		return 1
	fi
	if ! cmp -s "$WORK/payload" "$rout"; then
		msg "  integrity: received file differs from payload ($(stat -c %s "$rout") vs $PAYLOAD bytes)"
		return 1
	fi
	return 0
}

record() { # case sched dir result note
	TABLE+=("$(printf '%-4s %-9s %-7s %-4s %7s %7s %9s %9s %7s %5s %7s %7s %s' \
		"$1" "$2" "$3" "$4" "$T_MS" "$T_XFER" "$(fmt_bytes "$T_TX0")" "$(fmt_bytes "$T_TX1")" \
		"$T_DUP" "$T_JOINS" "$T_STALL" "$T_RETRANS" "$5")")
}

print_table() {
	printf '\n%s\n' "== Results (payload $(fmt_bytes "$PAYLOAD"), kernel $(uname -r))"
	printf '%-4s %-9s %-7s %-4s %7s %7s %9s %9s %7s %5s %7s %7s %s\n' \
		case sched dir res wall_ms xfer_ms tx_path0 tx_path1 dupseg joins stall retrans note
	local row; for row in "${TABLE[@]}"; do printf '%s\n' "$row"; done
	printf 'wall_ms: process lifetime incl. handshakes and close; xfer_ms: first to last byte received;\n'
	printf 'tx_path0/1: sender tx_bytes on the two veths; dupseg: MPTcpExtDuplicateData delta on the receiver;\n'
	printf 'joins: MP_JOIN handshakes seen; stall: longest gap (ms) without receive progress; retrans: sender TcpRetransSegs delta\n'
}

# assertions -------------------------------------------------------------

# each path carried >= 90 %% of the payload and the receiver saw >= 0.5 * payload/SEG duplicate segments
assert_redundant() {
	local ok=1 min_tx min_dup
	min_tx=$(awk -v p="$PAYLOAD" 'BEGIN { printf "%d", 0.9 * p }')
	min_dup=$(awk -v p="$PAYLOAD" -v s="$SEG" 'BEGIN { printf "%d", 0.5 * p / s }')
	[ "$T_JOINS" = 1 ] && pass "two subflows existed (1 MP_JOIN)" || { fail "expected exactly 1 MP_JOIN, saw $T_JOINS"; ok=0; }
	ge "$T_TX0" "$min_tx" && pass "path 0 carried $(pct "$T_TX0" "$PAYLOAD")% of payload (>= 90%)" || { fail "path 0 carried only $(pct "$T_TX0" "$PAYLOAD")% of payload"; ok=0; }
	ge "$T_TX1" "$min_tx" && pass "path 1 carried $(pct "$T_TX1" "$PAYLOAD")% of payload (>= 90%)" || { fail "path 1 carried only $(pct "$T_TX1" "$PAYLOAD")% of payload"; ok=0; }
	ge "$T_DUP" "$min_dup" && pass "receiver discarded $T_DUP duplicate segments (>= $min_dup)" || { fail "only $T_DUP duplicate segments at the receiver (expected >= $min_dup)"; ok=0; }
	[ $ok = 1 ]
}

# negative control: at least one path carried < 60 %% of the payload
assert_not_redundant() {
	local max_tx
	max_tx=$(awk -v p="$PAYLOAD" 'BEGIN { printf "%d", 0.6 * p }')
	[ "$T_JOINS" = 1 ] || { fail "expected exactly 1 MP_JOIN, saw $T_JOINS"; return 1; }
	if lt "$T_TX0" "$max_tx" || lt "$T_TX1" "$max_tx"; then
		pass "paths carried $(pct "$T_TX0" "$PAYLOAD")% / $(pct "$T_TX1" "$PAYLOAD")%: at least one < 60%, default scheduler distributes"
		return 0
	fi
	fail "both paths carried >= 60% ($(pct "$T_TX0" "$PAYLOAD")% / $(pct "$T_TX1" "$PAYLOAD")%) with the default scheduler: the control did not behave as a control"
	return 1
}

# hooks -----------------------------------------------------------------

# wait (up to 5 s) until the MP_JOIN handshake has completed
wait_join() {
	local _i
	for _i in $(seq 100); do
		[ "$(counter "$NS_SRV" MPTcpExtMPJoinAckRx)" -ge 1 ] && return 0
		sleep 0.05
	done
	return 1
}

# 30 % loss on path 1 in both directions, applied once the second subflow
# is established (a lost MP_JOIN SYN would otherwise be retried only after
# 1 s and could race the idle side's DATA_FIN, see run_transfer)
hook_loss_path1() {
	local opts=""
	[ "$PATH_DELAY_MS" != 0 ] && opts="$opts delay ${PATH_DELAY_MS}ms"
	[ "$PATH_RATE" != 0 ] && opts="$opts rate $PATH_RATE"
	wait_join || msg "  warning: MP_JOIN not seen before applying loss"
	# shellcheck disable=SC2086
	tc -n "$NS_CLI" qdisc replace dev veth1 root netem $opts loss 30% || die "tc netem failed (CONFIG_NET_SCH_NETEM)"
	# shellcheck disable=SC2086
	tc -n "$NS_SRV" qdisc replace dev veth1p root netem $opts loss 30% || die "tc netem failed"
	: > "$WORK/cut_at"
}

# bring path 1 down once ~40 % of the payload has been received
hook_cut_path1() {
	local rout="$1" size=0 limit
	limit=$(awk -v p="$PAYLOAD" 'BEGIN { printf "%d", 0.4 * p }')
	while [ "$size" -lt "$limit" ]; do
		sleep 0.02
		size=$(stat -c %s "$rout" 2>/dev/null || echo 0)
		[ "$size" -ge "$PAYLOAD" ] && break
	done
	ip -n "$NS_CLI" link set veth1 down
	printf '%s' "$(pct "$size" "$PAYLOAD")%" > "$WORK/cut_at"
}

# ---------------------------------------------------------------- main

if [ "${MPTCP_REDUNDANT_LIB:-0}" = 1 ]; then
	return 0 2>/dev/null || exit 0
fi

[ "$(id -u)" = 0 ] || die "must run as root"
[ -x "$MPTCP_CONNECT" ] || die "mptcp_connect not found at $MPTCP_CONNECT (set MPTCP_CONNECT)"
[ -f /proc/sys/net/mptcp/enabled ] || die "kernel without CONFIG_MPTCP"
for t in ip tc nstat ethtool ping cmp awk timeout; do command -v $t >/dev/null || die "missing tool: $t"; done
mkdir -p "$WORK"
msg "payload: $PAYLOAD_MB MiB, paths: netem delay ${PATH_DELAY_MS}ms rate ${PATH_RATE} per direction, work dir: $WORK"
msg "available schedulers: $(cat /proc/sys/net/mptcp/available_schedulers)"
head -c "$PAYLOAD" /dev/urandom > "$WORK/payload"

trap '[ "$KEEP_NS" = 1 ] || cleanup_ns' EXIT

CASE1_MS=0
for c in $CASES; do
	case "$c" in
	1)
		info "case 1: redundant scheduler, clean links, cli -> srv"
		setup_topology 1
		if run_transfer cli redundant - - && assert_redundant; then
			record 1 redundant 'cli>srv' PASS ""; CASE1_MS=$T_XFER
		else
			record 1 redundant 'cli>srv' FAIL ""; FAILED=1
		fi
		;;
	2)
		info "case 2: negative control, default scheduler, clean links, cli -> srv"
		setup_topology 1
		if run_transfer cli default - - && assert_not_redundant; then
			record 2 default 'cli>srv' PASS "control"
		else
			record 2 default 'cli>srv' FAIL "control"; FAILED=1
		fi
		;;
	3)
		info "case 3: redundant scheduler, 30% loss on path 1"
		setup_topology 1
		if run_transfer cli redundant - hook_loss_path1; then
			ok=1
			[ "$T_JOINS" = 1 ] && pass "two subflows existed" || { fail "expected 1 MP_JOIN, saw $T_JOINS"; ok=0; }
			if [ "$CASE1_MS" -gt 0 ]; then
				limit=$((3 * CASE1_MS)); [ $limit -lt 1000 ] && limit=1000
				[ "$T_XFER" -le "$limit" ] && pass "data phase took ${T_XFER} ms (<= 3x case 1 = ${limit} ms)" || { fail "data phase took ${T_XFER} ms, more than 3x case 1 (${limit} ms)"; ok=0; }
			else
				msg "  (case 1 not run: no timing comparison)"
			fi
			[ $ok = 1 ] && record 3 redundant 'cli>srv' PASS "loss30%" || { record 3 redundant 'cli>srv' FAIL "loss30%"; FAILED=1; }
		else
			record 3 redundant 'cli>srv' FAIL "loss30%"; FAILED=1
		fi
		;;
	4)
		info "case 4: redundant scheduler, path 1 cut mid-transfer"
		setup_topology 1
		if run_transfer cli redundant - hook_cut_path1; then
			ok=1
			[ "$T_JOINS" = 1 ] && pass "two subflows existed" || { fail "expected 1 MP_JOIN, saw $T_JOINS"; ok=0; }
			msg "  path 1 was cut when $T_CUT_AT of the payload had been received"
			[ "$T_STALL" -le 2000 ] && pass "longest stall ${T_STALL} ms (<= 2000)" || { fail "receive progress stalled for ${T_STALL} ms"; ok=0; }
			[ $ok = 1 ] && record 4 redundant 'cli>srv' PASS "cut@$T_CUT_AT" || { record 4 redundant 'cli>srv' FAIL "cut@$T_CUT_AT"; FAILED=1; }
		else
			record 4 redundant 'cli>srv' FAIL "cut@$T_CUT_AT"; FAILED=1
		fi
		;;
	5)
		info "case 5: redundant scheduler, single subflow"
		setup_topology 0
		if run_transfer cli redundant - -; then
			ok=1
			[ "$T_JOINS" = 0 ] && pass "no MP_JOIN" || { fail "expected 0 MP_JOIN, saw $T_JOINS"; ok=0; }
			min_tx=$(awk -v p="$PAYLOAD" 'BEGIN { printf "%d", 0.9 * p }')
			max_tx1=$(awk -v p="$PAYLOAD" 'BEGIN { printf "%d", 0.01 * p }')
			max_dup=$(awk -v p="$PAYLOAD" -v s="$SEG" 'BEGIN { printf "%d", 0.01 * p / s }')
			ge "$T_TX0" "$min_tx" && pass "path 0 carried $(pct "$T_TX0" "$PAYLOAD")%" || { fail "path 0 carried only $(pct "$T_TX0" "$PAYLOAD")%"; ok=0; }
			lt "$T_TX1" "$max_tx1" && pass "path 1 idle ($T_TX1 bytes)" || { fail "path 1 carried $T_TX1 bytes with a single subflow"; ok=0; }
			[ "$T_DUP" -le "$max_dup" ] && pass "$T_DUP duplicate segments (<= $max_dup)" || { fail "$T_DUP duplicate segments with a single subflow"; ok=0; }
			[ $ok = 1 ] && record 5 redundant 'cli>srv' PASS "1 subflow" || { record 5 redundant 'cli>srv' FAIL "1 subflow"; FAILED=1; }
		else
			record 5 redundant 'cli>srv' FAIL "1 subflow"; FAILED=1
		fi
		;;
	6)
		info "case 6: redundant scheduler, clean links, srv -> cli (roles swapped)"
		setup_topology 1
		if run_transfer srv redundant - - && assert_redundant; then
			record 6 redundant 'srv>cli' PASS ""
		else
			record 6 redundant 'srv>cli' FAIL ""; FAILED=1
		fi
		;;
	7)
		info "case 7: redundant scheduler, path 1 with MTU 1400 (shifted segment boundaries)"
		setup_topology 1 1400
		if run_transfer cli redundant - - && assert_redundant; then
			record 7 redundant 'cli>srv' PASS "mtu1400"
		else
			record 7 redundant 'cli>srv' FAIL "mtu1400"; FAILED=1
		fi
		;;
	*) die "unknown case $c" ;;
	esac
done

print_table
if [ $FAILED = 0 ]; then msg "ALL SELECTED CASES PASSED"; else msg "SOME CASES FAILED"; fi
exit $FAILED
