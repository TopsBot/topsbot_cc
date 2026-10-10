# topsbot_cc

[English](README.md) | [简体中文](README.zh-CN.md)

A **ROS 2 Humble cross-compilation SDK** for **MES20** (RISC-V64, Ubuntu 22.04): build board-ready ROS 2 packages on an x86_64 Linux host inside a build container, without a full native build on the device.

---

## Overview

This repo is the consumer side: fetch sources, download the sysroot, and cross-compile in a build container. The sysroot is built and packaged by `topsbot_ros_base` (`topsbot_ws/tools/sysroot/sysroot/`); this repo only downloads and uses it.

## Quick start

Clone from GitHub (or internal GitLab):

```bash
git clone https://github.com/TopsBot/topsbot_cc.git
cd topsbot_cc
source topsbot_ws/tools/scripts/envsetup.sh   # activate the command environment
lunch                       # pick a product + Ubuntu variant (mes20-jammy / mes20-noble)
tb update sysroot           # download + extract the sysroot (first run)
tb update code              # fetch sources (default configs/ros2.repos)
m                           # full cross build; m -s <pkg> single; mm current package
```

Artifacts go to `topsbot_ws/install/` and are deployed to the board via `scp`.

## Commands

`topsbot_ws/tools/scripts/envsetup.sh` provides `lunch` / `m` / `mm` / `tb`; `tb` subcommands are grouped by duty:

| Command | Description |
| --- | --- |
| `lunch [target]` | Select a product + variant (no args = menu; `lunch mes20` / `lunch mes20-noble`; configs in `topsbot_ws/configs/target/<board>/<board>.json`) |
| `tb update code` | Sync sources to latest (vcs import + pull; repos with unsaved local changes are skipped with a warning) |
| `tb update sysroot` | Download/extract sysroot (`--download-only` / `--extract-only`); refreshing an existing sysroot asks once (local changes inside are dropped) |
| `tb update docker-image` | Pull/update the build container image; refreshing an existing image asks once |
| `tb update all` | All the above |
| `tb build` / `tb clean` | Build / clean (default: all; `-s <pkg>` single; `--verbose` live output) |
| `tb shell --cross` / `--sysroot` | Fast cross-build & verification shell (cross env preloaded) / enter the sysroot |
| `tb exec <cmd>` | Run any command inside the build container |
| `tb config [key[=value]]` | View/set target config (`--raw` JSON; `--merge` into baseline) |
| `tb top` | cd to the repo root |
| `m` / `mm` | Full build / current-package build (auto-detects the package dir) |

`m clean` / `mm clean` clean all / one package (including `debsrc/<distro>/` package artifacts); `tb clean --container` resets the build container (drops its state).

`tb -h` lists only the common commands by default; `tb -h --full` shows all commands.

## Dependencies

Before every build, package.xml dependencies across `src/` + `tools/packages/` are resolved automatically with **rosdep** (rules: rosdistro + `tools/scripts/rosdep/topsbot.yaml`) and the missing riscv64 debs are downloaded and unpacked into the sysroot — new packages usually need no manual sysroot work. Only build-time tags are considered (`depend` / `build_depend` / `build_export_depend` / `buildtool_depend`): the sysroot exists to cross-compile, and runtime libraries already arrive as dependencies of the `-dev` packages. Resolution is incremental (content-hash stamp, reruns only when a package.xml or the rules change) and reuses the sysroot's own apt sources, so private `tbros-*` / `taco-sdk` packages resolve too. Keys rosdep cannot resolve are printed as warnings; add them to `tools/scripts/rosdep/topsbot.yaml`, or list plain apt names in the board's `sysroot.packages` file as a manual supplement.

## Cross-compiling your own code

The build container already carries the full cross toolchain, the sysroot and the built workspace — `tb shell --cross` drops you into it with the cross environment preloaded, so you can build & verify your own code directly without first turning it into a ROS 2 package:

| Variable | Purpose |
| --- | --- |
| `CROSS_COMPILE` | compiler/kbuild prefix (`$(CROSS_COMPILE)gcc`) |
| `TOPSBOT_SYSROOT` | target rootfs (`/sysroot`) — use as `--sysroot=`, headers & libs live here |
| `TOPSBOT_TOOLCHAIN_FILE` | ready-made CMake toolchain file |
| `TOPSBOT_INSTALL` | workspace build results (`install/include`, `install/lib`) |
| `CMAKE_PREFIX_PATH` / `AMENT_PREFIX_PATH` | `find_package` search path (workspace install + ROS underlay) |
| `PKG_CONFIG_PATH` / `PKG_CONFIG_SYSROOT_DIR` | cross `pkg-config`, works out of the box |

CMake projects need nothing else — the toolchain file routes compilers, sysroot, `find_package` and even the qemu emulator for `try_run`:

```bash
tb shell --cross
cmake -B build -DCMAKE_TOOLCHAIN_FILE=$TOPSBOT_TOOLCHAIN_FILE
cmake --build build && file build/your_app    # → ELF ... riscv64
```

Plain Makefile projects map onto the same variables:

```make
CC       := $(CROSS_COMPILE)gcc
CXX      := $(CROSS_COMPILE)g++
CFLAGS   += --sysroot=$(TOPSBOT_SYSROOT) -I$(TOPSBOT_INSTALL)/include
CXXFLAGS += --sysroot=$(TOPSBOT_SYSROOT) -I$(TOPSBOT_INSTALL)/include
LDFLAGS  += --sysroot=$(TOPSBOT_SYSROOT) -L$(TOPSBOT_INSTALL)/lib
```

For non-interactive runs:
`tb exec bash -c 'source /mnt/topsbot_cc/topsbot_ws/tools/scripts/cross_env.sh && make'`

### Sysroot path mechanics & CMake rules for package authors

Cross builds live in **three path worlds** that must agree:

| World | Path | Who believes it |
| --- | --- | --- |
| Container | `/usr/lib/riscv64-linux-gnu/...` | gcc-cross (`--with-sysroot=/`) and CMake-generated `build.make` prerequisites |
| Sysroot | `/sysroot/usr/lib/riscv64-linux-gnu/...` | `find_*` re-rooting, pkg-config, `CMAKE_SYSROOT` |
| Target device | `/usr/lib/riscv64-linux-gnu/...` | the produced binaries at runtime (SONAMEs) |

`cross_env.sh` stitches the worlds together: it exports the cross vars,
prepends the workspace install to `CMAKE_PREFIX_PATH`, points
`PKG_CONFIG_{PATH,SYSROOT_DIR}` at the sysroot, detects the target Python,
and mirrors every sysroot dev `*.so` into the container's
`/usr/lib/riscv64-linux-gnu/` (skip-if-exists). The mirror is required
because CMake stores file-level link prerequisites `CMAKE_SYSROOT`-relative
(bare `/usr/...`) and `make` stats those paths without consulting any
compiler; gcc-cross in turn believes its sysroot is `/`. With the mirror,
both spellings resolve to the same files, and linking records correct
SONAMEs for the device.

Rules for `CMakeLists.txt` in this workspace:

1. Resolve system libraries through `find_package` / `find_library` /
   `pkg_check_modules` and link **targets or variables** — never hand-written
   absolute paths. Cross builds get them sysroot-prefixed, native builds
   (release farm) get them as-is; both work with zero per-mode branches.
2. Vendored/prebuilt libs (e.g. orbbec `SDK/lib/<arch>/libOrbbecSDK.so.2`)
   shall be linked by **repo-relative full path** — those are outside
   `CMAKE_SYSROOT`, immune to prefix stripping, and real in both modes.
3. Never reference `/sysroot`, container paths or `uname` results inside
   CMake code; platform/arch branching uses `CMAKE_CROSSCOMPILING` /
   `CMAKE_SYSTEM_PROCESSOR` only (see orbbec_camera's `HOST_PLATFORM`).
4. New system deps go into `package.xml` as rosdep keys; keys missing from
   rosdistro are added to `tools/scripts/rosdep/topsbot.yaml` (loaded as
   `10-topsbot.list`, i.e. it only fills gaps the official DB lacks).

## Configuration

Products are configured as **targets** in `topsbot_ws/configs/target/<board>/<board>.json` (a board gets its own directory so the JSON can reference sibling files). Each board JSON has a `variants` map (Ubuntu suite: jammy / noble). `lunch` selects the active board + variant (exports `BUILD_TARGET` and `BUILD_VARIANT`); commands that need a target error out if not lunched:

```bash
$ tb build
no target selected: run 'lunch' to pick one
```

```bash
lunch mes20            # board default variant (jammy)
lunch mes20-jammy
lunch mes20-noble
lunch 11               # variant id from the menu
```

Sysroot download/extract dir and `tb package` distro follow the lunched variant. Switching variant does not reuse the other suite's sysroot; `tb-build` is recreated when the sysroot path changes. Cross-build `install/` is shared — run `tb clean` after switching suites.

### target JSON fields

```json
{
  "name": "mes20",
  "board": "mes20",
  "platform": "MES20",
  "repos": "configs/ros2_release.repos",
  "default_variant": "jammy",
  "variants": {
    "jammy": {
      "id": 10,
      "distro": "jammy",
      "sysroot": {
        "url": "https://…/s/SHARE?domainId=…"
      }
    },
    "noble": {
      "id": 11,
      "distro": "noble",
      "sysroot": {
        "url": "https://…/s/SHARE?domainId=…",
        "file": "*noble*"
      }
    }
  }
}
```

| Field | Purpose |
| --- | --- |
| `id` / `board` / `product` | lunch menu display (variant `id` is the menu number) |
| `platform` | Build platform (passed to build.sh `-p`) |
| `repos` | Source manifest for `tb update code` (file name or absolute path) |
| `default_variant` | Used by `lunch mes20` when no suite suffix is given |
| `variants.<suite>.distro` | Ubuntu codename; default for `tb package` |
| `variants.<suite>.image` | Local host image tag; omit → `topsbot_riscv64_cross_build:{variant}` |
| `variants.<suite>.remote_image` | If set, pull this and tag as `image` (no local fallback). Omit → build from `topsbot_ws/tools/docker/` |
| `variants.<suite>.container` | Persistent build container name; omit → `tb-build-{variant}` |
| `variants.<suite>.sysroot.url` | Aliyun share or direct tarball URL |
| `variants.<suite>.sysroot.file` | Optional glob to pick a file inside a share (`*noble*`) |
| `variants.<suite>.sysroot.dir` | Extract + compile sysroot directory |
| `sysroot.packages` | Optional package-list file (next to the board JSON, one apt package name per line); commands that need the sysroot ensure these exist inside it. Manual supplement to the automatic rosdep resolution (see Dependencies) |

`sysroot.url` and `sysroot.dir` — at least one is required. URL only extracts to `sysroot/{variant}` (tarball cached in `sysroot/archives/`); dir only uses that tree (no download).

`tb package --distro` still exists as an override; it defaults to the lunched variant's `distro`.

### Override merge (compose-style)

Local overrides go into `topsbot_ws/configs/target/<board>/<board>.override.json` (**not in git**), deep-merged with the baseline (nested fields override per-key):

```bash
tb config sysroot.url=https://mirror/…   # writes variants.<active>.sysroot.url
```

### tb config

```bash
tb config                        # show effective config (baseline + override)
tb config <key>                  # read one field (dotted, e.g. sysroot.url)
tb config <key>=<value>          # write into the override (dotted, nested auto-created)
tb config --raw [key]            # machine-readable JSON output
tb config --merge                # merge override back into the baseline target JSON, remove override
```

`tb config` also requires `lunch` (the active target decides); `--merge` formalizes local customization as baseline (can be committed and distributed).

### Switching the source download

`tb update code` reads the `repos` field of the active target. Two manifests are shipped:

- `topsbot_ws/configs/ros2_release.repos` — GitHub public sources (**default**)
- `topsbot_ws/configs/ros2.repos` — internal GitLab sources (commonly set via override)

```bash
tb config repos=configs/ros2.repos       # use internal GitLab manifest (writes local override)
# or an absolute path:  tb config repos=/path/to/xxx.repos

tb config repos                  # confirm the effective value
```

## Layout

```
topsbot_cc/
├── sysroot/                  # sysroot/{jammy,noble} + archives/ (path from JSON `sysroot.dir`)
└── topsbot_ws/
    ├── configs/
    │   ├── target/               # product configs (<board>/<board>.json + local *.override.json)
    │   ├── ros2.repos            # internal GitLab manifest
    │   └── ros2_release.repos    # GitHub public manifest
    ├── src/                  # sources (filled by vcs import)
    ├── build/ install/ log/
    ├── tools/
    │   ├── docker/           # cross-compile host image
    │   ├── sysroot/          # topsbot_ros_base checkout (builds + publishes the sysroot)
    │   ├── packages/         # in-tree meta packages (ros_workspace, topsbot_ros, topsbot_base)
    │   └── scripts/          # envsetup.sh, tb.py, build.sh, package.sh, etc.
```

## License

Apache-2.0, see [LICENSE](LICENSE). Version history in [CHANGELOG](CHANGELOG.md).
