#!/usr/bin/env bash
# vendor.d/performance_test.sh — populate performance_test's third_party/ with
# the pinned header-only deps (tclap, rapidjson, tabulate, sole) that its
# CMakeLists.txt otherwise downloads at build time with ExternalProject.
# OBS workers cannot git clone GitHub, so the sources must already be inside
# the package tree when dpkg-source rolls the orig tarball.
#
# Invoked by package.sh (`tb package`) with the package work tree as $1 —
# the vendored payload is disposable: it ships inside the .dsc for offline
# builders (OBS) and is wiped with the work tree afterwards. The source tree
# is normally NOT vendored: local `m`/`mm` cross builds download the deps via
# ExternalProject like upstream. Manual vendoring of the source tree remains
# possible for offline development:
#   topsbot_ws/tools/scripts/vendor.d/performance_test.sh [performance_test-pkg-dir]
#
# Clones are cached under ${CC_ROOT}/.vendor-cache (host-visible, survives
# container recreation); patches tracked upstream at third_party/*/diff.patch
# are applied on a scratch copy, the cache stays pristine.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
CC_ROOT="$(dirname "${WS}")"
CACHE="${CC_ROOT}/.vendor-cache"
SCRATCH="${CACHE}/.scratch"

# Package dir = the dir holding package.xml (third_party/ sits directly in it).
TARGET="${1:-${WS}/src/performance_test/performance_test}"
if [[ ! -f "${TARGET}/package.xml" ]]; then
  echo "[vendor] ERROR: ${TARGET} is not the performance_test package dir" >&2
  exit 1
fi

log() { echo "[vendor] $*"; }

# name|git-url|tag
DEPS=(
  "tclap|https://github.com/mirror/tclap.git|1.4.0-rc1"
  "rapidjson|https://github.com/Tencent/rapidjson.git|v1.1.0"
  "tabulate|https://github.com/p-ranav/tabulate.git|v1.4"
  "sole|https://github.com/r-lyeh-archived/sole.git|1.0.2"
)

fetch() { # name url tag
  local name="$1" url="$2" tag="$3" dst="${CACHE}/$1"
  if [[ ! -d "${dst}/.git" ]]; then
    log "cloning ${name}@${tag}"
    rm -rf "${dst}"
    git -c advice.detachedHead=false clone -q --depth 1 --branch "${tag}" "${url}" "${dst}"
  fi
}

stage() { # name — copy cache clone to scratch and apply third_party patch
  local name="$1" src="${CACHE}/$1" dst="${SCRATCH}/$1"
  mkdir -p "${SCRATCH}"
  rm -rf "${dst}"
  cp -a "${src}" "${dst}"
  local patch="${TARGET}/third_party/${name}/diff.patch"
  if [[ -f "${patch}" ]]; then
    patch -s -p1 -d "${dst}" <"${patch}"
  fi
}

install_dep() { # name — copy the staged headers into the target tree
  local name="$1" src="${SCRATCH}/$1" out="${TARGET}/third_party/$1"
  case "${name}" in
  sole)
    cp -a "${src}/sole.hpp" "${out}/sole.hpp"
    ;;
  *) # tclap / rapidjson / tabulate ship an include/ dir
    rm -rf "${out}/include"
    cp -a "${src}/include" "${out}/include"
    ;;
  esac
}

mkdir -p "${CACHE}"
# Vendored content is disposable: wipe any stale payload before re-populating,
# so a re-run never builds on top of outdated headers.
rm -rf "${TARGET}/third_party/tclap/include" \
  "${TARGET}/third_party/rapidjson/include" \
  "${TARGET}/third_party/tabulate/include" \
  "${TARGET}/third_party/sole/sole.hpp"
for entry in "${DEPS[@]}"; do
  IFS='|' read -r name url tag <<<"${entry}"
  fetch "${name}" "${url}" "${tag}"
  stage "${name}"
  install_dep "${name}"
done
rm -rf "${SCRATCH}"

# Same marker files CMakeLists.txt checks before choosing the vendored path.
for marker in \
  third_party/tclap/include/tclap/CmdLine.h \
  third_party/rapidjson/include/rapidjson/document.h \
  third_party/tabulate/include/tabulate/table.hpp \
  third_party/sole/sole.hpp; do
  if [[ ! -f "${TARGET}/${marker}" ]]; then
    echo "[vendor] ERROR: missing ${TARGET}/${marker} after vendoring" >&2
    exit 1
  fi
done
log "performance_test third_party vendored into ${TARGET}"
