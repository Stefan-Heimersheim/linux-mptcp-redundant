#!/usr/bin/env bash
# build-kernel.sh — build the linux-mptcp-redundant kernel packages.
#
#   ./build-kernel.sh                 build arm64 (Raspberry Pi) and x86_64 (VPS) .debs
#   ./build-kernel.sh --target arm64  only the Pi kernel
#   ./build-kernel.sh --target x86_64 only the VPS kernel
#   ./build-kernel.sh --source-only   just check out RPI_REV + apply patches/ (no build)
#   ./build-kernel.sh --release       build, then upload to the GitHub release
#   ./build-kernel.sh --release-only  only upload what is in out/kernels/
#   ./build-kernel.sh --stage         copy the upload set to out/release/ with
#                                     SHA256SUMS and RELEASE-NOTES.md (no upload)
#
# The source is raspberrypi/linux at the pinned RPI_REV (see build-lib.sh)
# plus the series in patches/, applied with `git am` onto branch
# mptcp-redundant. A patch that does not apply aborts the build.
#
# Optional env:
#   KDEB_PKGVERSION=6.12.107-1    Debian package version (default: kernelversion-1)
#   RELEASE_REPO=https://github.com/Stefan-Heimersheim/linux-mptcp-redundant
#   GH_TOKEN=...                  for --release
#   JOBS=N                        make -j (default nproc)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$ROOT/linux-rpi"
OUT="$ROOT/out/kernels"
# shellcheck source=build-lib.sh
. "$ROOT/build-lib.sh"

RELEASE_REPO="${RELEASE_REPO:-${GH_REPO:-https://github.com/Stefan-Heimersheim/linux-mptcp-redundant}}"
CROSS="${CROSS_COMPILE:-aarch64-linux-gnu-}"
JOBS="${JOBS:-$(nproc)}"
LOCALVERSION="-mptcp-redundant"

# Identity embedded in the artifacts instead of the build machine's user@host:
# the .deb Maintainer field (mkdebian reads DEBFULLNAME/DEBEMAIL) and the
# "Linux version ... (user@host)" banner in /proc/version.
export DEBFULLNAME="${DEBFULLNAME:-Stefan Heimersheim}"
export DEBEMAIL="${DEBEMAIL:-stefan.heimersheim@gmail.com}"
export KBUILD_BUILD_USER="${KBUILD_BUILD_USER:-stefan.heimersheim}"
export KBUILD_BUILD_HOST="${KBUILD_BUILD_HOST:-gmail.com}"

TARGETS="arm64 x86_64"
RELEASE=false
RELEASE_ONLY=false
SOURCE_ONLY=false
STAGE_ONLY=false
APT_CHANGED=false
ARM_SRC=/etc/apt/sources.list.d/mptcp-arm64-ports.sources
ARM_PREF=/etc/apt/preferences.d/mptcp-arm64-ports
ARM_SRC_CREATED=false
ARM_PREF_CREATED=false

root(){ [ "$EUID" -eq 0 ] && "$@" || sudo "$@"; }

cleanup_apt(){
    local changed=false
    if $ARM_SRC_CREATED; then root rm -f "$ARM_SRC"; changed=true; fi
    if $ARM_PREF_CREATED; then root rm -f "$ARM_PREF"; changed=true; fi
    if $changed && $APT_CHANGED; then apt_update; fi
}

# With a foreign architecture enabled, apt-get update returns 100 when the
# distribution's main sources have no indices for it (404 for
# binary-arm64 on archive.ubuntu.com); the arm64 indices come from the
# ports source added below and are fetched fine, so that status is not fatal.
apt_update(){
    root apt-get update || warn "apt-get update reported errors (missing foreign-arch indices in the main sources are harmless)"
}
trap cleanup_apt EXIT

while [ "$#" -gt 0 ]; do
    case "$1" in
        --release) RELEASE=true; shift ;;
        --release-only) RELEASE_ONLY=true; shift ;;
        --source-only) SOURCE_ONLY=true; shift ;;
        --stage) STAGE_ONLY=true; shift ;;
        --target) TARGETS="$2"; shift 2 ;;
        -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
        *) die "Unknown argument: $1" ;;
    esac
done
for t in $TARGETS; do
    case "$t" in arm64|x86_64) ;; *) die "unknown target $t (arm64|x86_64)" ;; esac
done

# ---------------------------------------------------------------- deps

os_id(){ . /etc/os-release; printf '%s' "${ID:-}"; }
os_id_like(){ . /etc/os-release; printf '%s' "${ID_LIKE:-}"; }
os_ubuntu_codename(){ . /etc/os-release; printf '%s' "${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"; }
os_family(){
    local id word
    id="$(os_id)"
    case "$id" in ubuntu|debian) printf '%s\n' "$id"; return 0 ;; esac
    for word in $(os_id_like); do
        case "$word" in ubuntu|debian) printf '%s\n' "$word"; return 0 ;; esac
    done
    printf 'unsupported\n'
}

apt_install(){
    command -v apt-get >/dev/null || die "Automatic package install needs apt-get"
    apt_update
    APT_CHANGED=true
    root env DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
}

package_installed(){
    [ "$(dpkg-query -W -f='${db:Status-Abbrev}\n' "$1" 2>/dev/null | grep -c '^ii ')" -gt 0 ]
}

bootstrap_deps(){
    local pkgs=(git build-essential bc bison flex libssl-dev libelf-dev dwarves debhelper rsync kmod cpio)
    case " $TARGETS " in *" arm64 "*) pkgs+=(gcc-aarch64-linux-gnu) ;; esac
    local missing=()
    for p in "${pkgs[@]}"; do package_installed "$p" || missing+=("$p"); done
    [ "${#missing[@]}" -eq 0 ] || apt_install "${missing[@]}"
}

apt_arm64_helper(){
    command -v apt-get >/dev/null || return 0
    dpkg -s libssl-dev:arm64 >/dev/null 2>&1 && return 0
    [ "$(dpkg --print-foreign-architectures | grep -c -x arm64)" -gt 0 ] || root dpkg --add-architecture arm64

    case "$(os_family)" in
    ubuntu)
        local codename
        codename="$(os_ubuntu_codename)"; [ -n "$codename" ] || die "Cannot detect Ubuntu codename"
        if [ ! -e "$ARM_SRC" ]; then
            ARM_SRC_CREATED=true
            root tee "$ARM_SRC" >/dev/null <<EOT
Types: deb
URIs: http://ports.ubuntu.com/ubuntu-ports/
Suites: $codename $codename-updates $codename-backports $codename-security
Components: main universe restricted multiverse
Architectures: arm64
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOT
        fi
        if [ ! -e "$ARM_PREF" ]; then
            ARM_PREF_CREATED=true
            root tee "$ARM_PREF" >/dev/null <<'EOT'
Package: *
Pin: origin "ports.ubuntu.com"
Pin-Priority: 100
EOT
        fi
        ;;
    debian) : ;;
    *) die "Automatic apt setup supports Debian and Ubuntu-like distributions only" ;;
    esac

    apt_update
    APT_CHANGED=true
    root apt-get install -y libssl-dev:arm64
}

deps(){
    case "$(os_family)" in
        debian|ubuntu) bootstrap_deps ;;
        *) die "Automatic package install supports Debian and Ubuntu-like distributions only" ;;
    esac
    command -v git >/dev/null || die "git missing"
    command -v make >/dev/null || die "make missing"
    case " $TARGETS " in
    *" arm64 "*)
        command -v "${CROSS}gcc" >/dev/null || die "cross compiler missing: install gcc-aarch64-linux-gnu"
        apt_arm64_helper
        ;;
    esac
    for p in bc bison flex libssl-dev libelf-dev dwarves debhelper rsync; do
        package_installed "$p" || die "$p missing"
    done
}

# ---------------------------------------------------------------- config

# $b is the per-target worktree (in-tree build, see ensure_worktree in build-lib.sh)
# Package names: bcm2711_defconfig sets CONFIG_LOCALVERSION="-v8", which is
# kept (subspace-relay's pi-install.sh expects 6.12.x-v8-mptcp-redundant);
# LOCALVERSION_AUTO is switched off so no git hash (which changes every time
# the patches are re-applied) ends up in the version string.
config_common(){ # builddir
    local b="$1"
    "$b/scripts/config" --file "$b/.config" --enable MPTCP --enable MPTCP_IPV6 \
        --enable INET_MPTCP_DIAG --enable NET_SCH_NETEM \
        --set-str SYSTEM_TRUSTED_KEYS "" --set-str SYSTEM_REVOCATION_KEYS "" \
        --disable DEBUG_INFO_BTF_MODULES --disable LOCALVERSION_AUTO
}

config_arm64(){
    local b="$1"
    make -C "$b" ARCH=arm64 CROSS_COMPILE="$CROSS" bcm2711_defconfig
    config_common "$b"
    grep -q 'CONFIG_DEBUG_INFO_NONE=y' "$b/.config" &&
        "$b/scripts/config" --file "$b/.config" --disable DEBUG_INFO_NONE --enable DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT
    "$b/scripts/config" --file "$b/.config" --enable DEBUG_INFO_BTF
    make -C "$b" ARCH=arm64 CROSS_COMPILE="$CROSS" olddefconfig
}

config_x86_64(){
    local b="$1"
    make -C "$b" ARCH=x86_64 x86_64_defconfig
    "$b/scripts/kconfig/merge_config.sh" -m -O "$b" "$b/.config" "$ROOT/build-x86_64.config" >/dev/null
    # The rpi tree does not link DRM without CONFIG_OF (a downstream backlight
    # patch declares backlight_set_display_name() unconditionally but defines
    # it under CONFIG_OF); a VPS has no GPU and keeps the VGA text console.
    "$b/scripts/config" --file "$b/.config" --disable DRM
    config_common "$b"
    make -C "$b" ARCH=x86_64 olddefconfig
    for opt in MPTCP MPTCP_IPV6 VIRTIO_NET VIRTIO_BLK EXT4_FS NF_NAT IP_NF_IPTABLES NFT_COMPAT; do
        grep -q "^CONFIG_$opt=[ym]" "$b/.config" || die "x86_64 config: CONFIG_$opt not set"
    done
}

# ---------------------------------------------------------------- build

pkgversion(){ # builddir make-args...
    local b="$1"; shift
    if [ -n "${KDEB_PKGVERSION:-}" ]; then printf '%s\n' "$KDEB_PKGVERSION"
    else printf '%s-1\n' "$(make -s -C "$b" "$@" kernelversion)"; fi
}

build_target(){ # arch
    local arch="$1" b="$ROOT/build-$1/linux" pkgver
    local -a margs
    case "$arch" in
        arm64) margs=(ARCH=arm64 CROSS_COMPILE="$CROSS") ;;
        x86_64) margs=(ARCH=x86_64) ;;
    esac
    info "Building $arch kernel in worktree $b"
    ensure_worktree "$b"
    mkdir -p "$OUT"
    make -s -C "$b" mrproper
    "config_$arch" "$b"
    pkgver="$(pkgversion "$b" "${margs[@]}")"
    info "$arch: KDEB_PKGVERSION=$pkgver LOCALVERSION=$LOCALVERSION (log: $OUT/build-$arch.log)"
    if ! make -C "$b" "${margs[@]}" -j"$JOBS" bindeb-pkg \
        LOCALVERSION="$LOCALVERSION" KDEB_PKGVERSION="$pkgver" > "$OUT/build-$arch.log" 2>&1; then
        tail -30 "$OUT/build-$arch.log"; die "$arch build failed (see $OUT/build-$arch.log)"
    fi
    if grep -E 'net/mptcp/.*warning' "$OUT/build-$arch.log"; then
        die "compiler warnings in net/mptcp/ ($arch)"
    fi
    NM="$([ "$arch" = arm64 ] && echo "${CROSS}nm" || echo nm)" assert_redundant_scheduler_built "$b"
    local deb_arch; deb_arch="$([ "$arch" = arm64 ] && echo arm64 || echo amd64)"
    # bindeb-pkg drops the packages next to the source tree, i.e. in build-$arch/.
    # Keep image + headers (+ dbg for arm64, BTF debug info); linux-libc-dev
    # is not part of the release.
    rm -f "$OUT"/*"_${deb_arch}.deb" "$OUT"/*"_${deb_arch}.buildinfo" "$OUT"/*"_${deb_arch}.changes"
    find "$(dirname "$b")" -maxdepth 1 \( -name "*mptcp-redundant*_${deb_arch}.deb" -o -name "*_${deb_arch}.buildinfo" -o -name "*_${deb_arch}.changes" \) -exec mv -t "$OUT" {} +
    find "$(dirname "$b")" -maxdepth 1 -name "linux-libc-dev_*_${deb_arch}.deb" -delete
    ok "$arch packages:"; ls -1 "$OUT"/*"_${deb_arch}.deb"
}

# ---------------------------------------------------------------- release

infer_release_name(){
    local file base version
    file="$(find "$OUT" -type f -name 'linux-image-*.deb' ! -name '*-dbg_*' | sort | head -n1)"
    [ -n "$file" ] || die "No linux-image .deb found in $OUT"
    base="$(basename "$file")"
    version="${base#linux-image-}"
    version="${version%%_*}"
    if [[ "$version" =~ ^([0-9]+[.][0-9]+[.][0-9]+) ]]; then
        printf 'v%s\n' "${BASH_REMATCH[1]}"
    else
        die "Could not infer release name from $base"
    fi
}

github_repo_arg(){
    local repo="${1%.git}"
    repo="${repo#https://github.com/}"
    repo="${repo#git@github.com:}"
    printf '%s\n' "$repo"
}

release_files(){ # the upload set: image + headers per architecture, no -dbg, no libc-dev
    find "$OUT" -type f -name 'linux-*mptcp-redundant*.deb' ! -name '*-dbg_*' | sort
}

release_notes(){
    local series kver
    series="$(cat "$PATCHES"/*.patch | sha256sum | cut -c1-16)"
    kver="$(make -s -C "$SRC" kernelversion 2>/dev/null || true)"
    cat <<EOT
MPTCP redundant-scheduler kernel packages for the Raspberry Pi (arm64, \`bcm2711_defconfig\`, \`kernel8.img\`) and the VPS (amd64).

- Source: $RPI_REPO branch \`$RPI_BRANCH\` at \`$RPI_REV\` (Linux $kver)
- Patch series: $(find "$PATCHES" -name '*.patch' | wc -l) patches in \`patches/\`, sha256 of the concatenated series: \`$series\`
- \`sysctl -w net.mptcp.scheduler=redundant\` makes the sender transmit every byte on every subflow; both ends need this kernel for both directions. See README.md for what was verified (netns tests incl. negative control, KASAN/lockdep, upstream mptcp selftests) and what was not (real links).
- The amd64 kernel is built from \`x86_64_defconfig\` + \`build-x86_64.config\` (generic KVM/Xen/Hyper-V guest, storage and netfilter drivers built in).

Asset names carry the Debian architecture (\`_arm64.deb\` / \`_amd64.deb\`) so both coexist in one release.

SHA256:
\`\`\`
$(release_files | xargs -r sha256sum 2>/dev/null | sed 's#  .*/#  #')
\`\`\`
EOT
}

# Copy the upload set to out/release/ with checksums and notes; nothing is uploaded.
stage_release(){
    local dir="$ROOT/out/release" f
    mapfile -t files < <(release_files)
    [ "${#files[@]}" -gt 0 ] || die "No packages in $OUT; run ./build-kernel.sh first"
    rm -rf "$dir"; mkdir -p "$dir"
    for f in "${files[@]}"; do cp "$f" "$dir/"; done
    (cd "$dir" && sha256sum ./*.deb > SHA256SUMS)
    release_notes > "$dir/RELEASE-NOTES.md"
    # values subspace-relay pins (pi-install.sh defaults and config.sh hashes)
    local img hdr kver
    img="$(find "$dir" -name 'linux-image-*_arm64.deb' | head -n1)"
    hdr="$(find "$dir" -name 'linux-headers-*_arm64.deb' | head -n1)"
    kver="$(basename "$img")"; kver="${kver#linux-image-}"; kver="${kver%%_*}"
    if [ -n "$img" ] && [ -n "$hdr" ]; then
        cat > "$dir/subspace-relay-pins.txt" <<EOT
# pi-install.sh
KERNEL_RELEASE="$(infer_release_name)"
KERNEL_VERSION="$kver"
KERNEL_PKG_VERSION="$(basename "$img" | sed -E 's/^[^_]+_([^_]+)_.*/\1/')"
# config.sh
KERNEL_IMAGE_DEB_SHA256="$(sha256sum "$img" | cut -d' ' -f1)"
KERNEL_HEADERS_DEB_SHA256="$(sha256sum "$hdr" | cut -d' ' -f1)"
EOT
    fi
    info "Staged $(infer_release_name) in $dir"; ls -la "$dir"
    printf '\nUpload with:\n  GH_TOKEN=... ./build-kernel.sh --release-only\nor\n  gh release create %s %s/*.deb --title %s --notes-file %s/RELEASE-NOTES.md --repo %s\n' \
        "$(infer_release_name)" "$dir" "$(infer_release_name)" "$dir" "$(github_repo_arg "$RELEASE_REPO")"
}

release_artifacts(){
    local name repo_arg
    local files=()
    command -v gh >/dev/null || die "gh missing: install GitHub CLI"
    [ -n "${GH_TOKEN:-}" ] || die "GH_TOKEN must be set for GitHub release uploads"
    [ -d "$OUT" ] || die "No output dir: $OUT"
    # image + headers for both architectures; the -dbg package (hundreds of MB) stays local
    mapfile -t files < <(release_files)
    [ "${#files[@]}" -gt 0 ] || die "No .deb artifacts found in $OUT"
    name="$(infer_release_name)"
    repo_arg="$(github_repo_arg "$RELEASE_REPO")"
    info "Releasing $name to $repo_arg: ${files[*]##*/}"
    if gh release view "$name" --repo "$repo_arg" >/dev/null 2>&1; then
        gh release upload "$name" "${files[@]}" --clobber --repo "$repo_arg"
    else
        gh release create "$name" "${files[@]}" --title "$name" --notes "$(release_notes)" --repo "$repo_arg"
    fi
}

# ---------------------------------------------------------------- main

if $RELEASE_ONLY; then
    release_artifacts
    exit 0
fi
if $STAGE_ONLY; then
    stage_release
    exit 0
fi
if $SOURCE_ONLY; then
    source_tree_from_patches
    exit 0
fi
deps
source_tree_from_patches
for t in $TARGETS; do
    build_target "$t"
done

info "Outputs"
find "$OUT" -type f -name '*.deb' -print | sort
stage_release
$RELEASE && release_artifacts
exit 0
