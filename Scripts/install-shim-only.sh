#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$HOME/.faraday}"
DERIVED="$ROOT/build/DerivedDataShimOnly"

cd "$ROOT"
if [ ! -f Config/Local.xcconfig ]; then
  printf 'FARADAY_TEAM_ID =\nFARADAY_BUNDLE_PREFIX = local.faraday\n' >Config/Local.xcconfig
  echo "Wrote Config/Local.xcconfig for a build without a team"
fi

xcodegen generate --quiet
set -o pipefail
xcodebuild -project Faraday.xcodeproj -scheme FaradayCLI -configuration Release \
  -destination "platform=macOS,arch=$(uname -m)" -derivedDataPath "$DERIVED" \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build \
  | grep -E "error:|BUILD (SUCCEEDED|FAILED)" || true
test -x "$DERIVED/Build/Products/Release/faraday" || { echo "error: build failed, see the output above" >&2; exit 1; }

mkdir -p "$OUT"
Scripts/build-shim.sh "$OUT" >/dev/null
install -m 755 "$DERIVED/Build/Products/Release/faraday" "$OUT/faraday"

cat <<EOF

Installed in $OUT (no signing, no Apple account):
  $OUT/faraday shim install        # load the shim into apps this simulator launches
  $OUT/faraday --shim-only on      # apps see no network
  $OUT/faraday --shim-only off

Add it to your PATH with: export PATH="$OUT:\$PATH"
Connections aren't blocked in this mode; only what apps see changes.
EOF

if [ -d /Applications/Faraday.app ]; then
  echo
  echo "Note: Faraday.app is installed and manages the shim itself, so --shim-only isn't needed on this Mac."
fi
