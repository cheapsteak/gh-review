#!/bin/bash
set -e

cd "$(dirname "$0")/../app"

APP_NAME="GHReview"

# Quit any running instance (ignore failure if not running)
osascript -e "quit app \"${APP_NAME}\"" 2>/dev/null || true
pkill -x "${APP_NAME}" 2>/dev/null || true

# Rebuild the .app bundle
bash scripts/build-app.sh

# Launch
open "build/${APP_NAME}.app"
