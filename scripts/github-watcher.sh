#!/bin/bash
# Quinn GitHub Watcher
# Polls GitHub every 60 seconds for new commits
# Auto-deploys when Quinn-related fixes are pushed

PROJECT_DIR="/Users/charlieseay/Projects/sonique-mac"
BRANCH="feature/sidecar-packaging"
CHECK_INTERVAL=60
LAST_COMMIT_FILE="/tmp/quinn-last-commit.txt"

cd "$PROJECT_DIR"

# Get initial commit
git fetch origin &>/dev/null
CURRENT=$(git rev-parse origin/$BRANCH)
echo "$CURRENT" > "$LAST_COMMIT_FILE"

echo "=== Quinn GitHub Watcher Started ==="
echo "Watching branch: $BRANCH"
echo "Check interval: ${CHECK_INTERVAL}s"
echo "Current commit: $CURRENT"

while true; do
    sleep $CHECK_INTERVAL

    # Fetch latest from GitHub (quiet)
    git fetch origin &>/dev/null

    # Get latest commit on remote branch
    LATEST=$(git rev-parse origin/$BRANCH)
    LAST=$(cat "$LAST_COMMIT_FILE" 2>/dev/null || echo "")

    if [ "$LATEST" != "$LAST" ]; then
        echo ""
        echo "→ NEW COMMIT DETECTED: $LATEST"
        echo "→ Previous: $LAST"

        # Get commit message
        MSG=$(git log -1 --pretty=%B $LATEST)
        echo "→ Message: $MSG"

        # Check if commit is Quinn-related (contains "Quinn" or "SoniqueBar" or "Build")
        if echo "$MSG" | grep -qiE "quinn|soniquebar|build [0-9]+|self-healing"; then
            echo "✅ Quinn-related commit detected - triggering auto-deploy"

            # Run auto-deploy
            /Users/charlieseay/Projects/sonique-mac/scripts/auto-deploy.sh

            if [ $? -eq 0 ]; then
                echo "✅ Auto-deploy completed successfully"
            else
                echo "❌ Auto-deploy failed - manual intervention required"
            fi
        else
            echo "ℹ️ Non-Quinn commit - skipping auto-deploy"
        fi

        # Update last commit
        echo "$LATEST" > "$LAST_COMMIT_FILE"
    fi
done
