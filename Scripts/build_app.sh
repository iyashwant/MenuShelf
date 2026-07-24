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

# Copy every SPM-generated resource bundle (Bundle.module backing) into
# the .app root. KeyboardShortcuts, Defaults, and MenuShelf each ship
# their own *.bundle directory next to the binary; without them, the
# first call to `Bundle.module` (e.g. KeyboardShortcuts.Recorder
# loading its localized strings) traps on a fatal assertion.
#
# SPM's generated `resource_bundle_accessor.swift` looks for the
# bundle at `Bundle.main.bundleURL.appendingPathComponent(<name>)`,
# which for an .app resolves to `MenuShelf.app/<name>.bundle` — the
# bundle root, NOT `Contents/Resources/`. Place them accordingly.
BUILD_OUTPUT_DIR="${ROOT_DIR}/.build/${CONFIGURATION}"
for bundle in "${BUILD_OUTPUT_DIR}"/*.bundle; do
  if [ -d "${bundle}" ]; then
    cp -R "${bundle}" "${APP_DIR}/"
  fi
done

# Security-scoped bookmarks (the folders/apps users add) are cryptographically
# bound to the app's code-signing identity. An ad-hoc signature's identity is
# the binary's cdhash, which changes on every build — so each app update
# invalidates every previously stored bookmark and the added folders suddenly
# fail to open ("Folder unavailable / isn't in the correct format"). Signing
# with a STABLE identity (a real certificate) keeps the app's designated
# requirement constant across updates so the bookmarks keep resolving.
#
# Set CODESIGN_IDENTITY to your certificate name (or SHA-1) to pick one
# explicitly, or "-" to force ad-hoc. When unset we auto-detect the first
# available codesigning identity and fall back to ad-hoc (with a warning) only
# when none exists.
SIGN_IDENTITY="${CODESIGN_IDENTITY:-}"
if [ -z "${SIGN_IDENTITY}" ]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | sed -nE 's/^[[:space:]]*[0-9]+\)[[:space:]]+[0-9A-F]+[[:space:]]+"(.*)"$/\1/p' | head -1)"
fi

# The SPM resource bundles (KeyboardShortcuts / Defaults / MenuShelf) must live
# at the .app root — that's where each generated `Bundle.module` accessor looks
# (Bundle.main.bundleURL/<name>.bundle). But codesign refuses to seal anything
# sitting at the bundle root next to Contents/ ("unsealed contents present in
# the bundle root"), so a whole-bundle signature is impossible with this layout.
# Instead we sign the main executable (the Mach-O) directly: the sandbox and the
# security-scoped-bookmark identity both derive from the executable's signature,
# not from the bundle's resource seal. Signing must happen on a copy OUTSIDE the
# bundle, otherwise codesign walks up, detects the .app, and tries to seal it.
#
# --identifier is pinned to the bundle id so the designated requirement stays
# "identifier <bundle-id> and certificate leaf = <cert>" — identical across
# every build, which is exactly what lets old bookmarks keep resolving.
EXEC_PATH="${APP_DIR}/Contents/MacOS/MenuShelf"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${APP_DIR}/Contents/Info.plist" 2>/dev/null || printf 'app.menushelf.MenuShelf')"
TMP_BIN="$(mktemp -t menushelf-exec)"
cp "${EXEC_PATH}" "${TMP_BIN}"

if [ -n "${SIGN_IDENTITY}" ] && [ "${SIGN_IDENTITY}" != "-" ]; then
  printf '%s\n' "Signing executable with stable identity: ${SIGN_IDENTITY} (identifier ${BUNDLE_ID})"
  codesign --force --sign "${SIGN_IDENTITY}" --identifier "${BUNDLE_ID}" --entitlements "${ROOT_DIR}/Resources/MenuShelf.entitlements" "${TMP_BIN}" >/dev/null
else
  printf '%s\n' "WARNING: signing ad-hoc — security-scoped bookmarks (folders you add) will break on each app update. Set CODESIGN_IDENTITY to a stable certificate name to persist them."
  codesign --force --sign - --identifier "${BUNDLE_ID}" --entitlements "${ROOT_DIR}/Resources/MenuShelf.entitlements" "${TMP_BIN}" >/dev/null
fi

cp "${TMP_BIN}" "${EXEC_PATH}"
rm -f "${TMP_BIN}"
touch "${APP_DIR}"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "${APP_DIR}" >/dev/null 2>&1 || true

printf '%s\n' "Built ${APP_DIR}"
