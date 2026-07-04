#!/bin/bash

IMAGE_NAME="topsbot_riscv64_cross_build"
IMAGE_TAG="latest"
LOCAL_IMAGE="${IMAGE_NAME}:${IMAGE_TAG}"
REMOTE_IMAGE="swr.cn-north-4.myhuaweicloud.com/topsfuture/${IMAGE_NAME}:${IMAGE_TAG}"

FORCE_UPDATE=false
FORCE_SYSROOT=false
for arg in "$@"; do
    case "$arg" in
        --update) FORCE_UPDATE=true ;;
        --update-sysroot) FORCE_SYSROOT=true ;;
    esac
done

# 检查本地是否存在指定 tag 的镜像
image_check=$(docker images --format "{{.Repository}}:{{.Tag}}" | grep -x "${LOCAL_IMAGE}")

# 若指定 --update 或不存在则重新拉取
if [ "$FORCE_UPDATE" = true ] || [ -z "$image_check" ]; then
    if [ "$FORCE_UPDATE" = true ]; then
        echo "检测到 --update，删除本地 ${IMAGE_NAME} 镜像后重新拉取..."
        docker rmi -f "${LOCAL_IMAGE}" 2>/dev/null
        docker rmi -f "${REMOTE_IMAGE}" 2>/dev/null
    else
        echo "本地未找到 ${LOCAL_IMAGE} 镜像，开始下载..."
    fi

    # 下载镜像
    docker login -u cn-north-4@HPUATZQ24NBWKCDANIVQ -p c800890a4405012f5ac173a5858c9a232c380ea80187b15d79cbdba1e9a1ef91 swr.cn-north-4.myhuaweicloud.com
    docker pull "${REMOTE_IMAGE}"
    if [ $? -ne 0 ]; then
        echo "下载镜像失败，请检查网络或镜像地址。"
        exit 1
    fi
    echo "镜像下载成功，开始重命名..."
    # 重命名镜像
    docker tag "${REMOTE_IMAGE}" "${LOCAL_IMAGE}"
    if [ $? -ne 0 ]; then
        echo "重命名镜像失败。"
        exit 1
    fi
    # 删除原镜像
    docker rmi "${REMOTE_IMAGE}"
    if [ $? -ne 0 ]; then
        echo "删除原镜像失败。"
        exit 1
    fi
else
    echo "本地已存在 ${LOCAL_IMAGE} 镜像，无需下载。"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 默认挂载 topsbot_cc 到容器 /mnt/topsbot_cc
CC_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

sysroot_args=()
if [[ "${FORCE_SYSROOT}" == true ]]; then
  sysroot_args+=(--force)
fi
bash "${SCRIPT_DIR}/download_sysroot.sh" "${sysroot_args[@]}"

CONTAINER_CC="/mnt/topsbot_cc"
CONTAINER_NAME="topsbot-cross-build-$(date +%Y%m%d%H%M%S)-$(shuf -i 1000-9999 -n 1)"

echo "每次启动都创建新的Docker容器，容器将在退出时自动删除..."
echo "正在创建新容器: $CONTAINER_NAME"

docker run -it --rm \
  --name "${CONTAINER_NAME}" \
  --privileged \
  --entrypoint /bin/bash \
  -v "${CC_ROOT}:${CONTAINER_CC}" \
  -v "${CC_ROOT}/topsbot_sysroot/opt/ros:/opt/ros:ro" \
  -w "${CONTAINER_CC}/topsbot_ws" \
  "${LOCAL_IMAGE}"
