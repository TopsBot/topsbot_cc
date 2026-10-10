#!/usr/bin/env bash
# rosdep_env.sh — shared rosdep/bloom environment for scripts that resolve
# rosdep keys inside the build container (package.sh, deps.sh).
#
# Usage: set DISTRO (ubuntu codename) and optionally REFRESH=1, define log(),
# then source this file. It provides:
#   exports:  ROSDEP_SOURCE_PATH / ROS_HOME / PYTHONDONTWRITEBYTECODE
#   vars:     SCRIPT_DIR TOOLS_DIR WS CC_ROOT SRC PACKAGES STORE ROSDEP_YAML VENV
#   funcs:    ensure_bloom ensure_rosdep resolve_humble_deb gen_distro_rosdep_overlay
#
# Persistent state (host-visible, survives container recreation):
#   .bloom/venv-<distro>/   bloom + rosdep python venv (per host python)
#   .bloom/ros/lists/       rosdep sources (ROSDEP_SOURCE_PATH)
#   .bloom/ros/home/        rosdep cache (ROS_HOME)

: "${DISTRO:?set DISTRO (ubuntu codename) before sourcing rosdep_env.sh}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
WS="$(cd "${TOOLS_DIR}/.." && pwd)"
CC_ROOT="$(cd "${WS}/.." && pwd)"
SRC="${WS}/src"
PACKAGES="${TOOLS_DIR}/packages"
STORE="${CC_ROOT}/.bloom"
ROSDEP_YAML="${SCRIPT_DIR}/rosdep/topsbot.yaml"
# jammy python3.10 vs noble python3.12: one venv cannot serve both (the
# interpreter is a symlink to the container /usr/bin/python3).
VENV="${STORE}/venv-${DISTRO}"

# rosdep hardcodes /etc/ros when running as root; ROSDEP_SOURCE_PATH is the
# only override that works in the container.
export ROSDEP_SOURCE_PATH="${STORE}/ros/lists"
export ROS_HOME="${STORE}/ros/home"
export PYTHONDONTWRITEBYTECODE=1

REFRESH="${REFRESH:-0}"

# Caller may define its own log() before sourcing to keep its prefix.
if ! declare -F log >/dev/null 2>&1; then
  log() { echo "[rosdep] $*"; }
fi

# Progress reporter for slow steps. Callers may override (deps.sh emits
# machine-readable PROGRESS lines for tb.py's spinner); default is a no-op
# so package.sh output stays unchanged.
if ! declare -F progress >/dev/null 2>&1; then
  progress() { :; }
fi

ensure_bloom() {
  if [[ ! -x "${VENV}/bin/bloom-generate" ]] ||
    ! "${VENV}/bin/python3" -c "import rosdep2, bloom" 2>/dev/null; then
    log "installing bloom into ${VENV}"
    progress "installing bloom+rosdep venv"
    rm -rf "${VENV}"
    python3 -m venv "${VENV}"
    "${VENV}/bin/pip" install -q --disable-pip-version-check bloom
  fi
  # bloom spawns its self-update checker as `bloom-update` via /bin/sh, so the
  # venv must be on PATH (otherwise every run prints "bloom-update: not found").
  export PATH="${VENV}/bin:${PATH}"
}

ensure_rosdep() {
  local lists="${ROSDEP_SOURCE_PATH}"
  mkdir -p "${lists}" "${ROS_HOME}"
  # NB: rosdep is first-source-wins (apt-like). Overlay lists must sort
  # before 20-default.list so they beat rosdistro's _is_ros keys.
  # Rewrite missing or stale copies (e.g. paths from before the
  # tools/scripts/ layout change); the overlay must track ROSDEP_YAML.
  if [[ ! -f "${lists}/10-topsbot.list" ]] || ! grep -qF "file://${ROSDEP_YAML}" "${lists}/10-topsbot.list"; then
    echo "yaml file://${ROSDEP_YAML}" >"${lists}/10-topsbot.list"
  fi
  # 50-topsbot.list was the old name: it sorts after 20-default.list, so
  # base.yaml silently won over the project overlay for shared keys (a
  # libopencv-dev -> libtaopencv-dev remap written here would never take
  # effect). Remove it so it cannot linger alongside the 10- copy.
  rm -f "${lists}/50-topsbot.list"
  # fuerte.yaml was removed from rosdistro (HTTP 404); rewrite stale copies.
  if [[ ! -f "${lists}/20-default.list" ]] || grep -q 'fuerte.yaml' "${lists}/20-default.list"; then
    cat >"${lists}/20-default.list" <<'EOF'
# os-specific listings first
yaml https://raw.githubusercontent.com/ros/rosdistro/master/rosdep/osx-homebrew.yaml osx

# generic
yaml https://raw.githubusercontent.com/ros/rosdistro/master/rosdep/base.yaml
yaml https://raw.githubusercontent.com/ros/rosdistro/master/rosdep/python.yaml
yaml https://raw.githubusercontent.com/ros/rosdistro/master/rosdep/ruby.yaml

# Humble+ come from the rosdistro index.yaml, not gbpdistro files here.
EOF
  fi
  local cache_index="${ROS_HOME}/rosdep/sources.cache/index"
  if [[ "${REFRESH}" == "1" || ! -f "${cache_index}" || "${ROSDEP_YAML}" -nt "${cache_index}" ]]; then
    log "rosdep update"
    progress "updating rosdep index"
    # transient network failures are common; retry once, then fall back to the
    # existing cache if there is one
    if ! rosdep update && ! rosdep update && [[ ! -f "${cache_index}" ]]; then
      log "ERROR: rosdep update failed and no cache exists"
      return 1
    fi
  fi
}

# rosdistro's _is_ros keys (ament_cmake, rclcpp, ...) only list Humble on
# jammy, not noble. Overlay every ROS stack key under src/ onto ros-humble-*
# (resolved on jammy, then noble).
#
# rosdep merge is first-source-wins at the OS name, so the overlay must be
# loaded *before* humble/distribution.yaml (00-*.list). Putting it last
# cannot add ubuntu.noble onto an existing ubuntu.jammy rule.
resolve_humble_deb() {
  local key="$1" os out
  for os in "${DISTRO}" jammy noble; do
    out="$(ROS_DISTRO=humble rosdep resolve "${key}" --os="ubuntu:${os}" 2>/dev/null | grep -v '^#' | head -1 || true)"
    case "${out}" in
    ros-humble-*)
      echo "${out}"
      return 0
      ;;
    esac
  done
  return 1
}

gen_distro_rosdep_overlay() {
  local yaml="${STORE}/ros/topsbot-${DISTRO}.yaml"
  local lists="${ROSDEP_SOURCE_PATH}"
  local list="${lists}/00-topsbot-${DISTRO}.list"
  local index="${ROS_HOME}/rosdep/sources.cache/index"
  # Only the lunched distro's overlay may be present: 00-jammy and 00-noble
  # together would let jammy win ubuntu and noble could never merge in.
  rm -f "${lists}"/60-topsbot-*.list
  for f in "${lists}"/00-topsbot-*.list; do
    [[ -e "${f}" && "${f}" != "${list}" ]] && rm -f "${f}"
  done
  local need_gen=0 need_update=0
  # All depend keys across the workspace + the project overlay content: the
  # generated overlay is regenerated whenever either changes (new ROS keys
  # must be mapped, or noble cannot resolve the jammy-only _is_ros rules; a
  # newly mapped key in ROSDEP_YAML must drop its stale ros-humble-* entry).
  local keys keys_hash
  keys="$(
    find "${SRC}" "${PACKAGES}" -name package.xml -not -path "*/.*" -print0 |
      xargs -0 grep -hoE '<[a-z_]*depend[^>]*>[^<]+' |
      sed -E 's/^<[a-z_]*depend[^>]*>//; s/^[[:space:]]+//; s/[[:space:]]+$//' |
      sort -u
  )"
  keys_hash="$({ printf '%s\n' "${keys}"; cat "${ROSDEP_YAML}"; } | sha256sum | cut -d' ' -f1)"
  [[ "${REFRESH}" == "1" || ! -f "${yaml}" ||
    "$(cat "${yaml}.keys" 2>/dev/null)" != "${keys_hash}" ]] && need_gen=1
  [[ ! -f "${list}" ]] && need_update=1
  if [[ -f "${index}" ]] && ! grep -qF "yaml file://${yaml}" "${index}"; then
    need_update=1
  fi
  if [[ "${need_gen}" == "1" ]]; then
    log "generating rosdep overlay for ${DISTRO} (ROS keys -> ros-humble-* debs)"
    local key out i=0 n
    n="$(printf '%s\n' "${keys}" | grep -c . || true)"
    {
      echo "# auto-generated by rosdep_env.sh for distro ${DISTRO} (do not edit)"
      printf '%s\n' "${keys}" |
        while read -r key; do
          [[ -n "${key}" ]] || continue
          i=$((i + 1))
          progress "ROS overlay ${i}/${n} ${key}"
          # Keys mapped by the project-local overlay (ROSDEP_YAML) stay
          # authoritative: this generated file loads first (00-*.list,
          # before 10-topsbot.list), so a ros-humble-* entry here would
          # shadow the project's tbros-humble-* mapping. Bug seen with
          # orbbec_camera_msgs resolving to ros-humble-orbbec-camera-msgs
          # instead of the tbros deb; once cached it also self-perpetuated
          # through resolve_humble_deb during regeneration.
          grep -qxF "${key}:" "${ROSDEP_YAML}" && continue
          out="$(resolve_humble_deb "${key}" || true)"
          # Unversioned ubuntu: first-wins replaces the whole ubuntu mapping
          # (jammy-only _is_ros) for every Ubuntu suite.
          [[ -n "${out}" ]] && printf '%s:\n  ubuntu: [%s]\n' "${key}" "${out}"
        done || true
    } >"${yaml}"
    printf '%s\n' "${keys_hash}" >"${yaml}.keys"
    need_update=1
  fi
  echo "yaml file://${yaml}" >"${list}"
  if [[ "${need_update}" == "1" ]]; then
    log "rosdep update (load ${DISTRO} overlay first)"
    if ! rosdep update && ! rosdep update && [[ ! -f "${index}" ]]; then
      log "ERROR: rosdep update failed after adding ${DISTRO} overlay and no cache exists"
      return 1
    fi
  fi
}
