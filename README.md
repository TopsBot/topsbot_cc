# topsbot_cc

[English](README.md) | [简体中文](README.zh-CN.md)

A **ROS 2 Humble cross-compilation SDK** for **MES20** (RISC-V64, Ubuntu 22.04): build board-ready ROS 2 packages on an x86_64 Linux host inside Docker, without a full native build on the device.

---

## Overview

This repository provides scripts, a RISC-V toolchain CMake file, and a Docker-based workflow for cross-compiling ROS 2 packages. It does **not** ship the sysroot or application source—the sysroot is downloaded and extracted on first use, and sources go under `topsbot_ws/src/` or are imported via `ros2_release.repos`.

### What's in the repo

| Path | Description |
|------|-------------|
| `topsbot_ws/tools/` | Build scripts, RISC-V toolchain CMake, Docker launcher |
| `topsbot_ws/ros2_release.repos` | Import open-source TopsBot packages from GitHub |
| `topsbot_sysroot/` | Extracted board root filesystem |
| `topsbot_sysroot.tar.gz` | Sysroot archive (downloaded by script) |

### Requirements

- Linux host (recommended: **x86_64**)
- **Docker** (cross-compilation container)
- **wget** or **curl** (sysroot download)

### Quick start

```bash
git clone https://github.com/TopsBot/topsbot_cc.git
cd topsbot_cc

# Download and extract sysroot (also done automatically when starting Docker)
bash topsbot_ws/tools/download_sysroot.sh

# Import ROS 2 sources from GitHub
cd topsbot_ws
vcs import src < ros2_release.repos

# Start the cross-build container (mounts repo and sysroot)
sudo topsbot_ws/tools/start_topsbot_cross_build_docker.sh

# Build packages inside the container (example)
topsbot_ws/tools/build.sh -s 'topsbot_msgs'
```

Create `topsbot_ws/src/` yourself or populate it with `vcs import` before running `build.sh`.

### Common commands

**Sysroot** (`download_sysroot.sh`):

```bash
bash topsbot_ws/tools/download_sysroot.sh              # download if missing, extract if needed
bash topsbot_ws/tools/download_sysroot.sh --force      # force re-download and extract
bash topsbot_ws/tools/download_sysroot.sh --extract-only   # extract local tgz only
```

**Docker** (`start_topsbot_cross_build_docker.sh`):

```bash
sudo topsbot_ws/tools/start_topsbot_cross_build_docker.sh            # start container
sudo topsbot_ws/tools/start_topsbot_cross_build_docker.sh --update    # force re-pull image
sudo topsbot_ws/tools/start_topsbot_cross_build_docker.sh --update-sysroot  # force refresh sysroot
```

**Cross-compile** (`build.sh`, inside the container):

```bash
topsbot_ws/tools/build.sh -s '<package_name>'                        # build one package
topsbot_ws/tools/build.sh -s 'pkg_a pkg_b'                           # build multiple packages
topsbot_ws/tools/build.sh -r '--packages-up-to my_pkg'               # pass raw colcon options
topsbot_ws/tools/build.sh -s 'my_pkg' -c '-DCMAKE_BUILD_TYPE=Debug'  # extra CMake args
```

Build artifacts land in `topsbot_ws/install/`; deploy to the MES20 board as needed (e.g. `scp`).

**Install extra dependencies into sysroot** (optional, inside the container):

```bash
topsbot_ws/tools/sysroot_apt.sh update
topsbot_ws/tools/sysroot_apt.sh install ros-humble-<package>
```

### Layout

```
topsbot_cc/
├── topsbot_sysroot.tar.gz
├── topsbot_sysroot/
└── topsbot_ws/
    ├── src/                  # user-created / vcs import
    ├── build/ install/ log/
    ├── ros2_release.repos
    └── tools/
        ├── build.sh
        ├── download_sysroot.sh
        ├── riscv64_toolchainfile.cmake
        ├── start_topsbot_cross_build_docker.sh
        └── sysroot_apt.sh
```

### License

Apache-2.0 — see [LICENSE](LICENSE). Release notes: [CHANGELOG](CHANGELOG.md).
