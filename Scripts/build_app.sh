#!/usr/bin/env bash
set -euo pipefail

CONFIGURATION="${1:-debug}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="${ROOT_DIR}/.build/MenuShelf.app"
BINARY_PATH="${ROOT_DIR}/.build/${CONFIGURATION}/MenuShelf"

cd "${ROOT_DIR}"
swift build -c "${CONFIGURATION}"

rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS" "${APP_DIR}/Contents/Resources"
cp "${BINARY_PATH}" "${APP_DIR}/Contents/MacOS/MenuShelf"
cp "${ROOT_DIR}/Resources/Info.plist" "${APP_DIR}/Contents/Info.plist"
cp "${ROOT_DIR}/Resources/MenuShelf.icns" "${APP_DIR}/Contents/Resources/MenuShelf.icns"
printf 'APPL????' > "${APP_DIR}/Contents/PkgInfo"

codesign --force --sign - --entitlements "${ROOT_DIR}/Resources/MenuShelf.entitlements" "${APP_DIR}" >/dev/null
touch "${APP_DIR}"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "${APP_DIR}" >/dev/null 2>&1 || true

printf '%s\n' "Built ${APP_DIR}"
