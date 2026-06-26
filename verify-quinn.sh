#!/bin/bash
#
# Quinn Verification Script
# Quick health check for SoniqueBar Build 70
#

echo "🔍 Quinn Health Check"
echo ""

# 1. Check if running
if ps aux | grep -i soniquebar | grep -v grep > /dev/null; then
    echo "✅ SoniqueBar is running"
    PID=$(ps aux | grep -i soniquebar | grep -v grep | awk '{print $2}')
    echo "   PID: $PID"
else
    echo "❌ SoniqueBar is not running"
    echo "   Start with: open /Applications/SoniqueBar.app"
    exit 1
fi

# 2. Check build version
VERSION=$(plutil -p /Applications/SoniqueBar.app/Contents/Info.plist | grep CFBundleVersion | awk '{print $3}' | tr -d '"')
echo "✅ Build version: $VERSION"

# 3. Check memory directory
if [ -d ~/Library/Containers/com.seayniclabs.soniquebar/Data/Documents/memory ]; then
    CONV_COUNT=$(ls -1 ~/Library/Containers/com.seayniclabs.soniquebar/Data/Documents/memory/*.jsonl 2>/dev/null | wc -l)
    echo "✅ Memory directory exists ($CONV_COUNT conversations)"
else
    echo "⚠️  Memory directory not yet created (first interaction will create it)"
fi

# 4. Check CommandServer
if curl -s http://localhost:9876/health > /dev/null 2>&1; then
    echo "✅ CommandServer responding on :9876"
else
    echo "⚠️  CommandServer not responding (may still be initializing)"
fi

# 5. Check Kokoro service (optional)
if curl -s http://localhost:5903/health > /dev/null 2>&1; then
    echo "✅ Kokoro TTS service running on :5903"
else
    echo "⚠️  Kokoro TTS service not running (ElevenLabs active)"
    echo "   To enable: cd ~/Projects/sonique-mac/kokoro-service && source venv/bin/activate && python main.py"
fi

echo ""
echo "🎙️  Ready to use Quinn!"
echo ""
echo "Test with: 'Hey Quinn, what time is it?'"
echo ""
