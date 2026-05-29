# SoniqueBar Dependencies

## Adding WebRTC Framework

**Manual step required:** Add WebRTC via Xcode SPM integration.

### Steps

1. Open `SoniqueBar.xcodeproj` in Xcode
2. Select the project in the navigator
3. Select the `SoniqueBar` target
4. Go to "Package Dependencies" tab
5. Click "+" to add package
6. Enter URL: `https://github.com/stasel/WebRTC.git`
7. Select "Up to Next Major Version" starting from `124.0.0`
8. Click "Add Package"
9. Select `WebRTC` library and click "Add Package"

### Verification

After adding, you should see:
- `WebRTC` in the Package Dependencies list
- `import WebRTC` should compile without errors in any Swift file

## Current Dependencies

| Package | Version | Purpose |
|---------|---------|---------|
| WebRTC | 124.0.0+ | Real-time peer-to-peer audio/video communication |
| Starscream | 4.0.0+ | WebSocket client for ElevenLabs streaming TTS |

## Adding Starscream (WebSocket client)

**Manual step required:** Add Starscream via Xcode SPM integration.

### Steps

1. Open `SoniqueBar.xcodeproj` in Xcode
2. Repeat steps 1-4 from WebRTC section
3. Enter URL: `https://github.com/daltoniam/Starscream.git`
4. Select "Up to Next Major Version" starting from `4.0.0`
5. Click "Add Package"
6. Select `Starscream` library and click "Add Package"

## Next Steps

After adding dependencies:
1. Build the project to verify dependencies resolve
2. Create `Services/WebRTCServer.swift`
3. Create `Services/TTSStreamer.swift`
4. Test `import WebRTC` and `import Starscream` compile successfully
