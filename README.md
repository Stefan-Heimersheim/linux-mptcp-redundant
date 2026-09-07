# linux-mptcp-redundant

Linux kernel packages with a **redundant MPTCP packet scheduler** for
[subspace-relay](https://github.com/Stefan-Heimersheim/subspace-relay): a
Raspberry Pi with several LTE modems carries all client traffic to a VPS over
one MPTCP connection, and with `net.mptcp.scheduler=redundant` **every byte is
transmitted on every link**, so a stall or loss burst on one link is invisible
to the clients. Because redundancy is a property of the *sender*, the same
kernel is built for the Pi (arm64, uploads) and for the VPS (x86_64,
downloads).

## What is in here

| path | purpose |
|---|---|
| `patches/000[1-4]-*.patch` | the kernel change, a 4-patch series on top of `raspberrypi/linux` `rpi-6.12.y` at the pinned revision in `build-lib.sh` (`RPI_REV`, Linux 6.12.107) |
| `build-kernel.sh` | checks out `RPI_REV`, applies `patches/` with `git am`, builds arm64 (Pi, `bcm2711_defconfig`) and x86_64 (VPS) `.deb` packages, optionally uploads a GitHub release |
| `build-lib.sh` | shared helpers: pinned revision, patch application, post-build assertion that the redundant scheduler is really in the object code |
| `config-6.12.100+deb13-cloud-amd64` | `/boot/config-*` of the VPS's Debian cloud kernel, the base for the x86_64 build (`olddefconfig` on top) |
| `test/check.sh` | build the x86_64 test kernel, boot it with virtme-ng, run the netns test and the upstream selftests; exit 0 iff all pass |
| `test/mptcp-redundant.sh` | the two-path netns test (positive test, negative control, loss, link cut, single subflow, reverse direction, asymmetric MTU); plain `ip netns`, also runs on real hosts |
| `test/run-selftests.sh`, `test/join-with-sched.sh` | upstream `mptcp_connect.sh` / `mptcp_join.sh` as regression gate, plus `mptcp_join.sh` with the redundant scheduler forced into every namespace |
| `test/x86-test.config`, `test/x86-debug.config` | Kconfig fragments for the VM test kernel and its KASAN/lockdep variant |

## The kernel change in one paragraph

Stock MPTCP schedulers pick one subflow per scheduling round. The scheduler
API allows marking several, but the push path (`__subflow_push_pending()`)
sends from one connection-level cursor, so marking two subflows *distributes*
the data between them instead of duplicating it; only the retransmit path
genuinely repeats a range on every marked subflow. The series adds (1) a
`redundant` scheduler that marks every usable subflow, (2) a per-subflow
"catch-up" step in front of the normal push: each subflow remembers up to
which sequence number it has carried data and, before it gets new data,
re-sends everything the other subflows sent in the meantime, using the same
`mptcp_sendmsg_frag()` machinery as retransmissions (correct DSS mappings, so
the receiver simply discards the duplicate and counts it in
`MPTcpExtDuplicateData`), (3) skips the "re-inject the whole unacked window
when a subflow goes stale" logic for redundant connections, since the other
subflows already carry that data, and (4) fixes a receive-side memory
accounting inconsistency in 6.12 (`__mptcp_move_skb()` partial-overlap path)
that duplicates with shifted segment boundaries trigger. Redundancy is best
effort: a subflow without send buffer space skips a round and catches up on
whatever is still unacknowledged when it has room again. Nothing changes for
the `default` scheduler or for BPF schedulers. See the commit messages in
`patches/` for the details and limitations.

## Verified (VM on the build machine)

`test/check.sh` boots the patched x86_64 kernel under virtme-ng/KVM and runs
`test/mptcp-redundant.sh`: two network namespaces, two veth paths with
`netem delay 10ms rate 100mbit` (20 ms RTT, LTE-like), one MPTCP connection
with two subflows, 8 MiB payload. Measured on the patched kernel:

```
case sched     dir     res  wall_ms xfer_ms  tx_path0  tx_path1  dupseg joins   stall retrans note
1    redundant cli>srv PASS    2056     722     8.57M     8.53M    5982     1     124       0
2    default   cli>srv PASS    1714     395     4.27M     4.26M       0     1     132       0 control
3    redundant cli>srv PASS    2820    1482     8.53M     0.09M      34     1     125      23 loss30%
4    redundant cli>srv PASS    2036     701     8.53M     4.00M    2963     1      81       0 cut@44%
5    redundant cli>srv PASS    2030     743     8.51M     0.00M       0     0     102       0 1 subflow
6    redundant srv>cli PASS    2521    1320     8.55M     8.59M    6155     1     115       0
7    redundant cli>srv PASS    2083     665     8.53M     8.58M    6340     1     128       0 mtu1400
```

`tx_path0/1` are the sender's bytes on each veth, `dupseg` the duplicate
segments the receiver discarded. With `redundant` both paths carry the whole
payload (24 further repetitions of cases 1 and 6: 106–108 % on every path);
the `default` control splits it 53 %/53 % with zero duplicates. The same
script on the unpatched kernel fails every redundant case. The guest kernel
console is part of the log and `check.sh` fails on any warning or oops; the
final series produced none in 30 transfers on the normal kernel and in
repeated full runs on a KASAN + lockdep kernel.

Known limitations: redundancy is best effort under memory pressure (a
subflow without send buffer space skips a round and catches up on whatever
is still unacknowledged when it has room again, so a link slower than the
stream carries the oldest unacknowledged data rather than everything); on a
memory-speed link without RTT the second copy is often acknowledged before
it can be sent, which is why the test gives the paths a 20 ms RTT; a
subflow that is far behind when the peer closes does not reach 100 %. The
default and BPF schedulers are unaffected by the series.

Upstream regression gate on the same kernel: `mptcp_connect.sh` (68/68) and
the complete `mptcp_join.sh` (126/126) pass with the default scheduler; with
`redundant` forced into every namespace all join/error/signal/fastclose/
syncookie/checksum groups pass too, and only the link-failure group's
per-link-usage and stale-count expectations differ (it assumes a backup
link carries nothing; the redundant scheduler uses it by design).

## Build

A plain `./build-kernel.sh` is the whole release build: it builds both
architectures and stages the upload set in `out/release/`. `--stage` only
re-assembles that directory from existing packages, and the upload
(`--release`, or `--release-only` for already built packages) is a separate
step that needs `GH_TOKEN`.

```bash
./build-kernel.sh                  # arm64 + x86_64 .debs into out/kernels/, upload set staged in out/release/
./build-kernel.sh --target arm64   # Pi only
./build-kernel.sh --target x86_64  # VPS only
./build-kernel.sh --stage          # (re)assemble out/release/: image+headers x2, SHA256SUMS, RELEASE-NOTES.md
GH_TOKEN=... ./build-kernel.sh --release-only                       # upload the staged set to the GitHub release
```

The release is named after the full Debian package version (`v6.12.107-1`).
For a rebuild on the same kernel base (config or patch change) bump the
revision with `PKG_REVISION=2 ./build-kernel.sh`: packages become
`…_6.12.107-2_*.deb` and the release `v6.12.107-2`, so a release name is never
reused and the installers see a new package version. The notes state
the pinned source revision and the sha256 of the patch series, and the
uploaded set is the two `linux-image-*` and two `linux-headers-*` packages
(the arm64 `-dbg` package and `linux-libc-dev` are not uploaded).

`build-kernel.sh` installs the Debian/Ubuntu build dependencies with `sudo
apt-get` and, for arm64, adds a temporary ports.ubuntu.com source to install
`libssl-dev:arm64` (the `dpkg --add-architecture arm64` and that package stay
installed). The source checkout `linux-rpi/` is pinned to `RPI_REV`; the
patches are applied with `git am` and a patch that does not apply aborts the
build. Packages are named `linux-image-6.12.107-v8-mptcp-redundant_*_arm64.deb`
(Pi) and `linux-image-6.12.107-mptcp-redundant_*_amd64.deb` (VPS), each with
its `linux-headers-*` package; the arm64 build also leaves a large
`linux-image-*-dbg` package (BTF debug info) in `out/kernels/`, which
`--release` does not upload.

## Test

```bash
test/check.sh                    # build test kernel, run everything (needs vng, qemu, /dev/kvm)
test/check.sh --from-patches     # reproducible: reset linux-rpi to RPI_REV + patches/ first
test/check.sh --debug            # KASAN + lockdep kernel in build-x86-debug/
SKIP_SELFTESTS=1 test/check.sh   # only the netns test (~2 min)
CASES="1 2" test/check.sh --no-build
```

On a real host (VPS or Pi) with the patched kernel and `mptcp_connect` built
from `linux-rpi/tools/testing/selftests/net/mptcp/`:

```bash
sudo MPTCP_CONNECT=/path/to/mptcp_connect PATH_DELAY_MS=0 PATH_RATE=0 test/mptcp-redundant.sh
```

## Using it

The primary use case is
[subspace-relay](https://github.com/Stefan-Heimersheim/subspace-relay), whose
installers download these packages and configure the Pi and the VPS; the
manual steps are:

```bash
sysctl -w net.mptcp.enabled=1
sysctl -w net.mptcp.scheduler=redundant     # per network namespace, before the socket is created
ip mptcp limits set subflows 4 add_addr_accepted 4
ip mptcp endpoint add <modem address> dev <modem interface> subflow
```

`cat /proc/sys/net/mptcp/available_schedulers` must list `redundant`; the
old kernel only *named* a scheduler `redundant` while using the default
selection logic.
