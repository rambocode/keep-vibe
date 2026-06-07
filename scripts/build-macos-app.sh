#!/usr/bin/env bash
set -euo pipefail

APP_NAME="${APP_NAME:-KeepVibe}"
BUNDLE_IDENTIFIER="${BUNDLE_IDENTIFIER:-com.keepvibe.macos}"
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
if [[ -n "${BUILD_DIR+x}" ]]; then
  BUILD_DIR="${BUILD_DIR}"
else
  BUILD_DIR="$(swift build -c release --show-bin-path)"
fi
BINARY_PATH="${BUILD_DIR}/${APP_NAME}"
WORK_DIR="${ROOT_DIR}/.build/macos-app"
APP_BUNDLE="${WORK_DIR}/${APP_NAME}.app"
DMG_ROOT="${WORK_DIR}/dmg-root"
DIST_DIR="${ROOT_DIR}/dist"
OUTPUT_ZIP="${DIST_DIR}/${APP_NAME}-macos.zip"
OUTPUT_DMG="${DIST_DIR}/${APP_NAME}-macos.dmg"

if [[ ! -f "${BINARY_PATH}" ]]; then
  echo "Binary not found: ${BINARY_PATH}"
  exit 1
fi

mkdir -p "${WORK_DIR}/Contents/MacOS" "${WORK_DIR}/Contents/Resources" "${DIST_DIR}" "${DMG_ROOT}"
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS" "${APP_BUNDLE}/Contents/Resources"

cp "${BINARY_PATH}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
chmod +x "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"

cat > "${APP_BUNDLE}/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_IDENTIFIER}</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

if [[ -n "${CODE_SIGN_IDENTITY}" ]]; then
  echo "Signing app with identity: ${CODE_SIGN_IDENTITY}"
  codesign \
    --options runtime \
    --timestamp \
    --force \
    --sign "${CODE_SIGN_IDENTITY}" \
    "${APP_BUNDLE}"
  codesign --verify --deep --strict --verbose=2 "${APP_BUNDLE}"
fi

rm -rf "${DMG_ROOT}"
mkdir -p "${DMG_ROOT}"
cp -R "${APP_BUNDLE}" "${DMG_ROOT}/"
ln -sfn /Applications "${DMG_ROOT}/Applications"

rm -f "${OUTPUT_ZIP}"
(cd "${WORK_DIR}" && zip -r "${OUTPUT_ZIP}" "${APP_NAME}.app")
echo "Created app package: ${OUTPUT_ZIP}"

hdiutil create \
  -volname "${APP_NAME}" \
  -srcfolder "${DMG_ROOT}" \
  -ov \
  -format UDZO \
  "${OUTPUT_DMG}"

if [[ -n "${CODE_SIGN_IDENTITY}" ]]; then
  echo "Signing DMG with identity: ${CODE_SIGN_IDENTITY}"
  codesign \
    --options runtime \
    --timestamp \
    --force \
    --sign "${CODE_SIGN_IDENTITY}" \
    "${OUTPUT_DMG}"
  codesign --verify --strict --verbose=2 "${OUTPUT_DMG}"
fi

echo "Created DMG package: ${OUTPUT_DMG}"
