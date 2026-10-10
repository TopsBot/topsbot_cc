#!/usr/bin/env bash
# Build the host cross-compile image for a suite (noble|jammy).
set -euo pipefail
SUITE="${1:-noble}"
case "${SUITE}" in
noble) UBUNTU_VERSION=24.04 ;;
jammy) UBUNTU_VERSION=22.04 ;;
*)
  echo "usage: $0 [noble|jammy]" >&2
  exit 1
  ;;
esac
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE="topsbot_riscv64_cross_build:${SUITE}"
echo "[docker] building ${IMAGE} (ubuntu:${UBUNTU_VERSION})"
exec docker build \
  --build-arg "UBUNTU_VERSION=${UBUNTU_VERSION}" \
  --build-arg "SUITE=${SUITE}" \
  -t "${IMAGE}" \
  "${ROOT}"
