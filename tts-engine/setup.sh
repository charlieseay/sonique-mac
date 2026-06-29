#!/bin/bash
# Setup script for Sonique TTS Engine
set -e

echo "🔧 Setting up Sonique TTS Engine..."

# Use Python 3.11 (required for kokoro>=0.9.4)
PYTHON_BIN="/Users/charlieseay/.local/bin/python3.11"

if [ ! -f "$PYTHON_BIN" ]; then
    echo "ERROR: Python 3.11 not found at $PYTHON_BIN"
    echo "Kokoro requires Python 3.10+"
    exit 1
fi

# Create venv
if [ ! -d "venv" ]; then
    echo "Creating Python virtual environment with Python 3.11..."
    "$PYTHON_BIN" -m venv venv
fi

# Activate venv
source venv/bin/activate

# Upgrade pip
echo "Upgrading pip..."
pip install --upgrade pip wheel

# Install dependencies
echo "Installing dependencies..."
pip install -r requirements.txt

# Install PyInstaller
echo "Installing PyInstaller..."
pip install pyinstaller

echo ""
echo "✅ Setup complete!"
echo ""
echo "Next steps:"
echo "  1. Test: source venv/bin/activate && python main.py"
echo "  2. Build: source venv/bin/activate && python build_binary.py"
