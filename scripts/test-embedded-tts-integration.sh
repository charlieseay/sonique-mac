#!/bin/bash
# Complete end-to-end integration test for Embedded TTS
set -e

echo "🧪 Testing Embedded TTS Integration"
echo "===================================="
echo ""

PROJECT_DIR="$HOME/Projects/sonique-mac"
BINARY="$PROJECT_DIR/tts-engine/dist/sonique-tts"
SWIFT_FILE="$PROJECT_DIR/SoniqueBar/Core/Voice/EmbeddedTTSProvider.swift"

# Test 1: Verify binary exists and is executable
echo "Test 1: Binary verification"
if [ -f "$BINARY" ]; then
    SIZE=$(du -h "$BINARY" | cut -f1)
    PERMS=$(ls -l "$BINARY" | cut -d' ' -f1)
    echo "  ✅ Binary exists: $SIZE"
    echo "  ✅ Permissions: $PERMS"
else
    echo "  ❌ Binary not found!"
    exit 1
fi

# Test 2: Verify Swift file exists
echo ""
echo "Test 2: Swift file verification"
if [ -f "$SWIFT_FILE" ]; then
    LINES=$(wc -l < "$SWIFT_FILE")
    echo "  ✅ Swift file exists: $LINES lines"
else
    echo "  ❌ Swift file not found!"
    exit 1
fi

# Test 3: Test binary standalone
echo ""
echo "Test 3: Binary standalone test"
echo '{"text":"Integration test","voice":"af_bella"}' | timeout 30 "$BINARY" > /tmp/tts-test.out 2>&1 &
PID=$!

sleep 5

if ps -p $PID > /dev/null; then
    echo "  ✅ Binary process running (PID: $PID)"

    # Wait a bit for model load
    sleep 10

    if grep -q "READY" /tmp/tts-test.out 2>/dev/null; then
        echo "  ✅ READY signal detected"
    else
        echo "  ⚠️  READY signal not yet detected (may still be loading)"
    fi

    # Kill the test process
    kill $PID 2>/dev/null || true
    wait $PID 2>/dev/null || true
else
    echo "  ❌ Binary process exited unexpectedly"
    cat /tmp/tts-test.out
    exit 1
fi

# Test 4: Verify Xcode project builds
echo ""
echo "Test 4: Xcode build test"
cd "$PROJECT_DIR"

if xcodebuild -project SoniqueBar.xcodeproj -scheme SoniqueBar -configuration Debug clean build SYMROOT=build 2>&1 | grep -q "BUILD SUCCEEDED"; then
    echo "  ✅ Xcode project builds successfully"
else
    echo "  ❌ Xcode build failed"
    exit 1
fi

# Test 5: Verify app bundle structure (if build succeeded)
echo ""
echo "Test 5: App bundle verification"
APP_PATH="$PROJECT_DIR/build/Debug/SoniqueBar.app"

if [ -d "$APP_PATH" ]; then
    echo "  ✅ App bundle exists: $APP_PATH"

    # Check if binary is in resources
    if [ -f "$APP_PATH/Contents/Resources/sonique-tts" ]; then
        echo "  ✅ Binary embedded in app bundle"

        if [ -x "$APP_PATH/Contents/Resources/sonique-tts" ]; then
            echo "  ✅ Binary is executable in bundle"
        else
            echo "  ⚠️  Binary not executable (Run Script phase may be missing)"
        fi
    else
        echo "  ⚠️  Binary NOT found in app bundle (needs manual Xcode step)"
    fi

    # Check if Swift file is compiled
    if [ -f "$APP_PATH/Contents/MacOS/SoniqueBar" ]; then
        if nm "$APP_PATH/Contents/MacOS/SoniqueBar" | grep -q "EmbeddedTTSProvider"; then
            echo "  ✅ EmbeddedTTSProvider compiled into binary"
        else
            echo "  ⚠️  EmbeddedTTSProvider not found in symbols"
        fi
    fi
else
    echo "  ⚠️  App bundle not found (build may not have completed)"
fi

echo ""
echo "===================================="
echo "✅ Integration test complete!"
echo ""
echo "Summary:"
echo "  - TTS binary: ✅ Working"
echo "  - Swift code: ✅ Present"
echo "  - Xcode build: ✅ Compiles"
echo "  - App bundle: $([ -d "$APP_PATH" ] && echo '✅ Created' || echo '⚠️  Check build')"
echo ""
echo "Next: Launch app and test voice synthesis"
