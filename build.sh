#!/bin/bash
set -e

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="${PROJECT_DIR}/output"

SNAPSHOT_TARGET="${SNAPSHOT_TARGET:-x86/64}"
SNAPSHOT_BASE_URL="${SNAPSHOT_BASE_URL:-https://downloads.openwrt.org/snapshots/targets/${SNAPSHOT_TARGET}}"

fetch_url() {
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --retry 3 --connect-timeout 20 "$1"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO- "$1"
    else
        echo "curl or wget is required to resolve the SNAPSHOT SDK" >&2
        return 1
    fi
}

resolve_snapshot_sdk() {
    if [ -n "${SNAPSHOT_SDK_URL:-}" ]; then
        printf '%s\n' "${SNAPSHOT_SDK_URL}"
        return 0
    fi

    local sums name
    sums="$(fetch_url "${SNAPSHOT_BASE_URL%/}/sha256sums")" || {
        echo "Failed to download ${SNAPSHOT_BASE_URL%/}/sha256sums" >&2
        return 1
    }

    name="$(printf '%s\n' "${sums}" | awk '{print $2}' | sed 's/^\*//' | grep -E '^openwrt-sdk-.*\.Linux-x86_64\.tar\.(zst|xz)$' | head -n 1)" || true
    if [ -z "${name}" ]; then
        name="$(fetch_url "${SNAPSHOT_BASE_URL%/}/" | grep -oE 'openwrt-sdk-[^"< ]+\.Linux-x86_64\.tar\.(zst|xz)' | head -n 1)" || true
    fi

    if [ -z "${name}" ]; then
        echo "Unable to find an SDK in ${SNAPSHOT_BASE_URL%/}" >&2
        return 1
    fi

    printf '%s/%s\n' "${SNAPSHOT_BASE_URL%/}" "${name}"
}

echo "============================================"
echo "  HostUpdater OpenWrt Package Builder"
echo "============================================"
echo ""
echo "Select build target:"
echo "  1) Stable 24.10.0 (.ipk) - Fast (Tsinghua mirror)"
echo "  2) SNAPSHOT (.apk)       - For OpenWrt 25.12+ (Official server)"
echo ""

# Support command line argument or interactive selection
if [ "$1" = "apk" ] || [ "$1" = "snapshot" ]; then
    CHOICE="2"
elif [ "$1" = "ipk" ] || [ "$1" = "stable" ]; then
    CHOICE="1"
else
    read -p "Enter choice [1-2] (default: 1): " CHOICE
    CHOICE=${CHOICE:-1}
fi

mkdir -p "${OUTPUT_DIR}"

case "${CHOICE}" in
    2)
        SDK_URL="$(resolve_snapshot_sdk)" || {
            echo "SNAPSHOT SDK resolution failed." >&2
            exit 1
        }
        FORMAT="apk"
        echo ""
        echo "Selected: SNAPSHOT (.apk format)"
        echo "Target: ${SNAPSHOT_TARGET}"
        echo "Note: Resolving the current OpenWrt SNAPSHOT SDK (may take a while)"
        ;;
    *)
        SDK_URL="https://mirrors.tuna.tsinghua.edu.cn/openwrt/releases/24.10.0/targets/x86/64/openwrt-sdk-24.10.0-x86-64_gcc-13.3.0_musl.Linux-x86_64.tar.zst"
        FORMAT="ipk"
        echo ""
        echo "Selected: Stable 24.10.0 (.ipk format)"
        echo "Using Tsinghua mirror for fast download"
        ;;
esac

echo "SDK URL: ${SDK_URL}"
echo ""

IMAGE_TAG="hostupdater-builder-${FORMAT}"

docker build \
    --build-arg SDK_URL="${SDK_URL}" \
    -t "${IMAGE_TAG}" "${PROJECT_DIR}"

echo ""
echo "Extracting packages from build container..."

CONTAINER_ID=$(docker create "${IMAGE_TAG}")
docker cp "${CONTAINER_ID}:/build/sdk/bin/." "${OUTPUT_DIR}"
docker rm "${CONTAINER_ID}" > /dev/null

echo ""
echo "============================================"
echo "  Build Complete!"
echo "============================================"
echo ""
echo "Packages are in: ${OUTPUT_DIR}/"
echo ""
find "${OUTPUT_DIR}" -name "*.${FORMAT}" 2>/dev/null | while read f; do
    ls -lh "$f"
done

if ! find "${OUTPUT_DIR}" -name "*.${FORMAT}" -print -quit | grep -q .; then
    echo "No .${FORMAT} package was produced." >&2
    exit 1
fi
echo ""

if [ "${FORMAT}" = "apk" ]; then
    echo "To install on OpenWrt SNAPSHOT (25.12+):"
    echo "  apk add output/hostupdater_*.apk"
else
    echo "To install on OpenWrt 24.10:"
    echo "  opkg install output/hostupdater_*.ipk"
fi
