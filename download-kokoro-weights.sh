#!/bin/bash
#
# Download Kokoro-82M weights from HuggingFace
# Source: https://huggingface.co/mweinbach/Kokoro-82M-Swift
#

set -e

WEIGHTS_DIR="$HOME/Projects/sonique-mac/Kokoro/MLX_GPU"
REPO="mweinbach/Kokoro-82M-Swift"
HF_BASE="https://huggingface.co/$REPO/resolve/main"

echo "📦 Downloading Kokoro-82M MLX weights..."

mkdir -p "$WEIGHTS_DIR/voices"

# Download model files
echo "⬇️  Downloading model config and weights..."
curl -L "$HF_BASE/MLX_GPU/config.json" -o "$WEIGHTS_DIR/config.json"
curl -L "$HF_BASE/MLX_GPU/kokoro-v1_0.safetensors" -o "$WEIGHTS_DIR/kokoro-v1_0.safetensors"

# Download af_jessica voice (American English female)
echo "⬇️  Downloading af_jessica voice..."
curl -L "$HF_BASE/MLX_GPU/voices/af_jessica.npy" -o "$WEIGHTS_DIR/voices/af_jessica.npy"

echo "✅ Kokoro weights downloaded successfully!"
echo ""
echo "Location: $WEIGHTS_DIR"
echo "Size: $(du -sh "$WEIGHTS_DIR" | cut -f1)"
echo ""
echo "Voice available: af_jessica (American English female)"
echo ""
echo "To download more voices, visit:"
echo "https://huggingface.co/$REPO/tree/main/MLX_GPU/voices"
