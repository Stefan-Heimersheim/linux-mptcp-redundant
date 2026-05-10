#!/usr/bin/env bash
# Build and optionally release one Raspberry Pi arm64 kernel .deb for Pi 3 + Pi 4.
# Usage: ./build-kernel.sh [--release]
#        ./build-kernel.sh --release-only
#
# Optional env:
#   KDEB_PKGVERSION=6.12.87-1
#   RELEASE_REPO=https://github.com/Stefan-Heimersheim/linux-mptcp-redundant
#   GH_TOKEN=...

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$ROOT/linux-rpi"
OUT="$ROOT/out/rpi-kernels"
BRANCH="${RPI_BRANCH:-rpi-6.12.y}"
REPO="${RPI_REPO:-https://github.com/raspberrypi/linux}"
RELEASE_REPO="${RELEASE_REPO:-${GH_REPO:-https://github.com/Stefan-Heimersheim/linux-mptcp-redundant}}"
CROSS="${CROSS_COMPILE:-aarch64-linux-gnu-}"
JOBS="${JOBS:-$(nproc)}"

RELEASE=false
RELEASE_ONLY=false
APT_CHANGED=false
ARM_SRC=/etc/apt/sources.list.d/mptcp-arm64-ports.sources
ARM_PREF=/etc/apt/preferences.d/mptcp-arm64-ports
ARM_SRC_CREATED=false
ARM_PREF_CREATED=false

info(){ printf '\n\033[1;34m>>> %s\033[0m\n' "$*"; }
ok(){ printf '\033[1;32mOK %s\033[0m\n' "$*"; }
die(){ printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
root(){ [ "$EUID" -eq 0 ] && "$@" || sudo "$@"; }

cleanup_apt(){
    local changed=false
    if $ARM_SRC_CREATED; then
        root rm -f "$ARM_SRC"
        changed=true
    fi
    if $ARM_PREF_CREATED; then
        root rm -f "$ARM_PREF"
        changed=true
    fi
    if $changed && $APT_CHANGED; then
        root apt-get update
    fi
}
trap cleanup_apt EXIT

while [ "$#" -gt 0 ]; do
    case "$1" in
        --release)
            RELEASE=true
            shift
            ;;
        --release-only)
            RELEASE_ONLY=true
            shift
            ;;
        *) die "Unknown argument: $1" ;;
    esac
done

os_id(){ . /etc/os-release; printf '%s' "${ID:-}"; }
os_id_like(){ . /etc/os-release; printf '%s' "${ID_LIKE:-}"; }
os_ubuntu_codename(){ . /etc/os-release; printf '%s' "${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"; }
os_family(){
    local id word
    id="$(os_id)"
    case "$id" in
        ubuntu|debian) printf '%s\n' "$id"; return 0 ;;
    esac
    for word in $(os_id_like); do
        case "$word" in
            ubuntu|debian) printf '%s\n' "$word"; return 0 ;;
        esac
    done
    printf 'unsupported\n'
}

apt_install(){
    command -v apt-get >/dev/null || die "Automatic package install needs apt-get"
    root apt-get update
    APT_CHANGED=true
    root env DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
}

package_installed(){
    dpkg-query -W -f='${db:Status-Abbrev}\n' "$1" 2>/dev/null | grep -q '^ii '
}

bootstrap_deps(){
    local pkgs=(git python3 build-essential gcc-aarch64-linux-gnu bc bison flex libssl-dev libelf-dev dwarves debhelper rsync)
    apt_install "${pkgs[@]}"
}

apt_arm64_helper(){
    command -v apt-get >/dev/null || return 0
    dpkg --print-foreign-architectures | grep -qx arm64 || root dpkg --add-architecture arm64

    case "$(os_family)" in
    ubuntu)
        local codename
        codename="$(os_ubuntu_codename)"; [ -n "$codename" ] || die "Cannot detect Ubuntu codename"
        if [ ! -e "$ARM_SRC" ]; then
            ARM_SRC_CREATED=true
            root tee "$ARM_SRC" >/dev/null <<EOF
Types: deb
URIs: http://ports.ubuntu.com/ubuntu-ports/
Suites: $codename $codename-updates $codename-backports $codename-security
Components: main universe restricted multiverse
Architectures: arm64
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
        fi
        if [ ! -e "$ARM_PREF" ]; then
            ARM_PREF_CREATED=true
            root tee "$ARM_PREF" >/dev/null <<'EOF'
Package: *
Pin: origin "ports.ubuntu.com"
Pin-Priority: 100
EOF
        fi
        ;;
    debian)
        :
        ;;
    *)
        die "Automatic apt setup supports Debian and Ubuntu-like distributions only"
        ;;
    esac

    root apt-get update
    APT_CHANGED=true
    dpkg -s libssl-dev:arm64 >/dev/null 2>&1 || root apt-get install -y libssl-dev:arm64
}

deps(){
    case "$(os_family)" in
        debian|ubuntu) bootstrap_deps ;;
        *)
        die "Automatic package install supports Debian and Ubuntu-like distributions only"
        ;;
    esac

    command -v git >/dev/null || die "git missing"
    command -v python3 >/dev/null || die "python3 missing"
    command -v make >/dev/null || die "make missing"
    command -v "${CROSS}gcc" >/dev/null || die "cross compiler missing: install gcc-aarch64-linux-gnu"
    apt_arm64_helper
    for p in bc bison flex libssl-dev libelf-dev dwarves debhelper rsync; do
        package_installed "$p" || die "$p missing"
    done
}

source_tree(){
    if [ -d "$SRC/.git" ]; then
        git -C "$SRC" pull --ff-only
    else
        git clone --depth=1 --branch "$BRANCH" "$REPO" "$SRC"
    fi
}

patch_mptcp(){
    python3 - "$SRC/net/mptcp/sched.c" <<'PY'
from pathlib import Path
import re, sys
p = Path(sys.argv[1])
s = p.read_text()
if 'mptcp_sched_redundant' in s:
    raise SystemExit(0)
m = re.search(r'(?ms)^static struct mptcp_sched_ops mptcp_sched_default = \{.*?^\};', s)
if not m:
    raise SystemExit("default scheduler block not found")
block = '''

static struct mptcp_sched_ops mptcp_sched_redundant = {
\t.get_subflow = mptcp_sched_default_get_subflow,
\t.name = "redundant",
\t.owner = THIS_MODULE,
};
'''
s = s[:m.end()] + block + s[m.end():]
s = s.replace('mptcp_register_scheduler(&mptcp_sched_default);',
              'mptcp_register_scheduler(&mptcp_sched_default);\n\tmptcp_register_scheduler(&mptcp_sched_redundant);')
p.write_text(s)
PY
}

config(){
    local b="$1"
    make -C "$SRC" O="$b" ARCH=arm64 CROSS_COMPILE="$CROSS" bcm2711_defconfig
    "$SRC/scripts/config" --file "$b/.config" --enable MPTCP --set-str SYSTEM_TRUSTED_KEYS "" --set-str SYSTEM_REVOCATION_KEYS ""
    grep -q 'CONFIG_DEBUG_INFO_NONE=y' "$b/.config" && "$SRC/scripts/config" --file "$b/.config" --disable DEBUG_INFO_NONE --enable DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT
    "$SRC/scripts/config" --file "$b/.config" --enable DEBUG_INFO_BTF
    make -C "$SRC" O="$b" ARCH=arm64 CROSS_COMPILE="$CROSS" olddefconfig
}

build_kernel(){
    local b="$ROOT/build-rpi"
    local pkgversion="${KDEB_PKGVERSION:-}"
    info "Building Raspberry Pi arm64 kernel"
    rm -rf "$b"
    mkdir -p "$b" "$OUT"
    rm -f "$OUT"/*.deb
    config "$b"
    if [ -z "$pkgversion" ]; then
        pkgversion="$(make -s -C "$SRC" O="$b" ARCH=arm64 CROSS_COMPILE="$CROSS" kernelversion)-1"
    fi
    info "Using KDEB_PKGVERSION=$pkgversion"
    make -C "$SRC" O="$b" ARCH=arm64 CROSS_COMPILE="$CROSS" -j"$JOBS" bindeb-pkg LOCALVERSION="-mptcp-redundant" KDEB_PKGVERSION="$pkgversion"
    find "$ROOT" -maxdepth 1 -name "*mptcp-redundant*_arm64.deb" -exec mv -t "$OUT" {} +
}

infer_release_name(){
    local file base version
    file="$(find "$OUT" -type f -name 'linux-image-*_arm64.deb' ! -name '*-dbg_*' | sort | head -n1)"
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

release_artifacts(){
    local name repo_arg
    local files=()

    command -v gh >/dev/null || die "gh missing: install GitHub CLI"
    [ -n "${GH_TOKEN:-}" ] || die "GH_TOKEN must be set for GitHub release uploads"
    [ -d "$OUT" ] || die "No output dir: $OUT"

    mapfile -t files < <(find "$OUT" -type f -name '*.deb' | sort)
    [ "${#files[@]}" -gt 0 ] || die "No .deb artifacts found in $OUT"

    name="$(infer_release_name)"
    repo_arg="$(github_repo_arg "$RELEASE_REPO")"
    info "Releasing $name to $repo_arg"

    if gh release view "$name" --repo "$repo_arg" >/dev/null 2>&1; then
        gh release upload "$name" "${files[@]}" --clobber --repo "$repo_arg"
    else
        gh release create "$name" "${files[@]}" --title "$name" --notes "Raspberry Pi arm64 MPTCP redundant kernel package." --repo "$repo_arg"
    fi
}

if $RELEASE_ONLY; then
    release_artifacts
    exit 0
fi
deps
source_tree
patch_mptcp
build_kernel

info "Outputs"
find "$OUT" -type f -name '*.deb' -print | sort

$RELEASE && release_artifacts
