#!/usr/bin/env bash
set -euo pipefail

APP_NAME="GravityBar"
BUNDLE_ID="com.gravitybar.GravityBar"
VERSION="1.0.0"
DIST_DIR="dist"
APP_DIR="${DIST_DIR}/${APP_NAME}.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

echo "==> Building ${APP_NAME} in release configuration..."
swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)/${APP_NAME}"
if [ ! -f "${BIN_PATH}" ]; then
  echo "Error: Release binary not found at ${BIN_PATH}"
  exit 1
fi

echo "==> Creating macOS App Bundle..."
rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"

cp "${BIN_PATH}" "${MACOS_DIR}/${APP_NAME}"
chmod +x "${MACOS_DIR}/${APP_NAME}"

echo "==> Generating Info.plist..."
cat <<EOF > "${CONTENTS_DIR}/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
</dict>
</plist>
EOF

# Ad-hoc sign so Gatekeeper on Apple Silicon doesn't flag the copied bundle as damaged.
# "-" means no identity: this is not notarization, just a valid local signature.
echo "==> Ad-hoc signing ${APP_NAME}.app..."
codesign --force --deep --sign - "${APP_DIR}"
codesign --verify --strict --verbose=2 "${APP_DIR}"

echo "✓ Successfully bundled ${APP_NAME}.app at ${APP_DIR}"

if [[ "${1:-}" == "--install" ]]; then
    echo "==> Installing to /Applications/${APP_NAME}.app..."
    rm -rf "/Applications/${APP_NAME}.app"
    cp -R "${APP_DIR}" "/Applications/${APP_NAME}.app"
    echo "✓ Installed to /Applications/${APP_NAME}.app"
fi
