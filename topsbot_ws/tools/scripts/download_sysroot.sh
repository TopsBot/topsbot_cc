#!/usr/bin/env bash
#
# 下载并解压 sysroot。地址和目录由 board JSON 经 tb 注入，本脚本不写死默认值。
#
# 用法:
#   bash topsbot_ws/tools/scripts/download_sysroot.sh              # 缺 tgz 则下载，缺 sysroot 则解压
#   bash topsbot_ws/tools/scripts/download_sysroot.sh --force      # 强制重新下载并解压
#   bash topsbot_ws/tools/scripts/download_sysroot.sh --extract-only   # 仅解压已有 tgz
#   bash topsbot_ws/tools/scripts/download_sysroot.sh --debug
#
# 环境变量: TOPSBOT_SYSROOT_URL / DIR / FILE / VARIANT（tb update sysroot 注入）
#   DIR 必填；URL 仅在需要下载时必填。

set -euo pipefail

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CC_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

TOPSBOT_SYSROOT_URL="${TOPSBOT_SYSROOT_URL:-${TB_SYSROOT_URL:-}}"
VARIANT="${TOPSBOT_SYSROOT_VARIANT:-${TB_SYSROOT_VARIANT:-}}"
FILE_PAT="${TOPSBOT_SYSROOT_FILE:-${TB_SYSROOT_FILE:-}}"
_RAW_DIR="${TOPSBOT_SYSROOT_DIR:-${TB_SYSROOT_DIR:-}}"
if [[ -z "${_RAW_DIR}" ]]; then
    echo "[ERROR] TOPSBOT_SYSROOT_DIR is required (set sysroot.dir in the board JSON)" >&2
    exit 1
fi
if [[ "${_RAW_DIR}" != /* ]]; then
    SYSROOT="${CC_ROOT}/${_RAW_DIR}"
else
    SYSROOT="${_RAW_DIR}"
fi
# Tarball under sysroot/archives/, named after the extract dir's basename
# (从 JSON dir 推出，不写死 jammy/noble 名）。
DEFAULT_ARCHIVE="${CC_ROOT}/sysroot/archives/$(basename "${SYSROOT}").tar.gz"
ARCHIVE=""

DEBUG="false"
FORCE=false
EXTRACT_ONLY=false
DOWNLOAD_ONLY=false

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
    echo "Usage: $0 [--force] [--extract-only] [--download-only] [--debug]"
    echo "  download the sysroot tarball and extract it to ${SYSROOT}/"
    echo "  env: TOPSBOT_SYSROOT_URL / DIR / FILE / VARIANT"
    echo "  --force         remove the existing tarball and sysroot, then re-download and extract"
    echo "  --extract-only  extract the local tarball only, no download"
    echo "  --download-only download the tarball only, do not extract"
    exit 1
}

resolve_sysroot_archive() {
    if [[ -f "${DEFAULT_ARCHIVE}" ]]; then
        ARCHIVE="${DEFAULT_ARCHIVE}"
        return 0
    fi
    ARCHIVE=""
    return 1
}

remove_sysroot_archives() {
    rm -f "${DEFAULT_ARCHIVE}"
}

sysroot_ready() {
    [[ -d "${SYSROOT}/usr/bin" ]] &&
        { [[ -d "${SYSROOT}/opt/tbros" ]] || [[ -d "${SYSROOT}/opt/ros" ]]; }
}

while [[ $# -gt 0 ]]; do
    case "$1" in
    --debug) DEBUG="true" ;;
    --force) FORCE=true ;;
    --extract-only) EXTRACT_ONLY=true ;;
    --download-only) DOWNLOAD_ONLY=true ;;
    -h | --help) usage ;;
    *)
        log_error "unknown argument: $1"
        usage
        ;;
    esac
    shift
done

res=$(which wget)
if [ $? != 0 ]; then
    log_error "Please install wget on your system!"
    exit 1
fi

res=$(which unzip)
if [ $? != 0 ]; then
    log_error "Please install unzip on your system!"
    exit 1
fi

res=$(which curl)
if [ $? != 0 ]; then
    log_error "Please install curl on your system!"
    exit 1
fi

res=$(which jq)
if [ $? != 0 ]; then
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
        local pick file_id file_name
        pick=$(echo "$response_body" | jq -c --arg file "${FILE_PAT}" --arg variant "${VARIANT}" '
            def glob2re:
              gsub("\\\\"; "\\\\") | gsub("\\."; "\\.") | gsub("\\*"; ".*") | gsub("\\?"; ".");
            .items
            | map(select((.type // "file") != "folder"))
            | if $file != "" then
                map(select(.name | test($file | glob2re)))
              elif $variant != "" then
                (map(select(.name | ascii_downcase | contains($variant | ascii_downcase)))) as $m
                | if ($m | length) > 0 then $m
                  elif length == 1 then .
                  else []
                  end
              else . end
            | sort_by(.name)
            | if length == 0 then empty else .[-1] end
        ')
        if [[ -n "$pick" && "$pick" != "null" ]]; then
            file_id=$(echo "$pick" | jq -r '.file_id')
            file_name=$(echo "$pick" | jq -r '.name')
            if [ "$file_id" != "null" ] && [ -n "$file_id" ]; then
                log_info "Share file: ${file_name}"
                log_debug "Found file: $file_name with ID: $file_id"
                echo "$file_id"
                return 0
            fi
        fi
        log_error "No matching file in share (file=${FILE_PAT:-none} variant=${VARIANT:-none})"
        echo "$response_body" | jq -r '.items[]? | "  - \(.name)"' >&2 || true
        return 1
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
        log_error "archive not found: ${DEFAULT_ARCHIVE}"
        exit 1
    fi

    if [[ -d "${SYSROOT}/usr/bin" ]] && [[ "${FORCE}" != true ]]; then
        log_info "${SYSROOT} exists; skipping extraction (use --force to re-extract)"
        return 0
    fi

    # Only a non-empty incomplete tree needs --force (could be a hand-maintained
    # dir-only sysroot). An empty dir is safe to extract into — dockerd
    # auto-creates missing bind-mount sources, leaving exactly that behind.
    if [[ -d "${SYSROOT}" ]] && [[ -n "$(ls -A "${SYSROOT}" 2>/dev/null)" ]] && [[ "${FORCE}" != true ]]; then
        log_error "${SYSROOT} exists but is incomplete; verify it, then re-extract with --force"
        exit 1
    fi
    if [[ "${FORCE}" == true ]]; then
        log_info "--force: removing existing ${SYSROOT}"
        rm -rf "${SYSROOT}"
    fi

    log_info "extracting ${ARCHIVE} -> ${SYSROOT} ..."
    # Detect archive layout from the first entry only: old tarballs wrap
    # content under a single top-level dir, new ones are flattened. tar
    # stops early via SIGPIPE (head closes the pipe).
    top="$( (tar tzf "${ARCHIVE}" 2>/dev/null | head -1 | cut -d/ -f1) || true)"
    mkdir -p "${SYSROOT}"
    case "${top}" in
    . | usr | lib | bin | etc | opt | var | root | sbin | home | media | mnt | srv)
        tar -xzf "${ARCHIVE}" -C "${SYSROOT}"
        ;;
    *)
        tar -xzf "${ARCHIVE}" --strip-components=1 -C "${SYSROOT}"
        ;;
    esac

    if [[ ! -d "${SYSROOT}/usr/bin" ]] ||
        { [[ ! -d "${SYSROOT}/opt/tbros" ]] && [[ ! -d "${SYSROOT}/opt/ros" ]]; }; then
        log_error "extraction finished but the sysroot is incomplete; check the archive contents"
        exit 1
    fi
}

download_sysroot_archive() {
    if [[ -z "${TOPSBOT_SYSROOT_URL}" ]]; then
        log_error "sysroot.url is empty; set it in the board JSON to download"
        exit 1
    fi
    log_info "cc root dir: ${CC_ROOT}"
    log_info "Downloading sysroot (variant=${VARIANT:-none}) from ${TOPSBOT_SYSROOT_URL}"
    mkdir -p "$(dirname "${DEFAULT_ARCHIVE}")"
    # Aliyun share links carry a /s/<share_id> segment + domainId (both are
    # required by the share-API flow); anything else is a plain direct URL.
    if [[ "${TOPSBOT_SYSROOT_URL}" =~ /s/[a-zA-Z0-9]+(\?|$) && "${TOPSBOT_SYSROOT_URL}" =~ domainId= ]]; then
        TOPSBOT_SYSROOT_FILE_ID=$(get_auto_file_id "$TOPSBOT_SYSROOT_URL" "sysroot")
        download_aliyun_file "$TOPSBOT_SYSROOT_URL" "$TOPSBOT_SYSROOT_FILE_ID" "${DEFAULT_ARCHIVE}" || {
            log_error "sysroot download failed"
            exit 1
        }
    else
        # -f: fail on HTTP errors instead of saving the error page;
        # -C -: resume a partial download; --retry: transient 5xx/timeouts
        curl -fL --retry 3 --retry-delay 2 -C - -o "${DEFAULT_ARCHIVE}" "${TOPSBOT_SYSROOT_URL}" || {
            log_error "sysroot download failed"
            exit 1
        }
    fi
    ARCHIVE="${DEFAULT_ARCHIVE}"
    log_success "sysroot downloaded: ${ARCHIVE}"
}

ensure_sysroot() {
    if [[ "${DOWNLOAD_ONLY:-}" == true ]]; then
        # download-only: decide on the tarball, NOT the extracted dir
        resolve_sysroot_archive || download_sysroot_archive
        log_success "download-only: ${ARCHIVE}"
        return 0
    fi

    if sysroot_ready && [[ "${FORCE}" != true ]]; then
        log_info "sysroot ready (${SYSROOT}); skipping download and extraction"
        return 0
    fi

    if [[ "${FORCE}" == true ]]; then
        log_info "--force: removing existing tarball and sysroot"
        remove_sysroot_archives
        rm -rf "${SYSROOT}"
    fi

    if [[ "${EXTRACT_ONLY}" == true ]]; then
        extract_sysroot
        return 0
    fi

    if resolve_sysroot_archive; then
        log_info "local archive exists: ${ARCHIVE}; skipping download"
    elif [[ -n "${TOPSBOT_SYSROOT_URL}" ]]; then
        download_sysroot_archive
    else
        log_error "${SYSROOT} is not ready and sysroot.url is empty"
        exit 1
    fi

    extract_sysroot
}

ensure_sysroot
