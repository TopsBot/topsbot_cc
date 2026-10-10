# topsbot_cc

[English](README.md) | [简体中文](README.zh-CN.md)

面向 **MES20**（RISC-V64，Ubuntu 22.04）的 **ROS 2 Humble 交叉编译 SDK**：在 x86_64 Linux 主机上通过编译容器产出可在板端运行的 ROS 2 包，无需在开发板上完整编译。

---

## 简介

本仓库为消费端：拉取源码、下载 sysroot、在编译容器中交叉编译。sysroot 由 `topsbot_ros_base`（`topsbot_ws/tools/sysroot` 的 `sysroot/`）构建并打包发布，这里只负责下载使用。

## 快速开始

从 GitHub 克隆（或内网 GitLab）：

```bash
git clone https://github.com/TopsBot/topsbot_cc.git
cd topsbot_cc
source topsbot_ws/tools/scripts/envsetup.sh   # 激活命令环境
lunch                       # 选择产品 + Ubuntu variant（mes20-jammy / mes20-noble）
tb update sysroot           # 下载并解压 sysroot（首次必需）
tb update code              # 拉取源码（默认 configs/ros2.repos）
m                           # 全量交叉编译；m -s <pkg> 单包；mm 编译当前包
```

产物输出到 `topsbot_ws/install/`，通过 `scp` 部署到板端。

## 命令

`topsbot_ws/tools/scripts/envsetup.sh` 提供 `lunch`/`m`/`mm`/`tb`；`tb` 子命令按职责分组：

| 命令 | 说明 |
| --- | --- |
| `lunch [target]` | 选择产品 + variant（无参=菜单；`lunch mes20` / `lunch mes20-noble`；配置在 `topsbot_ws/configs/target/<board>/<board>.json`） |
| `tb update code` | 同步源码到最新（vcs import + pull；有未保存本地更改的仓库会提醒并跳过） |
| `tb update sysroot` | 下载/解压 sysroot（`--download-only` / `--extract-only`）；已有 sysroot 时刷新会询问一次（其中的本地更改将被删除） |
| `tb update docker-image` | 拉取/更新编译容器镜像；已有镜像时刷新会询问一次 |
| `tb update all` | 以上全部 |
| `tb build` / `tb clean` | 编译 / 清理（默认全量；`-s <pkg>` 单包；`--verbose` 实时输出） |
| `tb shell --cross` / `--sysroot` | 快速交叉编译验证环境（已预载交叉环境）/ 进入 sysroot |
| `tb exec <cmd>` | 在编译容器中执行任意命令 |
| `tb config [key[=value]]` | 查看/设置 target 配置（`--raw` JSON；`--merge` 合并回基线） |
| `tb top` | cd 到仓库根 |
| `m` / `mm` | 全量编译 / 当前包编译（自动检测包目录） |

`m clean` / `mm clean` 分别清理全量/单包（含 `debsrc/<distro>/` 打包产物）；`tb clean --container` 重置编译容器（丢弃容器内状态）。

`tb -h` 默认只显示常用命令；`tb -h --full` 显示全部命令。

## 依赖

每次编译前会自动用 **rosdep** 解析 `src/` + `tools/packages/` 下所有 package.xml 的依赖（规则来源：rosdistro + `tools/scripts/rosdep/topsbot.yaml`），把缺失的 riscv64 deb 下载并解包进 sysroot——引入新包通常不再需要手动维护 sysroot。只考虑编译期标签（`depend` / `build_depend` / `build_export_depend` / `buildtool_depend`）：sysroot 是为交叉编译服务的，运行时库本就会随 `-dev` 包的依赖关系自动带入。解析是增量的（内容哈希 stamp，仅当 package.xml 或规则变化时重跑），并复用 sysroot 自带的 apt 源，因此私有 `tbros-*` / `taco-sdk` 包同样可解析安装。rosdep 无法解析的 key 会以警告列出；可补进 `tools/scripts/rosdep/topsbot.yaml`，或在 board 的 `sysroot.packages` 文件里直接写 apt 包名作为人工补充。

## 交叉编译自己的代码

编译容器里已经备好了完整的交叉工具链、sysroot 和工作区编译产物——`tb shell --cross` 进入后环境已预载，可以直接编译验证自己的代码：

| 变量 | 用途 |
| --- | --- |
| `CROSS_COMPILE` | 编译器/kbuild 前缀（`$(CROSS_COMPILE)gcc`） |
| `TOPSBOT_SYSROOT` | 目标根文件系统（`/sysroot`），`--sysroot=` 用；头文件和库都在里面 |
| `TOPSBOT_TOOLCHAIN_FILE` | 现成的 CMake toolchain file |
| `TOPSBOT_INSTALL` | 工作区编译产物（`install/include`、`install/lib`） |
| `CMAKE_PREFIX_PATH` / `AMENT_PREFIX_PATH` | `find_package` 搜索路径（工作区 install + ROS underlay） |
| `PKG_CONFIG_PATH` / `PKG_CONFIG_SYSROOT_DIR` | 交叉 `pkg-config`，开箱即用 |

CMake 项目无需任何其他改动——toolchain file 已经接管编译器、sysroot、查找路径，连 `try_run` 的 qemu 模拟器都配好了：

```bash
tb shell --cross
cmake -B build -DCMAKE_TOOLCHAIN_FILE=$TOPSBOT_TOOLCHAIN_FILE
cmake --build build
```

纯 Makefile 项目把同样的变量映射进去：

```make
CC       := $(CROSS_COMPILE)gcc
CXX      := $(CROSS_COMPILE)g++
CFLAGS   += --sysroot=$(TOPSBOT_SYSROOT) -I$(TOPSBOT_INSTALL)/include
CXXFLAGS += --sysroot=$(TOPSBOT_SYSROOT) -I$(TOPSBOT_INSTALL)/include
LDFLAGS  += --sysroot=$(TOPSBOT_SYSROOT) -L$(TOPSBOT_INSTALL)/lib
```

非交互脚本场景：
`tb exec bash -c 'source /mnt/topsbot_cc/topsbot_ws/tools/scripts/cross_env.sh && make'`

### sysroot 路径机制与包作者的 CMake 约定

交叉构建同时存在**三个路径世界**，它们必须相互对齐：

| 世界 | 路径形态 | 谁在用 |
| --- | --- | --- |
| 容器 | `/usr/lib/riscv64-linux-gnu/...`（裸路径） | gcc-cross（`--with-sysroot=/`）以及 CMake 生成的 `build.make` 文件级依赖 |
| sysroot | `/sysroot/usr/lib/riscv64-linux-gnu/...`（带前缀） | `find_*` 重根搜索、pkg-config、`CMAKE_SYSROOT` |
| 目标机 | `/usr/lib/riscv64-linux-gnu/...` | 产出的二进制运行时按 SONAME 找库（与容器同形，但真身在设备上） |

`cross_env.sh` 负责把三个世界缝合起来：导出交叉变量、把工作区 install 前插进
`CMAKE_PREFIX_PATH`、将 `PKG_CONFIG_{PATH,SYSROOT_DIR}` 指向 sysroot、探测目标机
Python，并把 sysroot 里的全部 dev `*.so` 软链镜像到容器的
`/usr/lib/riscv64-linux-gnu/`（已有则跳过）。镜像不可省：CMake 会把文件级链接
依赖按 `CMAKE_SYSROOT` 相对化（写成裸 `/usr/...`），而 `make` 判断依赖只 stat
文件、不经过任何编译器；gcc-cross 又认为自己的 sysroot 是 `/`。镜像之后，两种
写法都指向同一真身，链接记录的 SONAME 对目标机也是正确的。

本工作区 `CMakeLists.txt` 的编写约定：

1. 系统库一律通过 `find_package` / `find_library` / `pkg_check_modules`
   解析，链接**目标或变量**——绝不手写绝对路径。交叉时自动带 sysroot 前缀，
   原生（发布农场）时路径本来就对，无需按模式写分支。
2. vendored/预编译库（如 orbbec 的 `SDK/lib/<arch>/libOrbbecSDK.so.2`）用
   **仓库内相对完整路径**链接——不在 `CMAKE_SYSROOT` 下、不受剥前缀影响，
   两种模式下都真实存在。
3. 禁止在 CMake 里引用 `/sysroot`、容器路径或 `uname` 结果；平台/架构分支
   只用 `CMAKE_CROSSCOMPILING` / `CMAKE_SYSTEM_PROCESSOR`
   （参考 orbbec_camera 的 `HOST_PLATFORM`）。
4. 新的系统依赖写进 `package.xml` 的 rosdep key；官方库没有的 key 加到
   `tools/scripts/rosdep/topsbot.yaml`（以 `10-topsbot.list` 加载，只兜官方库
   的缺口）。

## 配置

产品配置以 **target** 为单位，位于 `topsbot_ws/configs/target/<board>/<board>.json`（每个 board 独占一个目录，JSON 可引用同目录文件）。每个 board JSON 带 `variants`（Ubuntu suite：jammy / noble）。`lunch` 选择当前 board + variant（export `BUILD_TARGET` 和 `BUILD_VARIANT`）；未 `lunch` 时使用配置的命令会报错：

```bash
$ tb build
no target selected: run 'lunch' to pick one
```

```bash
lunch mes20            # board 默认 variant（jammy）
lunch mes20-jammy
lunch mes20-noble
lunch 11               # 菜单里的 variant id
```

Sysroot 下载/解压目录和 `tb package` 的 distro 都跟当前 variant。两套 suite 的 sysroot 不混用；sysroot 路径变了会重建 `tb-build`。交叉编译的 `install/` 仍共用，切 suite 后请 `tb clean`。

### target JSON 字段

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

| 字段 | 用途 |
| --- | --- |
| `id` / `board` / `product` | lunch 菜单显示（variant 的 `id` 是菜单编号） |
| `platform` | 编译平台（传给 build.sh `-p`） |
| `repos` | `tb update code` 使用的源码清单 |
| `default_variant` | `lunch mes20` 未写 suite 后缀时使用 |
| `variants.<suite>.distro` | Ubuntu 代号；`tb package` 的默认 distro |
| `variants.<suite>.image` | 本地 host 镜像 tag；不写则 `topsbot_riscv64_cross_build:{variant}` |
| `variants.<suite>.remote_image` | 写了则 pull 再 tag 成 `image`（失败不回落本地构建）。不写则用 `topsbot_ws/tools/docker/` 本地构建 |
| `variants.<suite>.container` | 持久编译容器名；不写则 `tb-build-{variant}` |
| `variants.<suite>.sysroot.url` | 阿里云分享或直接 tarball URL |
| `variants.<suite>.sysroot.file` | 可选，分享目录里按 glob 选文件（如 `*noble*`） |
| `variants.<suite>.sysroot.dir` | 解压并参与编译的 sysroot 目录 |
| `sysroot.packages` | 可选，包列表文件（与 board JSON 同目录，每行一个 apt 包名）；任何需要 sysroot 的命令会确保这些包存在于 sysroot 内。是自动 rosdep 依赖解析（见「依赖」）的人工补充 |

`sysroot.url` 与 `sysroot.dir` 至少填一项。只写 URL 时解压到 `sysroot/{variant}`（tarball 缓存在 `sysroot/archives/`）；只写 dir 则直接用该目录（不下载）。

`tb package --distro` 仍可显式覆盖，默认跟 lunched variant 的 `distro`。

### override 合并（compose 式）

本地覆盖项写入 `topsbot_ws/configs/target/<board>/<board>.override.json`（**不提交 git**），加载时与基线配置深度合并，嵌套字段按 key 逐项覆盖：

```bash
tb config sysroot.url=https://内网镜像/…   # 写入 variants.<当前>.sysroot.url
```

### tb config

```bash
tb config                        # 查看当前 target 生效配置（基线+override）
tb config <key>                  # 读取单个字段（点路径，如 sysroot.url）
tb config <key>=<value>          # 写入 override（点路径，嵌套自动创建）
tb config --raw [key]            # 机器可读 JSON 输出
tb config --merge                # 将 override 合并写回基线 target JSON，并删除 override
```

`tb config` 同样要求已 `lunch`（当前 target 由它决定）；`--merge` 会把本地定制正式化为基线（提交后可随仓库分发）。

### 切换源码下载源

`tb update code` 读取 `topsbot_ws/configs/target/<board>/<board>.json` 的 `repos` 字段。仓库提供两个清单：

- `topsbot_ws/configs/ros2_release.repos`——GitHub 公开源码（默认）
- `topsbot_ws/configs/ros2.repos`——内网 GitLab 源码（本地开发常用 override）

切换下载源：

```bash
tb config repos=configs/ros2.repos              # 改用内网 GitLab 清单（写本地 override）
# 或指定绝对路径：  tb config repos=/path/to/xxx.repos

# 确认生效（读取字段）
tb config repos
# "configs/ros2.repos"
```

写入的是 `topsbot_ws/configs/target/<board>/<board>.override.json`（本地覆盖，不入 git）；如需作为默认随仓库分发，`tb config --merge` 后提交即可。

## 目录结构

```
topsbot_cc/
├── sysroot/                  # sysroot/{jammy,noble} + archives/（路径来自 JSON `sysroot.dir`）
└── topsbot_ws/
    ├── configs/
    │   ├── target/               # 产品配置（<board>/<board>.json + 本地 *.override.json）
    │   ├── ros2.repos            # 内网源码清单
    │   └── ros2_release.repos    # GitHub 公开清单
    ├── src/                  # 源码（vcs import 填充）
    ├── build/ install/ log/
    ├── tools/
    │   ├── docker/           # 交叉编译 host 镜像
    │   ├── sysroot/          # topsbot_ros_base checkout（构建并发布 sysroot）
    │   ├── packages/         # 仓内元包（ros_workspace、topsbot_ros、topsbot_base）
    │   └── scripts/          # envsetup.sh、tb.py、build.sh、package.sh 等
```

## 许可证

Apache-2.0，见 [LICENSE](LICENSE)。版本变更见 [CHANGELOG](CHANGELOG.md)。
