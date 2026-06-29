#!/bin/bash
# Quinn Auto-Deploy Script
# Called by helmsman after fixes are implemented

set -e

PROJECT_DIR="/Users/charlieseay/Projects/sonique-mac"
BUILD_DIR="$PROJECT_DIR/build/Build/Products/Release"
APP_PATH="$BUILD_DIR/SoniqueBar.app"
LAUNCHD_PLIST="$HOME/Library/LaunchAgents/com.seayniclabs.soniquebar.plist"

echo "=== Quinn Auto-Deploy Started ==="
echo "Timestamp: $(date)"

# 1. Pull latest from GitHub
cd "$PROJECT_DIR"
echo "→ Pulling latest code from GitHub..."
git fetch origin
git pull origin feature/sidecar-packaging

# 2. Bump build number
echo "→ Bumping build number..."
agvtool next-version -all

# 3. Clean build
echo "→ Building SoniqueBar..."
xcodebuild -scheme SoniqueBar -configuration Release clean build 2>&1 | tail -20

# 4. Verify build succeeded
if [ ! -f "$APP_PATH/Contents/MacOS/SoniqueBar" ]; then
    echo "❌ BUILD FAILED - Binary not found"
    exit 1
fi

# 5. Update launchd plist with new build path
echo "→ Updating launchd plist..."
NEW_PATH=$(find ~/Library/Developer/Xcode/DerivedData/SoniqueBar-*/Build/Products/Release/SoniqueBar.app/Contents/MacOS/SoniqueBar | head -1)

if [ -z "$NEW_PATH" ]; then
    echo "❌ Could not find new binary path"
    exit 1
fi

# Update plist with new path
plutil -replace ProgramArguments.0 -string "$NEW_PATH" "$LAUNCHD_PLIST"

# 6. Stop current instance
echo "→ Stopping current Quinn instance..."
launchctl bootout gui/$(id -u) "$LAUNCHD_PLIST" 2>/dev/null || true
killall SoniqueBar 2>/dev/null || true
sleep 2

# 7. Start new instance via launchd
echo "→ Starting new Quinn instance..."
launchctl bootstrap gui/$(id -u) "$LAUNCHD_PLIST"
sleep 3

# 8. Verify health
echo "→ Verifying health..."
sleep 2
HEALTH=$(curl -s --max-time 5 http://localhost:8890/health)

if echo "$HEALTH" | grep -q '"status":"ok"'; then
    BUILD=$(echo "$HEALTH" | python3 -c "import json,sys; print(json.load(sys.stdin).get('build', 'unknown'))")
    echo "✅ Quinn redeployed successfully - Build $BUILD"
    echo "Health: $HEALTH"

    # Notify via Slack
    slack-post-filtered cael "Quinn auto-deployed Build $BUILD after self-healing fix" --priority=low

    exit 0
else
    echo "❌ HEALTH CHECK FAILED"
    echo "Response: $HEALTH"

    # Rollback attempt (restart old version)
    launchctl bootout gui/$(id -u) "$LAUNCHD_PLIST" 2>/dev/null || true
    sleep 1
    launchctl bootstrap gui/$(id -u) "$LAUNCHD_PLIST"

    exit 1
fi
