#!/usr/bin/env bash
#
# 用法:
#   sudo bash topsbot_ws/tools/sysroot_apt.sh update
#   sudo bash topsbot_ws/tools/sysroot_apt.sh install xxx
#   sudo bash topsbot_ws/tools/sysroot_apt.sh repair
#   sudo bash topsbot_ws/tools/sysroot_apt.sh shell
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CC_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SYSROOT="${CC_ROOT}/topsbot_sysroot"
CHROOT="${SYSROOT}/.chroot"
USR="${SYSROOT}/usr"
ETC="${SYSROOT}/etc"
OPT="${SYSROOT}/opt"
VAR="${SYSROOT}/var"

CHROOT_STATE="${SYSROOT}/.chroot_mounted"
LINK_BASELINE="${SYSROOT}/.topsbot/link_baseline"

CROSS_LINK_PATHS=(
  "etc/alternatives/liblapack.so.3-riscv64-linux-gnu"
  "etc/alternatives/libblas.so.3-riscv64-linux-gnu"
  "usr/lib/riscv64-linux-gnu/liblapack.so.3"
  "usr/lib/riscv64-linux-gnu/libblas.so.3"
)

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "[ERROR] apt 需要 root（容器内 root 或 sudo）"
    exit 1
  fi
}

require_sysroot_base() {
  if [[ ! -d "${USR}/bin" ]]; then
    echo "[ERROR] 未找到 ${USR}"
    exit 1
  fi
  if [[ ! -f "${ETC}/apt/sources.list" ]]; then
    echo "[ERROR] 未找到 ${ETC}/apt/sources.list，请先同步板端 sysroot"
    exit 1
  fi
}

setup_qemu_binfmt() {
  if [[ -x /usr/bin/qemu-riscv64-static ]]; then
    mkdir -p "${USR}/bin"
    if [[ ! -f "${USR}/bin/qemu-riscv64-static" ]]; then
      cp -a /usr/bin/qemu-riscv64-static "${USR}/bin/qemu-riscv64-static"
    fi
  fi
  if command -v update-binfmts >/dev/null 2>&1; then
    update-binfmts --enable qemu-riscv64 >/dev/null 2>&1 || true
  fi
}

fix_sysroot_ownership() {
  [[ "${EUID}" -eq 0 ]] || return 0
  local uid gid
  if [[ -n "${SUDO_UID:-}" && -n "${SUDO_GID:-}" ]]; then
    uid="${SUDO_UID}" gid="${SUDO_GID}"
  elif stat -c '%u' "${CC_ROOT}" >/dev/null 2>&1; then
    uid="$(stat -c '%u' "${CC_ROOT}")"
    gid="$(stat -c '%g' "${CC_ROOT}")"
  else
    return 0
  fi
  [[ -n "${uid:-}" && "${uid}" != "0" ]] || return 0
  chown -R "${uid}:${gid}" "${USR}" "${OPT}" "${VAR}" 2>/dev/null || true
}

ensure_chroot_runtime() {
  mkdir -p "${CHROOT}/run" "${CHROOT}/tmp"
  chmod 1777 "${CHROOT}/tmp" 2>/dev/null || true
}

ensure_dpkg_status() {
  if [[ -s "${VAR}/lib/dpkg/status" ]]; then
    return 0
  fi
  echo "[ERROR] 缺少 ${VAR}/lib/dpkg/status"
  exit 1
}

mount_bind() {
  local src="$1" dst="$2"
  mkdir -p "${src}" "${dst}"
  if mountpoint -q "${dst}" 2>/dev/null; then
    return 0
  fi
  mount --bind "${src}" "${dst}"
}

chroot_is_mounted() {
  [[ -f "${CHROOT_STATE}" ]] && mountpoint -q "${CHROOT}/usr" 2>/dev/null
}

chroot_prepare() {
  require_root
  require_sysroot_base
  setup_qemu_binfmt
  ensure_chroot_runtime
  ensure_dpkg_status

  if chroot_is_mounted; then
    return 0
  fi

  mkdir -p "${CHROOT}"/{proc,sys,dev,dev/pts,run,tmp}

  mount_bind "${USR}" "${CHROOT}/usr"
  mount_bind "${ETC}" "${CHROOT}/etc"
  mount_bind "${OPT}" "${CHROOT}/opt"
  mount_bind "${VAR}" "${CHROOT}/var"

  ln -sfn usr/bin "${CHROOT}/bin"
  ln -sfn usr/sbin "${CHROOT}/sbin"
  ln -sfn usr/lib "${CHROOT}/lib"
  ln -sfn usr/lib64 "${CHROOT}/lib64" 2>/dev/null || true

  mount -t proc proc "${CHROOT}/proc"
  mount -t sysfs sysfs "${CHROOT}/sys"
  mount --bind /dev "${CHROOT}/dev"
  if [[ -d /dev/pts ]]; then
    mkdir -p "${CHROOT}/dev/pts"
    mount --bind /dev/pts "${CHROOT}/dev/pts"
  fi
  if [[ -d /run ]]; then
    mount_bind /run "${CHROOT}/run"
  fi
  mount -t tmpfs tmpfs "${CHROOT}/tmp" 2>/dev/null || mount_bind "${VAR}/tmp" "${CHROOT}/tmp"

  if [[ -f /etc/resolv.conf ]]; then
    cp /etc/resolv.conf "${CHROOT}/etc/resolv.conf"
  fi

  date -Iseconds > "${CHROOT_STATE}"
}

chroot_teardown() {
  require_root
  if ! chroot_is_mounted; then
    return 0
  fi

  local mounts=(
    "${CHROOT}/tmp"
    "${CHROOT}/run"
    "${CHROOT}/dev/pts"
    "${CHROOT}/dev"
    "${CHROOT}/sys"
    "${CHROOT}/proc"
    "${CHROOT}/var"
    "${CHROOT}/opt"
    "${CHROOT}/etc"
    "${CHROOT}/usr"
  )
  for m in "${mounts[@]}"; do
    if mountpoint -q "${m}" 2>/dev/null; then
      umount -l "${m}" 2>/dev/null || umount "${m}" 2>/dev/null || true
    fi
  done
  rm -f "${CHROOT_STATE}"
}

chroot_run() {
  chroot_prepare
  local cmd=("$@")
  echo "==> chroot ${CHROOT}: ${cmd[*]}"
  chroot "${CHROOT}" env DEBIAN_FRONTEND=noninteractive "${cmd[@]}"
}

restore_link_baseline() {
  if [[ ! -d "${LINK_BASELINE}" ]]; then
    echo "[WARN] 未找到 link baseline: ${LINK_BASELINE}"
    return 0
  fi

  echo "==> 从 baseline 恢复交叉编译软链"
  local restored=0
  for rel in "${CROSS_LINK_PATHS[@]}"; do
    local bak="${LINK_BASELINE}/${rel}"
    local dst="${SYSROOT}/${rel}"
    if [[ ! -L "${bak}" && ! -f "${bak}" ]]; then
      echo "[WARN] baseline 缺少: ${rel}"
      continue
    fi

    if [[ -L "${dst}" ]]; then
      local cur ref
      cur="$(readlink -n "${dst}")"
      ref="$(readlink -n "${bak}")"
      if [[ "${cur}" == "${ref}" ]]; then
        continue
      fi
      echo "  恢复 ${rel}: ${cur} -> ${ref}"
    elif [[ -e "${dst}" ]]; then
      echo "  恢复 ${rel}（当前非预期软链）"
    fi

    mkdir -p "$(dirname "${dst}")"
    rm -f "${dst}"
    cp -a "${bak}" "${dst}"
    restored=$((restored + 1))
  done
  echo "  已恢复 ${restored} 项"
}

post_apt_refresh() {
  restore_link_baseline
  fix_sysroot_ownership
}

usage() {
  cat <<EOF
用法: sudo bash $0 <command> [args...]

  update              apt-get update
  install <pkg>...    apt-get install -y
  remove <pkg>...     apt-get remove -y
  repair              dpkg --configure -a && apt-get install -f
  shell               进入 chroot bash
EOF
  exit 1
}

trap 'chroot_teardown 2>/dev/null || true' EXIT

main() {
  [[ $# -ge 1 ]] || usage

  local cmd="$1"
  shift

  case "${cmd}" in
    update)
      chroot_run /usr/bin/apt-get update
      post_apt_refresh
      ;;
    install)
      [[ $# -ge 1 ]] || { echo "请指定包名"; exit 1; }
      chroot_run /usr/bin/apt-get install -y --no-install-recommends "$@"
      post_apt_refresh
      ;;
    remove)
      [[ $# -ge 1 ]] || { echo "请指定包名"; exit 1; }
      chroot_run /usr/bin/apt-get remove -y "$@"
      post_apt_refresh
      ;;
    repair)
      chroot_prepare
      chroot_run /usr/bin/dpkg --configure -a
      chroot_run /usr/bin/apt-get install -f -y
      post_apt_refresh
      ;;
    shell)
      chroot_prepare
      trap - EXIT
      chroot "${CHROOT}" /bin/bash
      chroot_teardown
      ;;
    -h|--help|help)
      usage
      ;;
    *)
      echo "[ERROR] 未知命令: ${cmd}"
      usage
      ;;
  esac
}

main "$@"
