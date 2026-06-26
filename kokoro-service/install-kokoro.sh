#!/bin/bash
#
# Kokoro TTS Installer for SoniqueBar
# Downloads CoreML models and sets up Python service
#

set -e

KOKORO_DIR="$HOME/Library/Application Support/SoniqueBar/Kokoro"
SERVICE_DIR="$HOME/Projects/sonique-mac/kokoro-service"

echo "🎙️  Installing Kokoro TTS for SoniqueBar..."
echo ""

# 1. Check Git LFS
if ! command -v git-lfs &> /dev/null; then
    echo "❌ Git LFS not installed"
    echo "Install with: brew install git-lfs"
    exit 1
fi

# 2. Clone CoreML models
echo "📥 Downloading CoreML models (this may take a few minutes)..."
cd "$(dirname "$KOKORO_DIR")"
if [ ! -d "$KOKORO_DIR" ]; then
    git clone https://huggingface.co/remsky/kokoro-82m-coreml-ane "$KOKORO_DIR"
else
    echo "⚠️  Kokoro directory already exists, using existing"
fi

# 3. Check Python service
echo "🐍 Checking Python service..."
cd "$SERVICE_DIR"
if [ ! -d "venv" ]; then
    echo "Creating Python virtual environment..."
    python3.11 -m venv venv
fi

source venv/bin/activate
echo "Installing dependencies..."
pip install -q --upgrade pip
pip install -q -r requirements.txt

# 4. Test KokoroCLI
echo "🧪 Testing Kokoro synthesis..."
KOKORO_CLI="$HOME/Projects/sonique-mac/Packages/kokoro-swift/.build/debug/KokoroCLI"

if [ ! -f "$KOKORO_CLI" ]; then
    echo "❌ KokoroCLI not found at $KOKORO_CLI"
    echo "Build it with: cd ~/Projects/sonique-mac/Packages/kokoro-swift && swift build"
    exit 1
fi

TEST_OUTPUT="/tmp/kokoro-install-test.wav"
"$KOKORO_CLI" \
    --text "Kokoro installation complete. Ready to synthesize." \
    --voice af_bella \
    --output "$TEST_OUTPUT" \
    --backend coreml-ane-segmented \
    --weights-dir "$KOKORO_DIR"

if [ -f "$TEST_OUTPUT" ]; then
    echo "✅ Synthesis test passed!"
    afplay "$TEST_OUTPUT" &
    rm "$TEST_OUTPUT"
else
    echo "❌ Synthesis test failed"
    exit 1
fi

# 5. Instructions
echo ""
echo "✅ Kokoro TTS installed successfully!"
echo ""
echo "To use Kokoro with SoniqueBar:"
echo "  1. Start the service: cd $SERVICE_DIR && source venv/bin/activate && python main.py"
echo "  2. Edit config: ~/Library/Application Support/SoniqueBar/config.json"
echo "     Change: \"tts_provider\": \"kokoro\""
echo "  3. Restart SoniqueBar"
echo ""
echo "Available voices: af_bella (Jessica-like), af_heart (#1 ranked)"
echo ""
