#!/usr/bin/env bash
# test/join-with-sched.sh — run mptcp_join.sh with a non-default scheduler.
#
# mptcp_join.sh creates fresh network namespaces for every test; a new netns
# starts with the kernel default (net.mptcp.scheduler=default), not with the
# value of the parent namespace. There is no knob in mptcp_join.sh for the
# scheduler, so this wrapper puts a shim `ip` first in PATH that, after every
# successful `ip netns add NAME`, writes $MPTCP_SCHED_OVERRIDE into that
# namespace's net.mptcp.scheduler. Everything else is passed through.
#
# Usage: MPTCP_SCHED_OVERRIDE=redundant test/join-with-sched.sh [mptcp_join.sh args]
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SELFTESTS="${SELFTESTS:-$ROOT/linux-rpi/tools/testing/selftests/net/mptcp}"
: "${MPTCP_SCHED_OVERRIDE:?set MPTCP_SCHED_OVERRIDE to the scheduler name}"

SHIM="$(mktemp -d /tmp/ipshim.XXXXXX)"
REAL_IP="$(command -v ip)"
cat > "$SHIM/ip" <<SHIMEOF
#!/usr/bin/env bash
"$REAL_IP" "\$@"
rc=\$?
if [ \$rc = 0 ] && [ "\${1:-}" = netns ] && [ "\${2:-}" = add ] && [ -n "\${3:-}" ]; then
	"$REAL_IP" netns exec "\$3" sh -c 'echo $MPTCP_SCHED_OVERRIDE > /proc/sys/net/mptcp/scheduler' 2>/dev/null
fi
exit \$rc
SHIMEOF
chmod +x "$SHIM/ip"
trap 'rm -rf "$SHIM"' EXIT

cd "$SELFTESTS" || exit 2
PATH="$SHIM:$PATH" ./mptcp_join.sh "$@"
