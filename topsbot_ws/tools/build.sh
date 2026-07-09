#!/bin/bash

#*******************
platform=MES20
#*******************

function show_usage() {
  echo ""
  echo "Usage: bash -e $0 <options>"
  echo ""
  echo "Available options:"
  echo "  -p|--platform       MES20 (default)"
  echo "  -s|--selction       colcon --packages-select [PKG ...]"
  echo "  -c|--cmake-args     extra cmake-args"
  echo "  -r|--raw_options    raw colcon options, e.g. \"--packages-up-to pkg ...\""
  echo "  -h|--help"
  echo ""
  echo "Package selection priority: -s/--selction, then -r/--raw_options"
  exit 1
}

PACKAGE_SELECTION=""
RAW_OPTIONS=""
CMAKE_ARGS=""

PLATFORM_OPTS=(MES20)
GETOPT_ARGS=`getopt -o p:s:c:r:h -al platform:,selction:,cmake-args:,raw_options:,help -- "$@"`
eval set -- "$GETOPT_ARGS"

while [ -n "$1" ]
do
  case "$1" in
    -p|--platform)
      platform=$2
      shift 2
      if [[ ! "${PLATFORM_OPTS[@]}" =~ $platform ]] ; then
        echo "invalid platform: $platform (only MES20 is supported)"
        show_usage
      fi
      ;;
    -s|--selction)
      selction=$2
      shift 2
      echo "colcon build selction: $selction"
      PACKAGE_SELECTION="--packages-select $selction"
      ;;
    -c|--cmake-args)
      CMAKE_ARGS=$2
      shift 2
      echo "cmake-args: $CMAKE_ARGS"
      ;;
    -r|--raw_options)
      RAW_OPTIONS=$2
      shift 2
      echo "RAW_OPTIONS: $RAW_OPTIONS"
      ;;
    -h|--help) show_usage; break;;
    --) break ;;
    *) echo $1,$2 show_usage; break;;
  esac
done

if [ -z "${PACKAGE_SELECTION}" ]; then
  echo "PACKAGE_SELECTION is empty and reset with RAW_OPTIONS [$RAW_OPTIONS]"
  PACKAGE_SELECTION=$RAW_OPTIONS
fi
echo "PACKAGE_SELECTION: $PACKAGE_SELECTION"

export ROS_VERSION=2
export PLATFORM_MES20=OFF

echo "build platform ${platform}"

source /etc/profile.d/riscv64-cross-env.sh 2>/dev/null || true
export TARGET_ARCH=riscv64
export TARGET_TRIPLE=riscv64-linux-gnu
export CROSS_COMPILE=/usr/bin/${TARGET_TRIPLE}-

TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOPSBOT_WS="$(cd "${TOOLS_DIR}/.." && pwd)"
TOPSBOT_CC="$(cd "${TOPSBOT_WS}/.." && pwd)"
SYSROOT="${TOPSBOT_CC}/topsbot_sysroot"
INSTALL_PREFIX="${TOPSBOT_WS}/install"
TOOLCHAIN_FILE="${TOOLS_DIR}/riscv64_toolchainfile.cmake"

if [ ! -d "${SYSROOT}/usr/bin" ]; then
  echo "[ERROR] ${SYSROOT}/usr 不存在"
  exit 1
fi

if [[ -f /opt/tbros/humble/setup.bash ]]; then
  # shellcheck source=/dev/null
  source /opt/tbros/humble/setup.bash
  TOPSBOT_ROS_PREFIX=/opt/tbros/humble
elif [[ -f /opt/ros/humble/setup.bash ]]; then
  # shellcheck source=/dev/null
  source /opt/ros/humble/setup.bash
  TOPSBOT_ROS_PREFIX=/opt/ros/humble
else
  echo "[ERROR] 未找到 /opt/tbros/humble/setup.bash 或 /opt/ros/humble/setup.bash"
  exit 1
fi
export TOPSBOT_ROS_PREFIX

mkdir -p "${INSTALL_PREFIX}"

cd "${TOPSBOT_WS}"

# 仅当 workspace 已编过（存在 local_setup）才加入 install，避免 colcon 警告
CMAKE_PREFIX_PATH_FOR_BUILD="${AMENT_PREFIX_PATH:-${TOPSBOT_ROS_PREFIX}}"
if [ -f "${INSTALL_PREFIX}/local_setup.bash" ] || [ -f "${INSTALL_PREFIX}/local_setup.sh" ]; then
  export AMENT_PREFIX_PATH="${INSTALL_PREFIX}:${AMENT_PREFIX_PATH}"
  CMAKE_PREFIX_PATH_FOR_BUILD="${INSTALL_PREFIX}:${CMAKE_PREFIX_PATH_FOR_BUILD}"
fi
export CMAKE_PREFIX_PATH="${CMAKE_PREFIX_PATH_FOR_BUILD}"

export PKG_CONFIG_PATH="${SYSROOT}/usr/lib/riscv64-linux-gnu/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR="${SYSROOT}"
export TOPSBOT_SYSROOT="${SYSROOT}"

colcon build $PACKAGE_SELECTION \
      --merge-install \
      --cmake-force-configure \
      --cmake-args \
        -Wno-dev \
        $CMAKE_ARGS \
        -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
        --no-warn-unused-cli \
        -DCMAKE_TOOLCHAIN_FILE=${TOOLCHAIN_FILE} \
        -DCMAKE_PREFIX_PATH="${CMAKE_PREFIX_PATH_FOR_BUILD}" \
        -DPLATFORM_MES20=ON \
        -DTHIRDPARTY=ON \
|| echo -e "\033[1;31m[ERROR]\033[0m colcon build failed"
