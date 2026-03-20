#!/bin/bash
set -euo pipefail

# ============================================================================
# TransFlow PKG Packaging Script
# 构建、签名、公证并回填可安装到 /Applications 的 PKG 安装包
# ============================================================================

APP_NAME="TransFlow"
SCHEME="TransFlow"
INSTALL_LOCATION="/Applications"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
XCODE_PROJECT="${PROJECT_DIR}/TransFlow/TransFlow.xcodeproj"
BUILD_DIR="${PROJECT_DIR}/build"
PKG_DIR="${BUILD_DIR}/pkg"
APP_PATH="${PKG_DIR}/${APP_NAME}.app"
DEFAULT_ENTITLEMENTS="${PROJECT_DIR}/TransFlow/TransFlow/TransFlow.entitlements"
NOTARY_PROFILE="TransFlowNotary"

CONFIGURATION="Release"
ARCH="$(uname -m)"

APP_SIGN_IDENTITY=""
INSTALLER_SIGN_IDENTITY=""
SIGN_ENTITLEMENTS=""

SKIP_BUILD=false
CLEAN_BUILD=false
SKIP_NOTARIZE=false
OPEN_PKG=false

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --skip-build               跳过 Xcode build，直接打包已有的 .app
  --clean                    clean build（先清理再构建）
  --skip-notarize            跳过 notarization 和 stapling
  --open                     打包完成后自动打开 PKG
  --app-sign ID              指定 Developer ID Application 证书
  --installer-sign ID        指定 Developer ID Installer 证书
  --notary-profile NAME      指定 notarytool keychain profile（默认: TransFlowNotary）
  --entitlements FILE        指定 entitlements plist（默认自动检测）
  -h, --help                 显示帮助

示例:
  ./scripts/build-pkg.sh
  ./scripts/build-pkg.sh --clean
  ./scripts/build-pkg.sh --skip-notarize
  ./scripts/build-pkg.sh \\
    --app-sign "Developer ID Application: Siyuan Li (8RQVLSP2SC)" \\
    --installer-sign "Developer ID Installer: Siyuan Li (8RQVLSP2SC)"
EOF
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --skip-build)
            SKIP_BUILD=true
            shift
            ;;
        --clean)
            CLEAN_BUILD=true
            shift
            ;;
        --skip-notarize)
            SKIP_NOTARIZE=true
            shift
            ;;
        --open)
            OPEN_PKG=true
            shift
            ;;
        --app-sign)
            APP_SIGN_IDENTITY="$2"
            shift 2
            ;;
        --installer-sign)
            INSTALLER_SIGN_IDENTITY="$2"
            shift 2
            ;;
        --notary-profile)
            NOTARY_PROFILE="$2"
            shift 2
            ;;
        --entitlements)
            SIGN_ENTITLEMENTS="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            error "未知参数: $1（使用 --help 查看帮助）"
            ;;
    esac
done

find_app_identity() {
    if [ -n "${APP_SIGN_IDENTITY}" ]; then
        return
    fi

    local identities
    identities=$(security find-identity -v -p codesigning 2>/dev/null || true)
    APP_SIGN_IDENTITY=$(echo "${identities}" | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)".*/\1/' || true)

    if [ -z "${APP_SIGN_IDENTITY}" ]; then
        error "未找到 Developer ID Application 证书，请先在钥匙串中安装后重试"
    fi
}

find_installer_identity() {
    if [ -n "${INSTALLER_SIGN_IDENTITY}" ]; then
        return
    fi

    local identities
    identities=$(security find-identity -v -p basic 2>/dev/null || true)
    INSTALLER_SIGN_IDENTITY=$(echo "${identities}" | grep "Developer ID Installer" | head -1 | sed 's/.*"\(.*\)".*/\1/' || true)

    if [ -z "${INSTALLER_SIGN_IDENTITY}" ]; then
        error "未找到 Developer ID Installer 证书，请先在钥匙串中安装后重试"
    fi
}

resolve_entitlements() {
    local ent_file="${SIGN_ENTITLEMENTS}"

    if [ -z "${ent_file}" ] && [ -f "${DEFAULT_ENTITLEMENTS}" ]; then
        ent_file="${DEFAULT_ENTITLEMENTS}"
    fi

    if [ -z "${ent_file}" ]; then
        error "未找到 entitlements 文件，请使用 --entitlements 指定"
    fi

    if [ ! -f "${ent_file}" ]; then
        error "entitlements 文件不存在: ${ent_file}"
    fi

    SIGN_ENTITLEMENTS="${ent_file}"
}

sign_nested_code() {
    local app_path="$1"
    local sign_args=(--force --options runtime --timestamp --sign "${APP_SIGN_IDENTITY}")

    if [ -d "${app_path}/Contents/Frameworks" ]; then
        info "签名内嵌 Frameworks..."
        find "${app_path}/Contents/Frameworks" \
            \( -name "*.dylib" -o -name "*.framework" -o -name "*.xpc" -o -name "*.appex" -o -name "*.app" \) \
            -depth -print0 2>/dev/null | while IFS= read -r -d '' item; do
            codesign "${sign_args[@]}" "${item}"
        done
    fi

    if [ -d "${app_path}/Contents/Library" ]; then
        info "签名内嵌 Library 组件..."
        find "${app_path}/Contents/Library" \
            \( -name "*.xpc" -o -name "*.appex" -o -name "*.app" \) \
            -depth -print0 2>/dev/null | while IFS= read -r -d '' item; do
            codesign "${sign_args[@]}" "${item}"
        done
    fi

    if [ -d "${app_path}/Contents/MacOS" ]; then
        info "签名辅助可执行文件..."
        find "${app_path}/Contents/MacOS" -type f -perm -111 ! -name "${APP_NAME}" -print0 2>/dev/null | while IFS= read -r -d '' item; do
            codesign "${sign_args[@]}" "${item}"
        done
    fi
}

sign_app() {
    local app_path="$1"

    info "使用 Developer ID Application 签名 .app"
    info "证书: ${APP_SIGN_IDENTITY}"
    info "entitlements: ${SIGN_ENTITLEMENTS}"

    sign_nested_code "${app_path}"

    codesign \
        --force \
        --options runtime \
        --timestamp \
        --entitlements "${SIGN_ENTITLEMENTS}" \
        --sign "${APP_SIGN_IDENTITY}" \
        "${app_path}"

    codesign --verify --strict --verbose=2 "${app_path}"
}

check_notary_profile() {
    if [ "${SKIP_NOTARIZE}" = true ]; then
        return
    fi

    if ! xcrun notarytool history --keychain-profile "${NOTARY_PROFILE}" >/dev/null 2>&1; then
        error "notary profile 不可用: ${NOTARY_PROFILE}。请先运行 xcrun notarytool store-credentials"
    fi
}

notarize_and_staple_pkg() {
    local pkg_path="$1"
    info "提交 PKG 到 Apple notarization..."
    xcrun notarytool submit "${pkg_path}" \
        --keychain-profile "${NOTARY_PROFILE}" \
        --wait

    info "回填 notarization ticket..."
    xcrun stapler staple "${pkg_path}"
    xcrun stapler validate "${pkg_path}"
}

info "检查依赖..."
for tool in xcodebuild productbuild pkgutil codesign xcrun ditto; do
    if ! command -v "${tool}" >/dev/null 2>&1; then
        error "依赖未找到: ${tool}"
    fi
done
success "依赖检查通过"

find_app_identity
find_installer_identity
resolve_entitlements
check_notary_profile

info "Developer ID Application: ${APP_SIGN_IDENTITY}"
info "Developer ID Installer: ${INSTALLER_SIGN_IDENTITY}"
if [ "${SKIP_NOTARIZE}" = false ]; then
    info "notary profile: ${NOTARY_PROFILE}"
fi

info "清理旧的构建产物..."
rm -rf "${PKG_DIR}"
mkdir -p "${PKG_DIR}"

if [ "${CLEAN_BUILD}" = true ]; then
    info "执行 clean build..."
    xcodebuild clean \
        -project "${XCODE_PROJECT}" \
        -scheme "${SCHEME}" \
        -configuration "${CONFIGURATION}" \
        -quiet
fi

if [ "${SKIP_BUILD}" = true ]; then
    info "查找已有 Release 构建..."
    BUILT_APP=$(find "${BUILD_DIR}/DerivedData" ~/Library/Developer/Xcode/DerivedData -path "*/Build/Products/${CONFIGURATION}/${APP_NAME}.app" -type d 2>/dev/null | head -1)
    if [ -z "${BUILT_APP}" ]; then
        error "未找到已构建的 ${APP_NAME}.app，请先构建或去掉 --skip-build"
    fi
else
    info "构建 ${APP_NAME} (${CONFIGURATION}, ${ARCH})..."
    xcodebuild build \
        -project "${XCODE_PROJECT}" \
        -scheme "${SCHEME}" \
        -configuration "${CONFIGURATION}" \
        -arch "${ARCH}" \
        -derivedDataPath "${BUILD_DIR}/DerivedData" \
        -quiet \
        ONLY_ACTIVE_ARCH=NO \
        CODE_SIGN_IDENTITY="-" \
        CODE_SIGNING_REQUIRED=NO \
        CODE_SIGNING_ALLOWED=NO

    BUILT_APP="${BUILD_DIR}/DerivedData/Build/Products/${CONFIGURATION}/${APP_NAME}.app"
fi

if [ ! -d "${BUILT_APP}" ]; then
    error "构建完成但未找到 ${APP_NAME}.app: ${BUILT_APP}"
fi

info "复制 .app 到打包目录..."
ditto "${BUILT_APP}" "${APP_PATH}"

if [ ! -d "${APP_PATH}" ]; then
    error "${APP_NAME}.app 不存在: ${APP_PATH}"
fi

APP_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${APP_PATH}/Contents/Info.plist" 2>/dev/null || echo "1.0.0")
APP_BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "${APP_PATH}/Contents/Info.plist" 2>/dev/null || echo "1")
PKG_FINAL="${BUILD_DIR}/${APP_NAME}-${APP_VERSION}.pkg"

sign_app "${APP_PATH}"

info "生成 PKG 安装包..."
rm -f "${PKG_FINAL}"
productbuild \
    --component "${APP_PATH}" "${INSTALL_LOCATION}" \
    --sign "${INSTALLER_SIGN_IDENTITY}" \
    "${PKG_FINAL}"

pkgutil --check-signature "${PKG_FINAL}"

if [ "${SKIP_NOTARIZE}" = false ]; then
    notarize_and_staple_pkg "${PKG_FINAL}"
    spctl -a -t install -vv "${PKG_FINAL}"
else
    warn "已跳过 notarization；spctl 安装校验会因 Unnotarized Developer ID 失败，故不在此模式执行"
fi

PKG_SIZE=$(du -h "${PKG_FINAL}" | cut -f1 | xargs)

echo ""
echo "============================================"
echo -e "  ${GREEN}${APP_NAME} PKG 打包完成${NC}"
echo "  版本:   ${APP_VERSION} (${APP_BUILD})"
echo "  架构:   ${ARCH}"
echo "  大小:   ${PKG_SIZE}"
echo "  应用签名: ${APP_SIGN_IDENTITY}"
echo "  安装器签名: ${INSTALLER_SIGN_IDENTITY}"
if [ "${SKIP_NOTARIZE}" = false ]; then
    echo "  Notary: ${NOTARY_PROFILE}"
else
    echo "  Notary: 已跳过"
fi
echo "  路径:   ${PKG_FINAL}"
echo "============================================"
echo ""

if [ "${OPEN_PKG}" = true ]; then
    open "${PKG_FINAL}"
fi
