#!/bin/bash
# One-shot --rm cross-build shell. Image and sysroot come from the lunched
# board JSON (via tb.py). Prefer `tb shell --cross` for the persistent container.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CC_ROOT="$(cd "${TOOLS_DIR}/../.." && pwd)"
TB_PY="${SCRIPT_DIR}/tb.py"

if [[ -z "${BUILD_TARGET:-}" ]]; then
  echo "no target selected: run 'lunch' to pick one" >&2
  exit 1
fi

FORCE_UPDATE=false
FORCE_SYSROOT=false
for arg in "$@"; do
  case "$arg" in
  --update) FORCE_UPDATE=true ;;
  --update-sysroot) FORCE_SYSROOT=true ;;
  esac
done

FORCE_UPDATE="${FORCE_UPDATE}" FORCE_SYSROOT="${FORCE_SYSROOT}" python3 - "${TB_PY}" <<'PY'
import importlib.util, os, sys

path = sys.argv[1]
spec = importlib.util.spec_from_file_location("tb", path)
tb = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tb)
cfg = tb.load_active()
if not cfg:
    sys.exit(1)
if tb.update_docker_image(cfg, force=os.environ.get("FORCE_UPDATE") == "true"):
    sys.exit(1)
if tb.update_sysroot(os.environ.get("FORCE_SYSROOT") == "true", cfg):
    sys.exit(1)
PY

eval "$(python3 - "${TB_PY}" <<'PY'
import importlib.util, shlex, sys

path = sys.argv[1]
spec = importlib.util.spec_from_file_location("tb", path)
tb = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tb)
cfg = tb.load_active()
if not cfg:
    sys.exit(1)
print("LOCAL_IMAGE=" + shlex.quote(tb.active_image()))
print("SYSROOT_DIR=" + shlex.quote(tb.sysroot_dir(cfg)))
PY
)"

CONTAINER_CC="/mnt/topsbot_cc"
CONTAINER_NAME="topsbot-cross-build-$(date +%Y%m%d%H%M%S)-$(shuf -i 1000-9999 -n 1)"

SYSROOT_OPT="${SYSROOT_DIR}/opt"
if [[ ! -f "${SYSROOT_OPT}/tbros/humble/setup.bash" && ! -f "${SYSROOT_OPT}/ros/humble/setup.bash" ]]; then
  echo "[ERROR] sysroot ROS not found: opt/tbros/humble or opt/ros/humble"
  exit 1
fi

echo "a fresh Docker container is created on every start and removed on exit..."
echo "creating container: $CONTAINER_NAME"

docker run -it --rm \
  --name "${CONTAINER_NAME}" \
  --privileged \
  --entrypoint /bin/bash \
  -v "${CC_ROOT}:${CONTAINER_CC}" \
  -v "${SYSROOT_DIR}/opt:/opt:ro" \
  -v "${SYSROOT_DIR}:/sysroot" \
  -e TOPSBOT_SYSROOT_PATH=/sysroot \
  -w "${CONTAINER_CC}/topsbot_ws" \
  "${LOCAL_IMAGE}"
