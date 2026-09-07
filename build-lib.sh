#!/usr/bin/env bash
# build-lib.sh — shared helpers for build-kernel.sh and test/check.sh:
# pinned source revision, patch application, post-build assertions.
# Sourced, not executed. Expects ROOT and SRC to be set by the caller.

# Pinned sources, both Linux 6.12.107. Never build from a moving branch; bump
# these deliberately and together.
# Pi (arm64): raspberrypi/linux branch rpi-6.12.y as of 2026-08-28
# ("serial: sc16is7xx: Don't spin if no data received").
RPI_REV="${RPI_REV:-1138716fb8a796625e519982e53a7b3c89e76ca4}"
RPI_REPO="${RPI_REPO:-https://github.com/raspberrypi/linux}"
RPI_BRANCH="${RPI_BRANCH:-rpi-6.12.y}"
# VPS (x86_64): upstream stable tag v6.12.107 (the rpi tree is this plus the
# Pi downstream patches; net/mptcp is identical in both). Fetched into $SRC too.
STABLE_REV="${STABLE_REV:-f717995cb7dcd8998ab15516b8006aea09cfde0d}"
STABLE_REPO="${STABLE_REPO:-https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git}"
STABLE_TAG="${STABLE_TAG:-v6.12.107}"
WORK_BRANCH="mptcp-redundant"
PATCHES="$ROOT/patches"

info(){ printf '\n\033[1;34m>>> %s\033[0m\n' "$*"; }
ok(){ printf '\033[1;32mOK %s\033[0m\n' "$*"; }
warn(){ printf '\033[1;33mWARNING: %s\033[0m\n' "$*" >&2; }
die(){ printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# Make sure $SRC contains RPI_REV and STABLE_REV (clone or fetch as needed).
fetch_source(){
	if [ ! -d "$SRC/.git" ]; then
		info "cloning $RPI_REPO ($RPI_BRANCH) into $SRC"
		git clone --depth=1 --branch "$RPI_BRANCH" "$RPI_REPO" "$SRC"
	fi
	fetch_rev "$RPI_REPO" "$RPI_REV"
	fetch_rev "$STABLE_REPO" "$STABLE_REV" "$STABLE_TAG"
}

fetch_rev(){ # repo rev [ref]
	local repo="$1" rev="$2" ref="${3:-$2}"
	git -C "$SRC" cat-file -e "$rev^{commit}" 2>/dev/null && return 0
	info "fetching pinned revision $rev ($ref) from $repo"
	git -C "$SRC" fetch --depth=1 "$repo" "$ref" ||
		die "cannot fetch $ref from $repo"
	git -C "$SRC" cat-file -e "$rev^{commit}" 2>/dev/null ||
		die "$ref from $repo is not $rev; is the pin correct?"
}

# Reset branch $WORK_BRANCH to RPI_REV and apply patches/*.patch with git am.
# Aborts loudly on a dirty tree or a patch that does not apply.
source_tree_from_patches(){
	fetch_source
	if [ -n "$(git -C "$SRC" status --porcelain --untracked-files=no)" ]; then
		die "$SRC has uncommitted changes; commit or stash them before --from-patches / a release build"
	fi
	local n
	n=$(find "$PATCHES" -maxdepth 1 -name '*.patch' | wc -l)
	[ "$n" -gt 0 ] || die "no patches in $PATCHES"
	info "checking out $RPI_REV on branch $WORK_BRANCH and applying $n patch(es)"
	git -C "$SRC" checkout -q -B "$WORK_BRANCH" "$RPI_REV"
	git -C "$SRC" am --abort 2>/dev/null || true
	if ! git -C "$SRC" am --3way "$PATCHES"/*.patch; then
		git -C "$SRC" am --abort || true
		die "patches from $PATCHES do not apply on $RPI_REV"
	fi
	git -C "$SRC" log --oneline "$RPI_REV..HEAD" | sed 's/^/    /'
	ok "source at $(git -C "$SRC" rev-parse --short HEAD) = $RPI_REV + patches"
}

# Kbuild refuses O= builds while the source tree has an in-tree build (the
# test kernel is built in tree so vng finds it). Every other build therefore
# gets its own detached git worktree of $SRC's HEAD, built in tree there.
ensure_worktree(){ # dir
	local dir="$1" head
	head="$(git -C "$SRC" rev-parse HEAD)"
	if [ -e "$dir/.git" ]; then
		git -C "$dir" checkout -q --detach "$head" || die "cannot update worktree $dir"
	else
		mkdir -p "$(dirname "$dir")"
		git -C "$SRC" worktree prune
		git -C "$SRC" worktree add -q --detach "$dir" "$head" || die "cannot create worktree $dir"
	fi
	if [ -n "$(git -C "$SRC" status --porcelain --untracked-files=no)" ]; then
		warn "$SRC has uncommitted changes; they are NOT part of the worktree $dir"
	fi
	ok "worktree $dir at $(git -C "$dir" log --oneline -1)"
}

# Detached worktree at $2 with patches/*.patch applied on top (for the
# package builds, which start from different base revisions per target).
patched_worktree(){ # dir base_rev
	local dir="$1" base="$2"
	fetch_source
	if [ -e "$dir/.git" ]; then
		git -C "$dir" am --abort 2>/dev/null || true
		git -C "$dir" checkout -q --detach "$base" || die "cannot update worktree $dir"
	else
		mkdir -p "$(dirname "$dir")"
		git -C "$SRC" worktree prune
		git -C "$SRC" worktree add -q --detach "$dir" "$base" || die "cannot create worktree $dir"
	fi
	git -C "$dir" am --3way "$PATCHES"/*.patch >/dev/null || {
		git -C "$dir" am --abort || true
		die "patches from $PATCHES do not apply on $base"
	}
	ok "worktree $dir at $(git -C "$dir" rev-parse --short HEAD) = $(git -C "$dir" log --oneline -1 "$base") + patches"
}

# Export the commits on $WORK_BRANCH above RPI_REV into patches/.
export_patches(){
	rm -f "$PATCHES"/*.patch
	git -C "$SRC" format-patch --no-signature -o "$PATCHES" "$RPI_REV..$WORK_BRANCH" >/dev/null
	ls "$PATCHES"
}

# Post-build assertion: the object code really contains the redundant
# scheduler (guards against the "renamed default scheduler" mistake).
# $1: build dir (in-tree: the source dir).
# No `| grep -q` here: callers run with pipefail and grep -q's early exit
# would make the producer die of SIGPIPE and the pipeline "fail".
assert_redundant_scheduler_built(){
	local o="$1" nm=${NM:-nm} syms
	[ -f "$o/net/mptcp/sched.o" ] || die "$o/net/mptcp/sched.o missing: CONFIG_MPTCP off?"
	syms="$($nm "$o/net/mptcp/sched.o")"
	[ "$(printf '%s\n' "$syms" | grep -c 'mptcp_sched_redundant_get_subflow')" -gt 0 ] ||
		die "mptcp_sched_redundant_get_subflow not in sched.o: the redundant scheduler is not built in"
	syms="$($nm "$o/net/mptcp/protocol.o")"
	[ "$(printf '%s\n' "$syms" | grep -c -E '__subflow_push_redundant|mptcp_subflow_push')" -gt 0 ] ||
		die "redundant push path not in protocol.o"
	if [ -f "$o/vmlinux" ]; then
		[ "$(strings "$o/vmlinux" | grep -c -w 'redundant')" -gt 0 ] ||
			die "string 'redundant' not found in vmlinux"
	fi
	ok "sched.o has mptcp_sched_redundant_get_subflow, protocol.o has the redundant push path, vmlinux has the name"
}
