#!/bin/bash
set -e

cd "$(dirname "$0")/.."

APP_NAME="GHReview"
APP_DIR="build/${APP_NAME}.app"
CONTENTS="${APP_DIR}/Contents"

# Build the Swift binary
swift build -c release 2>&1

# Assemble .app bundle
rm -rf "${APP_DIR}"
mkdir -p "${CONTENTS}/MacOS"
mkdir -p "${CONTENTS}/Resources"

# Copy binary
cp ".build/release/${APP_NAME}" "${CONTENTS}/MacOS/${APP_NAME}"

# Copy resources
cp Resources/Info.plist "${CONTENTS}/Info.plist"
cp Resources/AppIcon.icns "${CONTENTS}/Resources/AppIcon.icns"

# Ad-hoc code sign (required for UNUserNotificationCenter)
codesign --force --sign - "${APP_DIR}"

echo "Built ${APP_DIR}"
echo "Run: open build/${APP_NAME}.app"
