#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI="${FARADAY_CLI:-/Applications/Faraday.app/Contents/Helpers/faraday}"
PORT="${LOCAL_PORT:-8765}"
LOGS="$ROOT/build/verify"
NETPROBE="$ROOT/build/DerivedDataSim/Build/Products/Debug-iphonesimulator/NetProbe.app"
rm -rf "$LOGS"
mkdir -p "$LOGS"

booted() {
  xcrun simctl list devices booted -j | python3 -c 'import json, sys; [print(d["udid"]) for ds in json.load(sys.stdin)["devices"].values() for d in ds]'
}

A="${1:-$(booted | sed -n 1p)}"
B="${2:-$(booted | sed -n 2p)}"
if [ -z "$A" ]; then
  echo "error: boot a simulator first, or pass its UDID" >&2
  exit 1
fi
if [ -z "$B" ]; then
  echo "note: boot a second simulator to also check isolation and cutting open connections"
fi
if ! pgrep -x Faraday >/dev/null; then
  open -g /Applications/Faraday.app
fi

echo "Building NetProbe…"
xcodebuild -project "$ROOT/Faraday.xcodeproj" -scheme NetProbe -configuration Debug -sdk iphonesimulator \
  -destination "generic/platform=iOS Simulator" -derivedDataPath "$ROOT/build/DerivedDataSim" -quiet build
BUNDLE_ID=$(plutil -extract CFBundleIdentifier raw "$NETPROBE/Info.plist")
for udid in $A $B; do
  xcrun simctl install "$udid" "$NETPROBE"
done

python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$LOGS" >/dev/null 2>&1 &
SERVER=$!
cleanup() {
  kill "$SERVER" 2>/dev/null || true
  "$CLI" all-online >/dev/null 2>&1 || true
  for udid in $A $B; do
    "$CLI" shim uninstall "$udid" >/dev/null 2>&1 || true
  done
}
trap cleanup EXIT

probe() {
  xcrun simctl launch --console --terminate-running-process "$1" "$BUNDLE_ID" -autorun -localPort "$PORT" 2>&1 \
    | grep NETPROBE_PROBE >"$LOGS/$2.log" || true
  echo "  $(grep -c ' ok ' "$LOGS/$2.log" || true) of $(grep -c . "$LOGS/$2.log" || true) probes succeeded"
}

filter_running() {
  "$CLI" status --json 2>/dev/null \
    | python3 -c 'import json, sys; print("yes" if json.load(sys.stdin).get("isFilterRunning") else "no")' 2>/dev/null \
    || echo "no"
}

wait_for_filter() {
  for _ in $(seq 1 30); do
    if [ "$(filter_running)" = "yes" ]; then
      return 0
    fi
    sleep 1
  done
  echo "warning: the filter isn't running; open Faraday.app and install the filter"
}

"$CLI" all-online >/dev/null
wait_for_filter
for udid in $A $B; do
  "$CLI" shim install "$udid" >/dev/null
done

echo; echo "== 1. All simulators online, filter running"
probe "$A" 1-online

echo; echo "== 2. $A offline"
"$CLI" on "$A"
"$CLI" kill-existing on >/dev/null
probe "$A" 2-offline

if [ -n "$B" ]; then
  echo; echo "== 3. $B while $A is offline"
  probe "$B" 3-other-online

  echo; echo "== 4. Cutting an open connection on $B"
  WATCH_LOG="$LOGS/watch.log"
  xcrun simctl launch --console --terminate-running-process "$B" "$BUNDLE_ID" -watch >"$WATCH_LOG" 2>&1 &
  WATCH=$!
  wait_for() {
    for _ in $(seq 1 "$2"); do
      if grep -q "$1" "$WATCH_LOG"; then
        return 0
      fi
      sleep 1
    done
    return 1
  }
  wait_for "NETPROBE_WS alive" 20 || echo "warning: the WebSocket never opened"
  "$CLI" on "$B" >/dev/null
  if wait_for "NETPROBE_WS dead" 15; then echo "✓ open WebSocket was cut"; else echo "✗ open WebSocket survived"; fi
  if wait_for "NETPROBE_PATH swift unsatisfied" 5; then echo "✓ NWPathMonitor reported unsatisfied without relaunch"; else echo "✗ NWPathMonitor didn't change"; fi
  if wait_for "NETPROBE_PATH scnetworkreachability flags 0x0" 5; then echo "✓ SCNetworkReachability reported no flags"; else echo "✗ SCNetworkReachability didn't change"; fi
  "$CLI" off "$B" >/dev/null
  xcrun simctl terminate "$B" "$BUNDLE_ID" >/dev/null 2>&1 || true
  wait "$WATCH" 2>/dev/null || true
fi

echo; echo "Filter counters:"
"$CLI" status || true

echo; echo "== 5. All simulators online again"
"$CLI" all-online >/dev/null
probe "$A" 5-online-again

echo; echo "== Summary (✓ = probe succeeded)"
python3 - "$LOGS" <<'EOF'
import os
import sys

logs = sys.argv[1]
columns = [("1-online", "online"), ("2-offline", "offline"), ("3-other-online", "other sim"), ("5-online-again", "online again")]


def load(name):
    path = os.path.join(logs, name + ".log")
    if not os.path.exists(path):
        return None
    results = {}
    with open(path) as file:
        for line in file:
            parts = line.rstrip("\n").split(" ", 4)
            if len(parts) >= 4 and parts[0] == "NETPROBE_PROBE":
                results[parts[1]] = parts[2] == "ok"
    return results


runs = [(title, load(name)) for name, title in columns]
runs = [(title, run) for title, run in runs if run is not None]
names = []
for _, run in runs:
    for name in run:
        if name not in names:
            names.append(name)
print(f"{'probe':34}" + "".join(f"{title:>14}" for title, _ in runs))
for name in names:
    print(f"{name:34}" + "".join(f"{('✓' if run.get(name) else '✗'):>14}" for _, run in runs))
EOF
