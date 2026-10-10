#!/usr/bin/env bash
# package.sh — turn ROS 2 packages into debian source packages (.dsc + tarballs)
# with bloom (rosdebian generator) + dpkg-source. Runs inside the build
# container; invoked from tools/scripts/tb.py (`tb package`).
#
# bloom's stock output (ros-humble-* names, /opt/ros/humble prefix) is
# post-processed into the final tbros packaging: tbros-humble-* self names and
# /opt/tbros/humble *install* prefix, matching the debs published in
# topsbot-apt.topsfuture.com.cn. Lookup paths (CMAKE_PREFIX_PATH, ament,
# pkg-config, setup.sh) still include /opt/ros/humble so cmake can find the
# stock humble-jammy underlay that OBS already installed as Build-Depends.
#
# Persistent state (host-visible, survives container recreation):
#   .bloom/venv-<distro>/   bloom + rosdep python venv (per host python)
#   .bloom/ros/lists/       rosdep sources (ROSDEP_SOURCE_PATH)
#   .bloom/ros/home/        rosdep cache (ROS_HOME)
#   topsbot_ws/debsrc/<distro>/   resulting .dsc / .orig.tar.gz / .debian.tar.xz
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISTRO="jammy" # ubuntu codename for bloom --os-version; overridable via --distro

PKG=""
REFRESH=0
while [[ $# -gt 0 ]]; do
  case "$1" in
  -s | --package)
    PKG="${2:?missing package name}"
    shift 2
    ;;
  --distro)
    DISTRO="${2:?missing distro codename}"
    shift 2
    ;;
  --refresh)
    REFRESH=1
    shift
    ;;
  *)
    echo "[package] unknown argument: $1" >&2
    exit 2
    ;;
  esac
done

# Resolved after arg parsing so --distro picks the output subdir.
TOOLS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
WS="$(cd "${TOOLS_DIR}/.." && pwd)"
OUT_DIR="${WS}/debsrc/${DISTRO}"

log() { echo "[package] $*"; }

# Shared rosdep/bloom environment: path vars, ROSDEP_SOURCE_PATH/ROS_HOME
# exports, VENV, ensure_bloom/ensure_rosdep, resolve_humble_deb,
# gen_distro_rosdep_overlay. Requires DISTRO (and optionally REFRESH).
# shellcheck source=rosdep_env.sh
source "${SCRIPT_DIR}/rosdep_env.sh"

# Print "name dir" pairs for every package under src/ and tools/packages
# (nested repos included, e.g. topsbot_msgs/tb_det_msgs). Name comes from
# package.xml, like colcon. ROS1 (catkin) packages are skipped: they cannot
# be debianized for humble. Delegated to the shared comment-safe parser
# (naive grep/sed once skipped a package over a commented-out catkin line).
collect_pkgs() {
  python3 "${SCRIPT_DIR}/pkgxml.py" list "${SRC}" "${PACKAGES}"
}

package_one() {
  local pkg="$1" dir="$2"
  local work="${OUT_DIR}/.work/${pkg}"
  log "${pkg}: bloom-generate rosdebian (ubuntu ${DISTRO} / ROS humble)"
  rm -rf "${work}"
  mkdir -p "${work}"
  cp -a "${dir}/." "${work}/"
  # Per-package vendor hook: fetch third-party sources into the work tree
  # before bloom/dpkg-source, so OBS builds offline (e.g. performance_test's
  # header-only deps, which upstream downloads from GitHub at build time).
  local vendor_hook="${SCRIPT_DIR}/vendor.d/${pkg}.sh"
  if [[ -x "${vendor_hook}" ]]; then
    log "${pkg}: vendoring third-party sources"
    "${vendor_hook}" "${work}"
  fi
  (
    cd "${work}"
    "${VENV}/bin/bloom-generate" rosdebian \
      --os-name ubuntu --os-version "${DISTRO}" --ros-distro humble
    # bloom exits 0 even when rosdep resolution fails (its prompt path crashes
    # on non-TTY stdin), so verify the debian/ dir was actually generated.
    if [[ ! -f debian/changelog || ! -f debian/control ]]; then
      echo "[package] ERROR: bloom produced no debian/ for ${pkg} (see errors above)" >&2
      exit 1
    fi
    # Post-process bloom output into the final tbros packaging:
    #   - self package name  ros-humble-<pkg>  → tbros-humble-<pkg>
    #     (deps on real ros-humble-* packages are left untouched)
    #   - install destination /opt/ros/humble  → /opt/tbros/humble
    #   - lookup paths keep the humble-jammy underlay at /opt/ros/humble
    #     (CMAKE_PREFIX_PATH / AMENT_PREFIX_PATH / PKG_CONFIG_PATH / setup.sh).
    #     A blanket prefix rewrite made cmake look only in /opt/tbros/humble,
    #     where ament_cmake is not installed — OBS then failed every cmake
    #     package with "Could not find ament_cmake".
    local ros_name tb_name
    ros_name="ros-humble-$(echo "${pkg}" | tr '_' '-')"
    tb_name="tbros-humble-$(echo "${pkg}" | tr '_' '-')"
    sed -i "s|${ros_name}|${tb_name}|g" debian/changelog debian/control debian/rules
    sed -i "s|/opt/ros/humble|/opt/tbros/humble|g" debian/rules
    # Restore underlay on search paths. CMAKE_* lists are semicolon-separated
    # (cmake), PKG_CONFIG_PATH is colon-separated (unix). Source underlay
    # setup.sh first so PYTHONPATH/ament env exist even before ros-workspace
    # has produced /opt/tbros/humble/setup.sh.
    sed -i \
      -e 's|-DAMENT_PREFIX_PATH="/opt/tbros/humble"|-DAMENT_PREFIX_PATH="/opt/tbros/humble;/opt/ros/humble"|g' \
      -e 's|-DCMAKE_PREFIX_PATH="/opt/tbros/humble"|-DCMAKE_PREFIX_PATH="/opt/tbros/humble;/opt/ros/humble"|g' \
      -e 's|export PKG_CONFIG_PATH=/opt/tbros/humble/lib/pkgconfig|export PKG_CONFIG_PATH=/opt/tbros/humble/lib/pkgconfig:/opt/ros/humble/lib/pkgconfig|g' \
      -e 's|if \[ -f "/opt/tbros/humble/setup.sh" \]; then \. "/opt/tbros/humble/setup.sh"; fi|if [ -f "/opt/ros/humble/setup.sh" ]; then . "/opt/ros/humble/setup.sh"; fi; if [ -f "/opt/tbros/humble/setup.sh" ]; then . "/opt/tbros/humble/setup.sh"; fi|g' \
      debian/rules
    # ros_workspace is the overlay bootstrap: it cannot source setup.sh yet
    # (that file is what this package generates). Official Humble debian/rules
    # sets PYTHONPATH to the underlay site-packages for the same reason.
    if [[ "${pkg}" == "ros_workspace" ]]; then
      sed -i '/^DEB_HOST_GNU_TYPE /a\
\
# Needed to bootstrap since the ros_workspace package does not yet exist.\
# noble underlay is python3.12, jammy python3.10; extra dirs are harmless.\
export PYTHONPATH=/opt/ros/humble/lib/python3.12/site-packages:/opt/ros/humble/lib/python3.10/site-packages:/opt/ros/humble/lib/python3.9/site-packages
' debian/rules
    fi
    # performance_test/plugins/ros2/plugin_factory.cpp pushes cc1plus past
    # 5.8 GB RSS at -O2 and gets OOM-killed on the OBS build VMs (make -j1
    # already). Aggressive ggc keeps the -O2 output while roughly halving
    # peak memory.
    if [[ "${pkg}" == "performance_test" ]]; then
      local ggc="--param ggc-min-expand=10 --param ggc-min-heapsize=32768"
      if [[ "${DISTRO}" != "jammy" ]]; then
        # noble build workers have ~3 GB RAM; jammy's halving is not enough there
        ggc="--param ggc-min-expand=5 --param ggc-min-heapsize=8192"
      fi
      sed -i "s|^export DEB_CXXFLAGS_MAINT_APPEND=-DNDEBUG\$|export DEB_CXXFLAGS_MAINT_APPEND=-DNDEBUG ${ggc}|" debian/rules
    fi
    # Traceability: record the source commit in the deb metadata.
    #   XS-Source-Commit in debian/control → dpkg-source copies it into the
    #     .dsc (as "Source-Commit", the XS- prefix is stripped) and it also
    #     travels inside the .debian.tar.xz
    #   extended Description line          → carried into the binary deb
    # Dirty trees get a -dirty suffix. Only the package's own repo counts:
    # non-git sources (e.g. hand-created meta packages) record "unknown".
    local git="git -c safe.directory=*"
    local commit="unknown"
    if [[ -d "${dir}/.git" ]]; then
      commit="$(${git} -C "${dir}" rev-parse --short HEAD 2>/dev/null || echo unknown)"
      if [[ "${commit}" != "unknown" && -n "$(${git} -C "${dir}" status --porcelain 2>/dev/null)" ]]; then
        commit="${commit}-dirty"
      fi
    fi
    sed -i "/^Source: /a XS-Source-Commit: ${commit}" debian/control
    sed -i "/^Description: /a\\ Source-Commit: ${commit}" debian/control
    # 3.0 (quilt) needs the upstream tarball to exist; synthesize it from the
    # tree (minus debian/) using the changelog's source name + upstream version.
    #
    # The tarball MUST be byte-reproducible: jammy and noble variants of one
    # package share the same orig filename (`<src>_<upstream-ver>.orig.tar.gz`)
    # and both publish into the same aptly pool, so any embedded variance
    # (file mtimes, owners, permission bits, directory order) makes them
    # "same name, different content" and aptly refuses to link the second one
    # — which fails obs-aptly-on-publish.sh and wedges the whole publisher.
    # Note --mode: the two build containers run with different umasks
    # (jammy produces 0666/0777, noble 0644/0755), so modes must be normalized
    # too; `X` keeps the executable bit on scripts.
    local src_name up_ver
    src_name="$(dpkg-parsechangelog -l debian/changelog -S Source)"
    up_ver="$(dpkg-parsechangelog -l debian/changelog -S Version)"
    up_ver="${up_ver%%-*}"
    tar --sort=name --mtime="@${SOURCE_DATE_EPOCH:-0}" \
      --owner=0 --group=0 --numeric-owner \
      --mode='u+rwX,go+rX,go-w' \
      --exclude=./debian --exclude-vcs \
      --transform="s,^\.,${src_name}-${up_ver}," \
      -czf "${OUT_DIR}/.work/${src_name}_${up_ver}.orig.tar.gz" .
    dpkg-source -b . >/dev/null
    # Version management: tag the .dsc for OBS's OBS-DCH-RELEASE mechanism —
    # the worker appends "+<obs-release>" to the changelog version, so every
    # OBS build publishes a unique, monotonically increasing version (apt
    # clients always see an upgrade, even when the source itself is unchanged).
    # The tag must go into the .dsc itself: dpkg-source title-cases control
    # fields ("Obs-Dch-Release") which OBS's case-sensitive grep would miss.
    sed -i "/^Format: /a OBS-DCH-RELEASE: 1" "${OUT_DIR}/.work/${src_name}_"*.dsc
  ) || return 1
  mv -f "${OUT_DIR}/.work"/*.dsc "${OUT_DIR}/.work"/*.tar.* "${OUT_DIR}/"
  rm -rf "${work}"
}

ensure_bloom
ensure_rosdep
gen_distro_rosdep_overlay
mkdir -p "${OUT_DIR}"

rc=0
failed=()
if [[ -n "${PKG}" ]]; then
  match="$(collect_pkgs | awk -v p="${PKG}" '$1 == p || $2 ~ ("/" p "$") {print}')"
  if [[ -z "${match}" ]]; then
    log "ERROR: package not found under src/ or tools/packages/: ${PKG}"
    exit 1
  fi
  # shellcheck disable=SC2086
  package_one ${match}
else
  while read -r name dir; do
    [[ -n "${name}" ]] || continue
    package_one "${name}" "${dir}" || {
      rc=1
      failed+=("${name}")
    }
  done < <(collect_pkgs)
fi

if [[ "${rc}" == "0" ]]; then
  log "artifacts in ${OUT_DIR}:"
  ls -1 "${OUT_DIR}" | grep -E '\.(dsc|tar\.[a-z0-9]+)$' | sed 's/^/    /'
else
  log "FAILED packages: ${failed[*]}"
fi
exit "${rc}"
