#!/bin/bash
#
# Add Kokoro Swift Package to SoniqueBar
# Run this script to integrate kokoro-swift for native TTS
#

set -e

echo "Adding Kokoro Swift Package to SoniqueBar..."

# 1. Open Xcode project
open SoniqueBar.xcodeproj

cat <<'EOF'

MANUAL STEPS REQUIRED:

1. In Xcode, select the SoniqueBar project in the navigator
2. Select the SoniqueBar target
3. Go to "General" tab → "Frameworks, Libraries, and Embedded Content"
4. Click "+" → "Add Package Dependency"
5. In the search bar, paste: https://github.com/mweinbach/kokoro-swift.git
6. Select version: "Up to Next Major Version" starting from 0.1.0
7. Click "Add Package"
8. Select "Kokoro" library and click "Add Package"

OR

Use local package:
1. Click "+" → "Add Local Package"
2. Navigate to: ~/Projects/sonique-mac/Kokoro
3. Click "Add Package"
4. Select "Kokoro" library

THEN:

9. Add KokoroTTS.swift to the project:
   - Right-click "Services" folder → "Add Files to SoniqueBar"
   - Select: SoniqueBar/Services/KokoroTTS.swift
   - Make sure "Copy items if needed" is UNCHECKED
   - Click "Add"

10. Build the project (Cmd+B) to verify

EOF

# Keep terminal open to show instructions
read -p "Press Enter after completing Xcode steps..."

echo "✓ Kokoro package should now be integrated"
echo "Next: Implement actual synthesis in KokoroTTS.swift"
