#!/usr/bin/env bash
#
# 下载并解压 topsbot_sysroot（支持 topsbot_sysroot.tar.gz 或 topsbot_sysroot_*.tar.gz 等）。
#
# 用法:
#   bash topsbot_ws/tools/download_sysroot.sh              # 缺 tgz 则下载，缺 sysroot 则解压
#   bash topsbot_ws/tools/download_sysroot.sh --force      # 强制重新下载并解压
#   bash topsbot_ws/tools/download_sysroot.sh --extract-only   # 仅解压已有 tgz
#   bash topsbot_ws/tools/download_sysroot.sh --debug

set -euo pipefail

TOPSBOT_SYSROOT_URL="https://bj25486.apps.aliyunfile.com/disk/s/rKEhSHhcjZ5?domainId=bj25486"

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CC_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DEFAULT_ARCHIVE="${CC_ROOT}/topsbot_sysroot.tar.gz"
ARCHIVE=""
SYSROOT="${CC_ROOT}/topsbot_sysroot"

DEBUG="false"
FORCE=false
EXTRACT_ONLY=false

# Log functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1" >&2
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1" >&2
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1" >&2
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

log_debug() {
    if [ "$DEBUG" = "true" ]; then
        echo -e "[DEBUG] $1" >&2
    fi
}

usage() {
    echo "Usage: $0 [--force] [--extract-only] [--debug]"
    echo "  下载 topsbot_sysroot*.tar.gz 并解压到 ${SYSROOT}/"
    echo "  本地 tgz 优先 topsbot_sysroot.tar.gz，否则用 topsbot_sysroot_<version>.tar.gz"
    echo "  --force         删除已有 tgz 和 sysroot 后重新下载解压"
    echo "  --extract-only  仅解压本地 tgz，不下载"
    exit 1
}

# 解析本地 sysroot 压缩包：新包名优先，否则取版本号最高的备份包
resolve_sysroot_archive() {
    if [[ -f "${DEFAULT_ARCHIVE}" ]]; then
        ARCHIVE="${DEFAULT_ARCHIVE}"
        return 0
    fi
    shopt -s nullglob
    local candidates=("${CC_ROOT}"/topsbot_sysroot_*.tar.gz)
    shopt -u nullglob
    if [[ ${#candidates[@]} -eq 0 ]]; then
        ARCHIVE=""
        return 1
    fi
    ARCHIVE="$(printf '%s\n' "${candidates[@]}" | sort -V | tail -1)"
    return 0
}

remove_sysroot_archives() {
    rm -f "${DEFAULT_ARCHIVE}"
    shopt -s nullglob
    rm -f "${CC_ROOT}"/topsbot_sysroot_*.tar.gz
    shopt -u nullglob
}

sysroot_ready() {
    [[ -d "${SYSROOT}/usr/bin" ]] && \
    { [[ -d "${SYSROOT}/opt/tbros" ]] || [[ -d "${SYSROOT}/opt/ros" ]]; }
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --debug) DEBUG="true" ;;
        --force) FORCE=true ;;
        --extract-only) EXTRACT_ONLY=true ;;
        -h|--help) usage ;;
        *)
            log_error "未知参数: $1"
            usage
            ;;
    esac
    shift
done

res=$(which wget)
if [ $? != 0 ];
then
    log_error "Please install wget on your system!"
    exit 1
fi

res=$(which unzip)
if [ $? != 0 ];
then
    log_error "Please install unzip on your system!"
    exit 1
fi

res=$(which curl)
if [ $? != 0 ];
then
    log_error "Please install curl on your system!"
    exit 1
fi

res=$(which jq)
if [ $? != 0 ];
then
    log_error "Please install jq on your system!"
    exit 1
fi

parse_share_id() {
    local share_url="$1"

    if [[ "$share_url" =~ /s/([a-zA-Z0-9]+)(\?|$) ]]; then
        local share_id="${BASH_REMATCH[1]}"
        echo "$share_id"
        return 0
    else
        log_error "Unable to parse share_id from the share link"
        return 1
    fi
}

extract_domain() {
    local share_url="$1"

    if [[ "$share_url" =~ domainId=([a-zA-Z0-9]+) ]]; then
        local domain="${BASH_REMATCH[1]}"
        echo "$domain"
        return 0
    fi

    local domain=$(echo "$share_url" | sed -E 's|^https?://||')
    local subdomain=$(echo "$domain" | cut -d'.' -f1)

    if [ -z "$subdomain" ]; then
        log_error "Unable to extract domain from the share link"
        return 1
    fi

    echo "$subdomain"
    return 0
}

get_share_token() {
    local domain="$1"
    local share_id="$2"

    log_debug "Getting x-share-token..."
    log_debug "Getting share token via official API..."

    local api_base="https://${domain}.api.aliyunfile.com"
    local url="${api_base}/v2/share_link/get_share_token"

    local data=$(jq -n --arg share_id "$share_id" '{
        "share_id": $share_id,
        "expire_sec": 7200
    }')

    local headers=(
        "Content-Type: application/json"
        "Accept: application/json"
        "User-Agent: Mozilla/5.0 (X11; Ubuntu; Linux x86_64; rv:136.0) Gecko/20100101 Firefox/136.0"
    )

    log_debug "Calling API: $url"
    log_debug "Request parameters: $data"

    # Use temporary file to store response
    local temp_response=$(mktemp)
    local temp_headers=$(mktemp)

    # POST
    local http_code
    http_code=$(curl -s -o "$temp_response" -w "%{http_code}" -X POST "$url" \
        -H "${headers[0]}" \
        -H "${headers[1]}" \
        -H "${headers[2]}" \
        -d "$data" \
        --dump-header "$temp_headers")

    local response_body
    response_body=$(cat "$temp_response" 2>/dev/null || echo "")
    rm -f "$temp_response" 2>/dev/null
    log_debug "Raw HTTP status code: $http_code"
    # Security check for HTTP status code
    if ! [[ "$http_code" =~ ^[0-9]+$ ]]; then
        log_error "Invalid HTTP status code: $http_code"
        log_debug "Response body: $response_body"
        return 1
    fi

    if [ "$http_code" -eq 200 ]; then
        local share_token=$(echo "$response_body" | jq -r '.share_token')
        if [ "$share_token" != "null" ] && [ -n "$share_token" ]; then
            echo "$share_token"
            return 0
        fi
    fi
    log_error "Failed to get share token"
    return 1
}

# 新增函数：获取文件ID
get_file_id_from_share() {
    local domain="$1"
    local share_id="$2"
    local share_token="$3"

    log_debug "Getting file ID from share..."

    local api_base="https://${domain}.api.aliyunfile.com"
    local url="${api_base}/v2/file/list"

    local data=$(jq -n --arg share_id "$share_id" '{
        "share_id": $share_id,
        "parent_file_id": "root",
        "limit": 100
    }')

    local headers=(
        "x-share-token: $share_token"
        "Content-Type: application/json"
        "Accept: application/json"
        "User-Agent: Mozilla/5.0 (X11; Ubuntu; Linux x86_64; rv:136.0) Gecko/20100101 Firefox/136.0"
    )

    log_debug "Calling list files API: $url"
    log_debug "Request parameters: $data"

    # Use temporary file to store response
    local temp_response=$(mktemp)
    local temp_headers=$(mktemp)

    # POST
    local http_code
    http_code=$(curl  -s -o "$temp_response" -w "%{http_code}" -X POST "$url" \
        -H "${headers[0]}" \
        -H "${headers[1]}" \
        -H "${headers[2]}" \
        -d "$data" \
        --dump-header "$temp_headers")

    local response_body
    response_body=$(cat "$temp_response" 2>/dev/null || echo "")
    rm -f "$temp_response" 2>/dev/null
    log_debug "Raw HTTP status code: $http_code"
    # Security check for HTTP status code
    if ! [[ "$http_code" =~ ^[0-9]+$ ]]; then
        log_error "Invalid HTTP status code: $http_code"
        log_debug "Response body: $response_body"
        return 1
    fi

    if [ "$http_code" -eq 200 ]; then
        local file_id=$(echo "$response_body" | jq -r '.items[0].file_id')
        if [ "$file_id" != "null" ] && [ -n "$file_id" ]; then
            local file_name=$(echo "$response_body" | jq -r '.items[0].name')
            log_debug "Found file: $file_name with ID: $file_id"
            echo "$file_id"
            return 0
        else
            log_error "No files found in the share link"
            return 1
        fi
    fi
    log_error "Failed to get file list"
    return 1
}

# 新增函数：自动获取文件ID
get_auto_file_id() {
    local share_url="$1"
    local file_type="$2"

    log_info "Auto getting $file_type file ID..."

    local share_id=$(parse_share_id "$share_url")
    [ $? -ne 0 ] && return 1

    local domain=$(extract_domain "$share_url")
    [ $? -ne 0 ] && return 1

    local share_token=$(get_share_token "$domain" "$share_id")
    [ $? -ne 0 ] && return 1

    local file_id=$(get_file_id_from_share "$domain" "$share_id" "$share_token")
    [ $? -ne 0 ] && return 1

    echo "$file_id"
    return 0
}

get_download_url() {
    local domain="$1"
    local file_id="$2"
    local share_id="$3"
    local share_token="$4"

    local api_base="https://${domain}.api.aliyunfile.com"
    local url="${api_base}/v2/file/get_download_url"

    local data=$(jq -n --arg share_id "$share_id" --arg file_id "$file_id" '{
        "share_id": $share_id,
        "file_id": $file_id,
        "expire_sec": 7200
    }')
log_debug "share_token:  $share_token"

    local headers=(
        "x-share-token: $share_token"
        "Content-Type: application/json"
        "Accept: application/json,text/plain,*/*"
        "Origin: https://${domain}.apps.aliyunfile.com"
        "Referer: https://${domain}.apps.aliyunfile.com/"
        "User-Agent: Mozilla/5.0 (X11; Ubuntu; Linux x86_64; rv:136.0) Gecko/20100101 Firefox/136.0"
    )

    local temp_response=$(mktemp)
    local temp_headers=$(mktemp)

    log_debug "Sending request to: $url"

    local http_code
    http_code=$(curl --http1.1 -s -o "$temp_response" -w "%{http_code}" -X POST "$url" \
        -H "${headers[0]}" \
        -H "${headers[1]}" \
        -H "${headers[2]}" \
        -H "${headers[3]}" \
        -H "${headers[4]}" \
        -d "$data" \
        --dump-header "$temp_headers")
    local response_body
    response_body=$(cat "$temp_response")

    rm -f "$temp_response" "$temp_headers"
    log_debug "Response status code: $http_code"

    # Security check for HTTP status code
    if ! [[ "$http_code" =~ ^[0-9]+$ ]]; then
        log_error "Invalid HTTP status code: $http_code"
        return 1
    fi
    if [ "$http_code" -eq 200 ]; then
        local download_url=$(echo "$response_body" | jq -r '.url')
        if [ "$download_url" != "null" ] && [ -n "$download_url" ]; then
            echo "$download_url"
            return 0
        fi
    fi

    log_error "Failed to get download URL"
    return 1
}

download_aliyun_file() {
    local share_url="$1"
    local file_id="$2"
    local output="$3"

    log_debug "Starting to process Aliyun download: $share_url"

    local share_id=$(parse_share_id "$share_url")
    [ $? -ne 0 ] && return 1

    local domain=$(extract_domain "$share_url")
    [ $? -ne 0 ] && return 1

    local share_token=$(get_share_token "$domain" "$share_id")
    [ $? -ne 0 ] && return 1

    local download_url=$(get_download_url "$domain" "$file_id" "$share_id" "$share_token")
    [ $? -ne 0 ] && return 1

    log_debug "Starting to download file to: $output"
    curl -L -o "$output" "$download_url"
    if [ $? -eq 0 ]; then
        log_success "Download successful: $output"
        return 0
    else
        log_error "Download failed: $share_url"
        return 1
    fi
}

extract_sysroot() {
    if ! resolve_sysroot_archive; then
        log_error "未找到压缩包: topsbot_sysroot.tar.gz 或 topsbot_sysroot_*.tar.gz"
        exit 1
    fi

    if sysroot_ready && [[ "${FORCE}" != true ]]; then
        log_info "topsbot_sysroot 已存在，跳过解压（使用 --force 可重新解压）"
        return 0
    fi

    if [[ -d "${SYSROOT}" ]]; then
        if [[ "${FORCE}" != true ]]; then
            log_error "${SYSROOT} 存在但不完整，请确认后使用 --force 重新解压"
            exit 1
        fi
        log_info "--force：删除已有 ${SYSROOT}"
        rm -rf "${SYSROOT}"
    fi

    log_info "正在解压 ${ARCHIVE} ..."
    tar -xzf "${ARCHIVE}" -C "${CC_ROOT}"

    if ! sysroot_ready; then
        log_error "解压完成但 sysroot 不完整，请检查压缩包内容"
        exit 1
    fi

    log_success "解压完成: ${SYSROOT}"
}

download_sysroot_archive() {
    log_info "cc root dir: ${CC_ROOT}"
    log_info "Starting to download topsbot_sysroot..."
    TOPSBOT_SYSROOT_FILE_ID=$(get_auto_file_id "$TOPSBOT_SYSROOT_URL" "topsbot_sysroot")
    download_aliyun_file "$TOPSBOT_SYSROOT_URL" "$TOPSBOT_SYSROOT_FILE_ID" "${DEFAULT_ARCHIVE}" || {
        log_error "topsbot_sysroot download failed"
        exit 1
    }
    ARCHIVE="${DEFAULT_ARCHIVE}"
    log_success "topsbot_sysroot downloaded successfully: ${ARCHIVE}"
}

ensure_sysroot() {
    if sysroot_ready && [[ "${FORCE}" != true ]]; then
        log_info "topsbot_sysroot 已就绪，跳过下载和解压"
        return 0
    fi

    if [[ "${FORCE}" == true ]]; then
        log_info "--force：删除已有 tgz 和 sysroot"
        remove_sysroot_archives
        rm -rf "${SYSROOT}"
    fi

    if [[ "${EXTRACT_ONLY}" == true ]]; then
        extract_sysroot
        return 0
    fi

    if resolve_sysroot_archive; then
        log_info "本地已存在 ${ARCHIVE}，跳过下载"
    else
        download_sysroot_archive
    fi

    extract_sysroot
}

ensure_sysroot
