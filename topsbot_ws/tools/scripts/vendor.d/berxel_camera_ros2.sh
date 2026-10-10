#!/usr/bin/env bash
# vendor.d/berxel_camera_ros2.sh — copy the (already in-repo) Berxel Hawk SDK
# tree into the package work tree.
#
# bloom debianizes only the ROS package directory
#   src/BerxelSDK_ROS2_riscv64/RosSDKNode/berxel_camera_ros2
# while the driver is built against the SDK sitting next to it in the workspace
#   src/BerxelSDK_ROS2_riscv64/{Include,libs}   (CMakeLists.txt fallback
#   ${CMAKE_CURRENT_SOURCE_DIR}/../../Include)
# OBS builds from the rolled orig tarball, where that path does not exist, so
# the SDK has to travel inside the package: copy it to <pkg>/sdk/{Include,libs}
# and let CMakeLists.txt fall back to that location. No third-party code is
# fetched here — the payload is already part of this repository.
#
# Invoked by package.sh (`tb package`) with the package work tree as $1.
# Usage: tools/scripts/vendor.d/berxel_camera_ros2.sh [berxel_camera_ros2-dir]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
SDK_ROOT="${WS}/src/BerxelSDK_ROS2_riscv64"
TARGET="${1:-${SDK_ROOT}/RosSDKNode/berxel_camera_ros2}"

if [[ ! -f "${TARGET}/package.xml" ]]; then
  echo "[vendor] ERROR: ${TARGET} is not the berxel_camera_ros2 package dir" >&2
  exit 1
fi
for part in Include libs; do
  if [[ ! -d "${SDK_ROOT}/${part}" ]]; then
    echo "[vendor] ERROR: missing SDK dir ${SDK_ROOT}/${part}" >&2
    exit 1
  fi
done

mkdir -p "${TARGET}/sdk"
cp -a "${SDK_ROOT}/Include" "${SDK_ROOT}/libs" "${TARGET}/sdk/"
echo "[vendor] Berxel Hawk SDK -> ${TARGET}/sdk ($(find "${TARGET}/sdk" -type f | wc -l) files, $(du -sh "${TARGET}/sdk" | cut -f1))"
