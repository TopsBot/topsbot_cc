#!/usr/bin/env bash
# cross_env.sh — riscv64 cross env for the build container; sourced by
# build.sh (colcon) and hand builds alike, so both always agree.
#
#   tb shell --cross     # env preloaded
#   source /mnt/topsbot_cc/topsbot_ws/tools/scripts/cross_env.sh
#
# Exports: TARGET_*/CROSS_COMPILE, TOPSBOT_{SYSROOT,WS,INSTALL,TOOLCHAIN_FILE,
#   ROS_PREFIX}, CMAKE_PREFIX_PATH, AMENT_PREFIX_PATH, PKG_CONFIG_*, PYTHON_*
# Usage: README "Cross-compiling your own code".

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export TOPSBOT_WS="$(cd "${SCRIPTS_DIR}/../.." && pwd)"
export TOPSBOT_INSTALL="${TOPSBOT_WS}/install"
export TOPSBOT_TOOLCHAIN_FILE="${SCRIPTS_DIR}/riscv64_toolchainfile.cmake"

source /etc/profile.d/riscv64-cross-env.sh 2>/dev/null || true
export TARGET_ARCH=riscv64
export TARGET_TRIPLE=riscv64-linux-gnu
export CROSS_COMPILE=/usr/bin/${TARGET_TRIPLE}-

# Sysroot: tb injects TOPSBOT_SYSROOT_PATH=/sysroot for builds; interactive
# shells default to the container mount convention.
export TOPSBOT_SYSROOT="${TOPSBOT_SYSROOT_PATH:-/sysroot}"
if [ ! -d "${TOPSBOT_SYSROOT}/usr/bin" ]; then
    echo "[cross-env] ERROR: ${TOPSBOT_SYSROOT}/usr does not exist" >&2
    echo "[cross-env]        source this inside the build container (tb shell --cross)" >&2
    echo "[cross-env]        and fetch the sysroot first (tb update sysroot)" >&2
    return 1 2>/dev/null || exit 1
fi

# qemu-user target root: CMake try_run() (via CMAKE_CROSSCOMPILING_EMULATOR in
# the toolchain file) and hand runs of cross-built binaries both need it, or the
# riscv64 loader/libs are not found and feature probes fail silently.
export QEMU_LD_PREFIX="${TOPSBOT_SYSROOT}"

if [[ -f /opt/tbros/humble/setup.bash ]]; then
    # shellcheck source=/dev/null
    source /opt/tbros/humble/setup.bash
    TOPSBOT_ROS_PREFIX=/opt/tbros/humble
elif [[ -f /opt/ros/humble/setup.bash ]]; then
    # shellcheck source=/dev/null
    source /opt/ros/humble/setup.bash
    TOPSBOT_ROS_PREFIX=/opt/ros/humble
else
    echo "[cross-env] ERROR: /opt/tbros/humble/setup.bash or /opt/ros/humble/setup.bash not found" >&2
    return 1 2>/dev/null || exit 1
fi
export TOPSBOT_ROS_PREFIX

mkdir -p "${TOPSBOT_INSTALL}"

# install prepended once (idempotent), only when built (local_setup) —
# otherwise colcon warns; fall back to the ROS underlay.
if [ -f "${TOPSBOT_INSTALL}/local_setup.bash" ] || [ -f "${TOPSBOT_INSTALL}/local_setup.sh" ]; then
    _cmake_base="${CMAKE_PREFIX_PATH:-${AMENT_PREFIX_PATH:-${TOPSBOT_ROS_PREFIX}}}"
    case ":${AMENT_PREFIX_PATH}:" in
    *":${TOPSBOT_INSTALL}:"*) : ;;
    *) export AMENT_PREFIX_PATH="${TOPSBOT_INSTALL}:${AMENT_PREFIX_PATH:-}" ;;
    esac
    case ":${CMAKE_PREFIX_PATH}:" in
    *":${TOPSBOT_INSTALL}:"*) : ;;
    *) export CMAKE_PREFIX_PATH="${TOPSBOT_INSTALL}:${_cmake_base}" ;;
    esac
else
    export CMAKE_PREFIX_PATH="${CMAKE_PREFIX_PATH:-${AMENT_PREFIX_PATH:-${TOPSBOT_ROS_PREFIX}}}"
fi

export PKG_CONFIG_PATH="${TOPSBOT_SYSROOT}/usr/lib/riscv64-linux-gnu/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR="${TOPSBOT_SYSROOT}"

# Target Python comes from the sysroot underlay (jammy=3.10, noble=3.12),
# not the host python3 inside the cross image.
PYTHON_MAJOR_MINOR=""
for _p in "${TOPSBOT_SYSROOT}/opt/tbros/humble" "${TOPSBOT_SYSROOT}/opt/ros/humble" \
    /opt/tbros/humble /opt/ros/humble; do
    for _d in "${_p}"/lib/python3.*; do
        [[ -d "${_d}" ]] || continue
        PYTHON_MAJOR_MINOR="${_d##*/python}"
    done
done
PYTHON_MAJOR_MINOR="${PYTHON_MAJOR_MINOR:-3.10}"
export PYTHON_MAJOR_MINOR
export PYTHON_SOABI="cpython-${PYTHON_MAJOR_MINOR//./}-riscv64-linux-gnu"
echo "target python ${PYTHON_MAJOR_MINOR} (${PYTHON_SOABI})"

# Ubuntu gcc-cross is configured --with-sysroot=/. CMake then records
# -lpythonX.Y as /usr/lib/riscv64-linux-gnu/libpythonX.Y.so (host path).
# Point that at the target lib in the mounted sysroot (old jammy image
# copied stubs here; keep them out of the Dockerfile).
_host_pylib=/usr/lib/riscv64-linux-gnu
mkdir -p "${_host_pylib}"
shopt -s nullglob
for _f in "${TOPSBOT_SYSROOT}/usr/lib/riscv64-linux-gnu"/libpython${PYTHON_MAJOR_MINOR}*; do
    ln -sfn "${_f}" "${_host_pylib}/$(basename "${_f}")"
done
# CMake strips CMAKE_SYSROOT from link prerequisites recorded in build.make
# (it assumes the compiler's --sysroot re-resolves bare /usr paths).
# gcc-cross here is configured --with-sysroot=/, so those bare paths must
# exist in the container: mirror every sysroot dev .so the container lacks
# (existing files always win; first seen via VTK FindLZ4 → tanwaylidar_view
# "No rule to make target /usr/lib/riscv64-linux-gnu/liblz4.so").
for _f in "${TOPSBOT_SYSROOT}/usr/lib/riscv64-linux-gnu"/*.so; do
    _n="$(basename "${_f}")"
    [[ -e "${_host_pylib}/${_n}" ]] || ln -sn "${_f}" "${_host_pylib}/${_n}"
done
shopt -u nullglob
