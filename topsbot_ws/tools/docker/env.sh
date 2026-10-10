# RISC-V64 cross-compile env (apt gcc-riscv64-linux-gnu).
# Sysroot is the container mount /sysroot (set by tb); do not default a host path.
export TARGET_ARCH=riscv64
export TARGET_TRIPLE=riscv64-linux-gnu
export CROSS_COMPILE=/usr/bin/${TARGET_TRIPLE}-
