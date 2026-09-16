#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOCAL="$ROOT/Config/Local.xcconfig"

if [ -f "$LOCAL" ] && [ "${1:-}" != "--force" ]; then
  echo "Using $LOCAL"
  exit 0
fi

TEAM="${FARADAY_TEAM_ID:-}"
if [ -z "$TEAM" ]; then
  TEAMS=$(defaults export com.apple.dt.Xcode - 2>/dev/null | python3 -c '
import plistlib
import sys

try:
    prefs = plistlib.loads(sys.stdin.buffer.read())
except Exception:
    sys.exit(0)

accounts = prefs.get("IDEProvisioningTeamByIdentifier", {})
groups = accounts.values() if isinstance(accounts, dict) else [accounts]
seen = set()
for teams in groups:
    for team in teams if isinstance(teams, list) else [teams]:
        team_id = team.get("teamID")
        if team_id and not team.get("isFreeProvisioningTeam", False) and team_id not in seen:
            seen.add(team_id)
            print(team_id + "\t" + team.get("teamName", ""))
' || true)
  COUNT=$(printf "%s" "$TEAMS" | grep -c . || true)
  if [ "$COUNT" -eq 0 ]; then
    echo "error: no paid Apple Developer team found in Xcode → Settings → Accounts." >&2
    echo "Network Extensions require a paid membership. Add your account in Xcode, or run: FARADAY_TEAM_ID=<team id> $0" >&2
    exit 1
  fi
  if [ "$COUNT" -gt 1 ]; then
    echo "error: several paid teams found. Choose one: FARADAY_TEAM_ID=<team id> $0" >&2
    printf "%s\n" "$TEAMS" | sed 's/^/  /' >&2
    exit 1
  fi
  TEAM=$(printf "%s" "$TEAMS" | cut -f1)
fi

PREFIX="${FARADAY_BUNDLE_PREFIX:-dev.faraday.$(printf "%s" "$TEAM" | tr '[:upper:]' '[:lower:]')}"

cat >"$LOCAL" <<EOF
FARADAY_TEAM_ID = $TEAM
FARADAY_BUNDLE_PREFIX = $PREFIX
EOF
echo "Wrote $LOCAL (team $TEAM, bundle identifier prefix $PREFIX)"
