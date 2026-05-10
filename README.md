# linux-mptcp-redundant
Linux kernel builds with a redundant MPTCP scheduler.

## Build instructions
To download the sources, build the kernel, and create the deb package, run
```bash
./build-kernel.sh
```

To upload the deb files as a GitHub release run
```bash
GH_TOKEN=... ./build-kernel.sh --release-only
```
## Notes
The build will add temporary sources such as
```
/etc/apt/sources.list.d/mptcp-arm64-ports.sources
/etc/apt/preferences.d/mptcp-arm64-ports
```
that are deleted on exit. However, the changes below are persistent:
```
sudo dpkg --add-architecture arm64
sudo apt-get install -y libssl-dev:arm64
```
