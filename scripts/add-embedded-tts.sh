#!/bin/bash
# Add EmbeddedTTSProvider and sonique-tts binary to Xcode project
set -e

echo "🔧 Adding Embedded TTS to Xcode project..."

PROJECT_DIR="$HOME/Projects/sonique-mac"
XCODE_PROJECT="$PROJECT_DIR/SoniqueBar.xcodeproj"

# Files to add
SWIFT_FILE="$PROJECT_DIR/SoniqueBar/Core/Voice/EmbeddedTTSProvider.swift"
BINARY_FILE="$PROJECT_DIR/tts-engine/dist/sonique-tts"

# Verify files exist
if [ ! -f "$SWIFT_FILE" ]; then
    echo "❌ Error: Swift file not found: $SWIFT_FILE"
    exit 1
fi

if [ ! -f "$BINARY_FILE" ]; then
    echo "❌ Error: Binary not found: $BINARY_FILE"
    exit 1
fi

echo "✅ Files verified:"
echo "   Swift: $SWIFT_FILE"
echo "   Binary: $BINARY_FILE ($(du -h "$BINARY_FILE" | cut -f1))"

# Use xcodebuild to add files
# Note: This requires manual project file editing OR using xcodebuild -project approach
# For now, we'll use a simpler approach: open the project and let Xcode handle it

echo ""
echo "📝 Next steps (manual):"
echo ""
echo "1. Open Xcode project:"
echo "   open $XCODE_PROJECT"
echo ""
echo "2. Add EmbeddedTTSProvider.swift:"
echo "   - Right-click 'SoniqueBar/Core/Voice' folder"
echo "   - Select 'Add Files to SoniqueBar...'"
echo "   - Navigate to: $SWIFT_FILE"
echo "   - Check 'Copy items if needed' (should be UNCHECKED - file already in place)"
echo "   - Check 'Add to targets: SoniqueBar'"
echo "   - Click 'Add'"
echo ""
echo "3. Add sonique-tts binary:"
echo "   - Select SoniqueBar target"
echo "   - Go to 'Build Phases' tab"
echo "   - Expand 'Copy Bundle Resources'"
echo "   - Click '+' button"
echo "   - Click 'Add Other...'"
echo "   - Navigate to: $BINARY_FILE"
echo "   - Click 'Open'"
echo ""
echo "4. Make binary executable (Add Run Script Phase):"
echo "   - In 'Build Phases', click '+' → 'New Run Script Phase'"
echo "   - Name it: 'Make TTS Binary Executable'"
echo "   - Add script:"
echo "   chmod +x \"\$BUILT_PRODUCTS_DIR/\$CONTENTS_FOLDER_PATH/Resources/sonique-tts\""
echo ""
echo "✅ Ready for manual Xcode configuration"
