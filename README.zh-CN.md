# topsbot_cc

[English](README.md) | [简体中文](README.zh-CN.md)

面向 **MES20**（RISC-V64，Ubuntu 22.04）的 **ROS 2 Humble 交叉编译 SDK**：在 x86_64 Linux 主机上通过 Docker 编译可在板端运行的 ROS 2 包，无需在开发板上完整编译。

---

## 简介

本仓库提供交叉编译所需的脚本、工具链 CMake 配置与 Docker 工作流。**不包含** sysroot 与源码包——sysroot 在首次使用时自动下载解压，源码由用户自行放入 `topsbot_ws/src/` 或通过 `ros2_release.repos` 导入。

### 仓库内容

| 路径 | 说明 |
|------|------|
| `topsbot_ws/tools/` | 交叉编译脚本、RISC-V 工具链 CMake、Docker 启动脚本 |
| `topsbot_ws/ros2_release.repos` | 从 GitHub 导入开源 TopsBot 包 |
| `topsbot_sysroot/` | 解压后的板端根文件系统 |
| `topsbot_sysroot.tar.gz` | sysroot 压缩包（由脚本下载） |

### 环境要求

- Linux 主机（建议 **x86_64**）
- **Docker**（用于交叉编译容器）
- **wget** 或 **curl**（下载 sysroot）

### 快速开始

```bash
git clone https://github.com/TopsBot/topsbot_cc.git
cd topsbot_cc

# 下载并解压 sysroot（启动 Docker 时也会自动执行）
bash topsbot_ws/tools/download_sysroot.sh

# 从 GitHub 导入 ROS 2 源码
cd topsbot_ws
vcs import src < ros2_release.repos

# 启动交叉编译容器（挂载仓库与 sysroot）
sudo topsbot_ws/tools/start_topsbot_cross_build_docker.sh

# 在容器内编译指定包（示例）
topsbot_ws/tools/build.sh -s 'topsbot_msgs'
```

`topsbot_ws/src/` 不在仓库中，需自行创建或通过 `vcs import` 填充后再执行 `build.sh`。

### 常用命令

**Sysroot 管理**（`download_sysroot.sh`）：

```bash
bash topsbot_ws/tools/download_sysroot.sh              # 缺 tgz 则下载，缺 sysroot 则解压
bash topsbot_ws/tools/download_sysroot.sh --force      # 强制重新下载并解压
bash topsbot_ws/tools/download_sysroot.sh --extract-only   # 仅解压本地 tgz
```

**Docker 容器**（`start_topsbot_cross_build_docker.sh`）：

```bash
sudo topsbot_ws/tools/start_topsbot_cross_build_docker.sh            # 启动容器
sudo topsbot_ws/tools/start_topsbot_cross_build_docker.sh --update    # 强制重新拉取 Docker 镜像
sudo topsbot_ws/tools/start_topsbot_cross_build_docker.sh --update-sysroot  # 强制更新 sysroot
```

**交叉编译**（`build.sh`，在容器内执行）：

```bash
topsbot_ws/tools/build.sh -s '<package_name>'                        # 编译指定包
topsbot_ws/tools/build.sh -s 'pkg_a pkg_b'                           # 编译多个包
topsbot_ws/tools/build.sh -r '--packages-up-to my_pkg'               # 使用 colcon 原始选项
topsbot_ws/tools/build.sh -s 'my_pkg' -c '-DCMAKE_BUILD_TYPE=Debug'  # 附加 CMake 参数
```

编译产物输出到 `topsbot_ws/install/`，可通过 `scp` 等方式部署到 MES20 板端。

**在 sysroot 中安装额外依赖**（可选，在容器内执行）：

```bash
topsbot_ws/tools/sysroot_apt.sh update
topsbot_ws/tools/sysroot_apt.sh install ros-humble-<package>
```

### 目录结构

```
topsbot_cc/
├── topsbot_sysroot.tar.gz
├── topsbot_sysroot/
└── topsbot_ws/
    ├── src/                  # 用户自建 / vcs import
    ├── build/ install/ log/
    ├── ros2_release.repos
    └── tools/
        ├── build.sh
        ├── download_sysroot.sh
        ├── riscv64_toolchainfile.cmake
        ├── start_topsbot_cross_build_docker.sh
        └── sysroot_apt.sh
```

### 许可证

Apache-2.0，见 [LICENSE](LICENSE)。版本变更见 [CHANGELOG](CHANGELOG.md)。
