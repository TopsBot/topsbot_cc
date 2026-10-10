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
GETOPT_ARGS=$(getopt -o p:s:c:r:h -al platform:,selction:,cmake-args:,raw_options:,help -- "$@")
eval set -- "$GETOPT_ARGS"

while [ -n "$1" ]; do
    case "$1" in
    -p | --platform)
        platform=$2
        shift 2
        if [[ ! "${PLATFORM_OPTS[@]}" =~ $platform ]]; then
            echo "invalid platform: $platform (only MES20 is supported)"
            show_usage
        fi
        ;;
    -s | --selction)
        selction=$2
        shift 2
        PACKAGE_SELECTION="--packages-select $selction"
        ;;
    -c | --cmake-args)
        CMAKE_ARGS=$2
        shift 2
        ;;
    -r | --raw_options)
        RAW_OPTIONS=$2
        shift 2
        ;;
    -h | --help)
        show_usage
        break
        ;;
    --) break ;;
    *)
        echo $1,$2 show_usage
        break
        ;;
    esac
done

if [ -z "${PACKAGE_SELECTION}" ]; then
    PACKAGE_SELECTION=$RAW_OPTIONS
fi

export ROS_VERSION=2
export PLATFORM_MES20=OFF

echo "build platform ${platform}"

# Cross env shared with hand builds (tb shell --cross sources the same file).
# shellcheck source=cross_env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cross_env.sh" || exit 1

cd "${TOPSBOT_WS}"

colcon build $PACKAGE_SELECTION \
    --base-paths src tools/packages \
    --merge-install \
    --cmake-force-configure \
    --cmake-args \
    -Wno-dev \
    $CMAKE_ARGS \
    -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
    --no-warn-unused-cli \
    -DCMAKE_TOOLCHAIN_FILE=${TOPSBOT_TOOLCHAIN_FILE} \
    -DCMAKE_PREFIX_PATH="${CMAKE_PREFIX_PATH}" \
    -DPYTHON_MAJOR_MINOR="${PYTHON_MAJOR_MINOR}" \
    -DPYTHON_LIBRARY="${TOPSBOT_SYSROOT}/usr/lib/riscv64-linux-gnu/libpython${PYTHON_MAJOR_MINOR}.so" \
    -DPYTHON_INCLUDE_DIR="${TOPSBOT_SYSROOT}/usr/include/python${PYTHON_MAJOR_MINOR}" \
    -DPLATFORM_MES20=ON \
    -DTHIRDPARTY=ON
rc=$?
if [[ $rc -ne 0 ]]; then
    echo -e "\033[1;31m[ERROR]\033[0m colcon build failed"
    exit $rc
fi
