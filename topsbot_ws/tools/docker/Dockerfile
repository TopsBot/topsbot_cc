# Host cross-compile image: Ubuntu + gcc-riscv64-linux-gnu + colcon.
# Target sysroot is bind-mounted at /sysroot (not baked in).
#
#   ./build.sh noble    # ubuntu:24.04, gcc 13, glibc 2.39
#   ./build.sh jammy    # ubuntu:22.04, gcc 11, glibc 2.35
ARG UBUNTU_VERSION=24.04
FROM ubuntu:${UBUNTU_VERSION}

ARG UBUNTU_VERSION
ARG SUITE=noble

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8
# pip 23+ (noble) refuses system installs without this; jammy pip ignores it.
ENV PIP_BREAK_SYSTEM_PACKAGES=1

# colcon / vcstool are not in Ubuntu archives.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        git vim wget curl unzip \
        build-essential make cmake ccache pkg-config file rsync xz-utils \
        python3 python3-pip python3-venv python3-dev python3-setuptools \
        python3-numpy python3-lark python3-empy python3-catkin-pkg \
        qemu-user-static \
        gcc-riscv64-linux-gnu \
        g++-riscv64-linux-gnu \
        binutils-riscv64-linux-gnu \
        protobuf-compiler \
    && python3 -m pip install --no-cache-dir colcon-common-extensions vcstool \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

COPY env.sh /etc/profile.d/riscv64-cross-env.sh
RUN chmod 644 /etc/profile.d/riscv64-cross-env.sh

WORKDIR /root

LABEL maintainer="topsbot-cross-build" \
      description="TOPSBOT RISC-V64 cross-compile host toolchain" \
      suite="${SUITE}" \
      base="ubuntu:${UBUNTU_VERSION}"
