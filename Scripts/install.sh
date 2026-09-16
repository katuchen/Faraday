#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-Release}"
DERIVED="$ROOT/build/DerivedDataSigned"
APP="$DERIVED/Build/Products/$CONFIGURATION/Faraday.app"

cd "$ROOT"
Scripts/configure.sh
xcodegen generate --quiet
set -o pipefail
xcodebuild -project Faraday.xcodeproj -scheme Faraday -configuration "$CONFIGURATION" \
  -destination "platform=macOS,arch=$(uname -m)" \
  -derivedDataPath "$DERIVED" -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
  CURRENT_PROJECT_VERSION="$(date +%s)" build \
  | grep -E "error:|warning:|BUILD (SUCCEEDED|FAILED)" || true
test -d "$APP" || { echo "error: build failed, see the output above" >&2; exit 1; }
codesign --verify --deep --strict "$APP"

osascript -e 'tell application "Faraday" to quit' >/dev/null 2>&1 || true
rm -rf /Applications/Faraday.app
ditto "$APP" /Applications/Faraday.app
open /Applications/Faraday.app || echo "Open Faraday from /Applications to finish the update."

cat <<EOF

Faraday is installed and running in the menu bar (network icon).
  1. Click it and choose Install Filter.
  2. Approve the extension: System Settings → General → Login Items & Extensions → Network Extensions.
  3. Allow the filter configuration when macOS asks.

Command-line tool: /Applications/Faraday.app/Contents/Helpers/faraday
End-to-end check:  Scripts/verify.sh
EOF
