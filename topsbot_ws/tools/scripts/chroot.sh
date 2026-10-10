#!/bin/bash
# chroot.sh — enter a chroot shell in /sysroot (host variant sysroot dir).
# Runs inside the privileged build container: mounts proc/sys/dev and adapts
# the usr-merge layout (no top-level /bin) before chroot.
#
#   bash /mnt/topsbot_cc/topsbot_ws/tools/scripts/chroot.sh
set -euo pipefail

SYSROOT="/sysroot"

if [[ ! -d "${SYSROOT}/usr" ]]; then
  echo "[chroot] ERROR: ${SYSROOT} looks empty (missing usr/) — run 'tb update sysroot' first" >&2
  exit 1
fi

# qemu for executing riscv64 ELF inside the chroot (binfmt comes from host kernel)
cp -a /usr/bin/qemu-riscv64-static "${SYSROOT}/usr/bin/" 2>/dev/null || true

# usr-merge layout adaptation (idempotent)
ln -sfn usr/bin "${SYSROOT}/bin"
ln -sfn usr/sbin "${SYSROOT}/sbin"
ln -sfn usr/lib "${SYSROOT}/lib"
ln -sfn usr/lib64 "${SYSROOT}/lib64" 2>/dev/null || true

# runtime dirs + DNS (apt needs writable /tmp and resolv.conf)
mkdir -p "${SYSROOT}/tmp" "${SYSROOT}/run"
chmod 1777 "${SYSROOT}/tmp" 2>/dev/null || true
if [[ -f /etc/resolv.conf ]]; then
  cp -L /etc/resolv.conf "${SYSROOT}/etc/resolv.conf"
fi

# mounts (idempotent, safe to re-enter)
mountpoint -q "${SYSROOT}/proc"     || { mkdir -p "${SYSROOT}/proc";     mount -t proc proc "${SYSROOT}/proc"; }
mountpoint -q "${SYSROOT}/sys"      || { mkdir -p "${SYSROOT}/sys";      mount -t sysfs sysfs "${SYSROOT}/sys"; }
mountpoint -q "${SYSROOT}/dev"      || { mkdir -p "${SYSROOT}/dev";      mount --bind /dev "${SYSROOT}/dev"; }
mountpoint -q "${SYSROOT}/dev/pts"  || { mkdir -p "${SYSROOT}/dev/pts";  mount --bind /dev/pts "${SYSROOT}/dev/pts"; }

echo "[chroot] chroot ${SYSROOT} (type exit to leave; writes persist in the mounted sysroot)"
chroot "${SYSROOT}" /bin/bash

# cleanup (non-fatal)
umount "${SYSROOT}/dev/pts" 2>/dev/null || true
umount "${SYSROOT}/dev"      2>/dev/null || true
umount "${SYSROOT}/sys"      2>/dev/null || true
umount "${SYSROOT}/proc"     2>/dev/null || true
echo "[chroot] left sysroot"