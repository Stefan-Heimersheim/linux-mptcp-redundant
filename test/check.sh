#!/usr/bin/env bash
# test/check.sh — build-and-test loop for linux-mptcp-redundant.
#
# Builds the x86_64 test kernel from linux-rpi/ (in tree), boots it with
# virtme-ng and runs test/mptcp-redundant.sh (positive test, negative control,
# loss, link cut, single subflow, reverse direction) and, unless SKIP_SELFTESTS
# is set, test/run-selftests.sh (upstream mptcp_connect.sh / mptcp_join.sh).
# Exit 0 iff everything passed.
#
# Modes for the kernel source:
#   default          use linux-rpi/ as it is (developer loop). The tree must be
#                    based on RPI_REV; uncommitted changes are built as they are.
#   --from-patches   reset branch mptcp-redundant to RPI_REV and `git am` the
#                    series in patches/ (refuses if the tree is dirty). This is
#                    the reproducible mode.
#
# Options / environment:
#   --no-build         skip the kernel build (reuse the existing image)
#   --debug            build in build-x86-debug/ with DEBUG_LIST, PROVE_LOCKING,
#                      KASAN (slow)
#   --stable           build in build-x86-stable/ from upstream stable STABLE_REV
#                      + patches/ (the VPS base) instead of the linux-rpi tree
#   --reconfig         regenerate .config from defconfig + test/x86-test.config
#                      (done automatically when .config is missing)
#   SKIP_SELFTESTS=1   only run test/mptcp-redundant.sh
#   SKIP_REDUNDANT_TEST=1  only run the upstream selftests
#   CASES="1 2"        forwarded to test/mptcp-redundant.sh
#   PAYLOAD_MB=N       forwarded (default 8 with /dev/kvm, 2 without)
#   VNG_CPUS / VNG_MEM guest size (default 4 / 2G)
#   JOBS               make -j (default nproc)

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/linux-rpi"
OUT="$ROOT/out"
# shellcheck source=../build-lib.sh
. "$ROOT/build-lib.sh"

BUILD=1 DEBUG=0 RECONFIG=0 FROM_PATCHES=0 STABLE=0
while [ $# -gt 0 ]; do
	case "$1" in
	--no-build) BUILD=0 ;;
	--debug) DEBUG=1 ;;
	--stable) STABLE=1 ;;
	--reconfig) RECONFIG=1 ;;
	--from-patches) FROM_PATCHES=1 ;;
	-h|--help) sed -n '2,30p' "$0"; exit 0 ;;
	*) die "unknown argument: $1" ;;
	esac
	shift
done

JOBS="${JOBS:-$(nproc)}"
VNG_CPUS="${VNG_CPUS:-4}"
VNG_MEM="${VNG_MEM:-2G}"
mkdir -p "$OUT"

for t in vng qemu-system-x86_64 ip tc nstat ss ethtool; do
	command -v "$t" >/dev/null || die "missing tool: $t (see README.md, Test)"
done
if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
	KVM=1; PAYLOAD_MB="${PAYLOAD_MB:-8}"
else
	KVM=0; PAYLOAD_MB="${PAYLOAD_MB:-2}"
	warn "/dev/kvm not usable: the guest runs under TCG, expect ~10x slower runs; payload ${PAYLOAD_MB} MiB"
fi

# ---------------------------------------------------------------- source
if [ "$FROM_PATCHES" = 1 ]; then
	source_tree_from_patches
else
	[ -d "$SRC/.git" ] || die "$SRC is not a git checkout; run ./build-kernel.sh --source-only or test/check.sh --from-patches"
	git -C "$SRC" merge-base --is-ancestor "$RPI_REV" HEAD ||
		die "linux-rpi HEAD is not based on RPI_REV=$RPI_REV"
	info "source: $(git -C "$SRC" log --oneline -1) (developer mode; $(git -C "$SRC" status --short | wc -l) uncommitted change(s))"
	git -C "$SRC" log --oneline "$RPI_REV..HEAD" | sed 's/^/    /'
fi

# ---------------------------------------------------------------- build
# The normal test kernel is built in tree (vng finds arch/x86/boot/bzImage).
# The debug variant lives in its own worktree so the two configs never fight.
if [ "$STABLE" = 1 ]; then
	[ "$DEBUG" = 0 ] || die "--stable and --debug cannot be combined"
	O="$ROOT/build-x86-stable/linux"
	patched_worktree "$O" "$STABLE_REV"
elif [ "$DEBUG" = 1 ]; then
	O="$ROOT/build-x86-debug/linux"
	ensure_worktree "$O"
else
	O="$SRC"
fi
KIMG="$O/arch/x86/boot/bzImage"
BUILD_LOG="$OUT/build-x86-$([ "$DEBUG" = 1 ] && echo debug || echo test).log"

configure() {
	info "configuring x86_64 test kernel in $O"
	make -s -C "$O" defconfig
	"$O/scripts/kconfig/merge_config.sh" -m -O "$O" "$O/.config" "$ROOT/test/x86-test.config" >/dev/null
	if [ "$DEBUG" = 1 ]; then
		"$O/scripts/kconfig/merge_config.sh" -m -O "$O" "$O/.config" "$ROOT/test/x86-debug.config" >/dev/null
	fi
	make -s -C "$O" olddefconfig
	for opt in MPTCP MPTCP_IPV6 VETH NET_SCH_NETEM NET_NS VIRTIO_FS; do
		grep -q "^CONFIG_$opt=y" "$O/.config" || die "CONFIG_$opt not enabled after olddefconfig"
	done
	if [ "$DEBUG" = 1 ]; then
		for opt in KASAN PROVE_LOCKING DEBUG_LIST; do
			grep -q "^CONFIG_$opt=y" "$O/.config" || die "debug option CONFIG_$opt not enabled"
		done
	fi
}

if [ "$BUILD" = 1 ]; then
	if [ "$RECONFIG" = 1 ] || [ ! -f "$O/.config" ]; then
		configure
	fi
	info "building x86_64 kernel (log: $BUILD_LOG)"
	if ! make -C "$O" -j"$JOBS" > "$BUILD_LOG" 2>&1; then
		tail -30 "$BUILD_LOG"; die "kernel build failed"
	fi
	if grep -E 'net/mptcp/.*warning' "$BUILD_LOG"; then
		die "compiler warnings in net/mptcp/ (see $BUILD_LOG)"
	fi
	info "building mptcp selftest binaries"
	make -s -C "$SRC" headers >/dev/null
	make -s -C "$SRC/tools/testing/selftests/net/mptcp" >/dev/null
fi
[ -f "$KIMG" ] || die "no kernel image at $KIMG"
[ -x "$SRC/tools/testing/selftests/net/mptcp/mptcp_connect" ] || die "mptcp_connect not built"

# cheap insurance against the "renamed default scheduler" mistake
assert_redundant_scheduler_built "$O"

# ---------------------------------------------------------------- run
# vng needs real stdio ("not a valid pts" otherwise); when not on a terminal
# redirect everything to a log file and print it afterwards.
run_vng() { # name script [env...]
	local name="$1" script="$2"; shift 2
	local log="$OUT/$name.log" rc
	info "running $script in the guest ($VNG_CPUS cpus, $VNG_MEM; log: $log)"
	# --verbose keeps the guest kernel console in the log (exec mode sends it
	# to /dev/null otherwise), which is what makes the splat check below work.
	local cmd=(vng --run "$KIMG" --cpus "$VNG_CPUS" --memory "$VNG_MEM" --rw --cwd "$ROOT"
		--verbose --append 'loglevel=7'
		--exec "env PAYLOAD_MB=$PAYLOAD_MB CASES='${CASES:-1 2 3 4 5 6 7}' $* bash $script")
	[ "$KVM" = 1 ] || cmd+=(--disable-kvm)
	if [ -t 0 ] && [ -t 1 ]; then
		"${cmd[@]}" 2>&1 | tee "$log"; rc=${PIPESTATUS[0]}
	else
		"${cmd[@]}" < /dev/null > "$log" 2>&1; rc=$?
		grep -v -E '^\[ *[0-9.]+\] ' "$log" | grep -v '^$'
	fi
	# kernel splats in the guest fail the run even if the script passed
	local splat='WARNING: CPU|BUG:|Oops|KASAN|possible circular locking|INFO: task .* blocked|rcu: INFO|soft lockup|divide error'
	if grep -q -E "$splat" "$log"; then
		warn "kernel splat in guest log $log:"
		grep -E -A5 "$splat" "$log" | head -60
		return 1
	fi
	return $rc
}

RC=0
if [ "${SKIP_REDUNDANT_TEST:-0}" != 1 ]; then
	run_vng "test-mptcp-redundant$([ "$DEBUG" = 1 ] && echo -debug)" "$ROOT/test/mptcp-redundant.sh" || RC=1
fi
if [ "${SKIP_SELFTESTS:-0}" != 1 ]; then
	run_vng "test-selftests$([ "$DEBUG" = 1 ] && echo -debug)" "$ROOT/test/run-selftests.sh" || RC=1
fi

echo
if [ $RC = 0 ]; then ok "check.sh: ALL PASSED (kernel $(make -s -C "$O" kernelrelease 2>/dev/null))"; else die "check.sh: FAILED"; fi
