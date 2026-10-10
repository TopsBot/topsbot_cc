#!/usr/bin/env bash
# deps.sh — resolve workspace package.xml dependencies with rosdep and write
# the apt package list the sysroot must provide. Runs inside the build
# container; invoked from tb.py (ensure_sysroot_deps) before a build.
#
#   bash deps.sh --distro <ubuntu-codename>
#
# Result:
#   .bloom/deps/resolved-<distro>.list   one apt package name per line
#
# Exit 0 when resolution ran (unresolvable keys are warnings, not errors);
# exit 1 only on hard failures (no rosdep env / no cache and no network), in
# which case tb.py skips dependency injection and lets the build proceed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DISTRO=""
while [[ $# -gt 0 ]]; do
  case "$1" in
  --distro)
    DISTRO="${2:?missing distro codename}"
    shift 2
    ;;
  *)
    echo "[deps] unknown argument: $1" >&2
    exit 2
    ;;
  esac
done
if [[ -z "${DISTRO}" ]]; then
  echo "[deps] --distro <ubuntu-codename> is required" >&2
  exit 2
fi

log() { echo "[deps] $*"; }
# Machine-readable progress for tb.py's spinner (stderr keeps stdout clean).
progress() { echo "PROGRESS $*" >&2; }

# Shared rosdep/bloom environment (venv, sources, overlay helpers).
# shellcheck source=rosdep_env.sh
source "${SCRIPT_DIR}/rosdep_env.sh"

OUT_DIR="${STORE}/deps"
OUT_LIST="${OUT_DIR}/resolved-${DISTRO}.list"
STAMP="${OUT_DIR}/stamp-${DISTRO}"

# Content hash of everything that can change the resolved dependency set:
# every package.xml, the project rosdep rules, and the target distro. Uses
# the container's system python3 so the fast path needs no venv.
deps_hash() {
  python3 - "${DISTRO}" "${SRC}" "${PACKAGES}" "${ROSDEP_YAML}" <<'EOF'
import hashlib, os, sys

distro, src, packages, yaml = sys.argv[1:5]
h = hashlib.sha256()
h.update(distro.encode())
paths = []
for base in (src, packages):
    for root, dirs, files in os.walk(base):
        dirs[:] = [d for d in dirs if not d.startswith(".")]
        if "package.xml" in files:
            paths.append(os.path.join(root, "package.xml"))
            dirs[:] = []
paths.sort()
paths.append(yaml)
for p in paths:
    if not os.path.isfile(p):
        continue
    h.update(p.encode())
    with open(p, "rb") as f:
        h.update(f.read())
print(h.hexdigest())
EOF
}

HASH="$(deps_hash)"
if [[ -f "${STAMP}" && -f "${OUT_LIST}" && "$(cat "${STAMP}")" == "${HASH}" ]]; then
  log "dependencies unchanged; skipping resolution"
  exit 0
fi

# Dependency keys that matter for the target sysroot: build/link time only.
# exec_depend is deliberately excluded — the sysroot exists to cross-compile,
# and runtime libraries already come in as dependencies of the -dev packages
# (libfoo-dev Depends: libfooX); test_depend / doc_depend are never needed.
# The tag set lives in the shared comment-safe parser (pkgxml.py).

# All depend keys under src/ + tools/packages, minus the workspace's own
# package names (inter-package deps are built from source, not apt).
collect_dep_keys() {
  local keys pkgs
  keys="$(python3 "${SCRIPT_DIR}/pkgxml.py" dep-keys "${SRC}" "${PACKAGES}" | sort -u)"
  pkgs="$(python3 "${SCRIPT_DIR}/pkgxml.py" list --keep-catkin --name-only "${SRC}" "${PACKAGES}" | sort -u)"
  # both sides sorted with the same collation: comm requires it
  comm -23 <(printf '%s\n' "${keys}") <(printf '%s\n' "${pkgs}")
}

progress "preparing rosdep environment"
ensure_bloom
ensure_rosdep
# ROS keys (rclcpp, ament_cmake, ...) only carry a jammy rule in rosdistro;
# the generated overlay maps them onto ros-humble-* for this distro.
gen_distro_rosdep_overlay

mapfile -t KEYS < <(collect_dep_keys)
if [[ "${#KEYS[@]}" -eq 0 ]]; then
  log "no dependency keys found under src/ and tools/packages/"
  mkdir -p "${OUT_DIR}"
  : >"${OUT_LIST}"
  exit 0
fi

# One rosdep invocation for all keys. Output alternates between an installer
# comment ("#apt") and the resolved packages for the preceding key;
# unresolvable keys go to stderr without aborting the rest.
progress "resolving ${#KEYS[@]} rosdep keys"
RESOLVED_ERR="${OUT_DIR}/resolve-${DISTRO}.err"
mkdir -p "${OUT_DIR}"
set +e
RESOLVED_OUT="$(ROS_DISTRO=humble rosdep resolve "${KEYS[@]}" --os="ubuntu:${DISTRO}" 2>"${RESOLVED_ERR}")"
rc=$?
set -e
if [[ ${rc} -ne 0 && -z "${RESOLVED_OUT}" ]]; then
  log "ERROR: rosdep resolve failed entirely (see ${RESOLVED_ERR})"
  exit 1
fi

PKGS="$(printf '%s\n' "${RESOLVED_OUT}" | awk '
  /^#/ { installer = substr($0, 2); next }
  NF && installer == "apt" { for (i = 1; i <= NF; i++) print $i }
' | sort -u)"

# Non-apt resolutions (e.g. pip) cannot be injected into the sysroot.
NON_APT="$(printf '%s\n' "${RESOLVED_OUT}" | awk '/^#/ { installer = substr($0, 2); next } NF && installer != "apt" { print installer }' | sort -u)"
if [[ -n "${NON_APT}" ]]; then
  log "WARNING: keys resolved to non-apt installers (skipped): $(printf '%s\n' "${NON_APT}" | tr '\n' ' ')"
fi

if grep -qE 'no rosdep rule|Cannot locate' "${RESOLVED_ERR}" 2>/dev/null; then
  log "WARNING: unresolvable rosdep keys (add real system deps to tools/scripts/rosdep/topsbot.yaml):"
  grep -E 'no rosdep rule|Cannot locate' "${RESOLVED_ERR}" | sed 's/^/    /' >&2
fi

printf '%s\n' ${PKGS:+"${PKGS}"} | sed '/^$/d' >"${OUT_LIST}"
printf '%s\n' "${HASH}" >"${STAMP}"
n=$(grep -c . "${OUT_LIST}" || true)
log "resolved ${#KEYS[@]} keys -> ${n} apt packages (${OUT_LIST})"
