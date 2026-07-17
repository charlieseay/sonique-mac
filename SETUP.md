# Sonique Setup Guide

## Current Configuration (2026-07-17)

### TTS Provider
- **Primary**: ElevenLabs (cloud, high quality)
- **Pending**: Piper (local, free) - waiting for working arm64 binary
- **Fallback**: macOS `say` command

### LLM Provider
- **Primary**: Ollama (local, free) - `qwen2.5:14b-instruct-q4_K_M`
- **Fallback**: Claude CLI (subscription)

## Architecture

```
iOS App (Sonique.app)
  ↓ HTTP (port 8890)
SoniqueBar (macOS menu bar)
  ↓
┌─────────────────────────────┬──────────────────────────┐
│ ModelRouter                 │ TTS Engine               │
│ - Ollama (primary)          │ - ElevenLabs (primary)   │
│ - Claude CLI (fallback)     │ - macOS say (fallback)   │
└─────────────────────────────┴──────────────────────────┘
```

## iOS App Details

**Build**: 160  
**TTS Mode**: VoiceBox (server-side synthesis)  
**Audio Format**: MP3 from ElevenLabs → PCM via AVAssetReader @ 16kHz

### Voice Flow
1. User speaks → STT → transcript
2. Send to SoniqueBar `/command/stream` → LLM response
3. Send text to `/synthesize` → ElevenLabs MP3
4. iOS converts MP3 → PCM using AVAssetReader
5. Play PCM through VoiceSession (supports Bluetooth)

## Configuration Files

- **LLM Config**: `/Volumes/data/secrets/sonique_model_router.json`
- **ElevenLabs Key**: `/Volumes/data/secrets/elevenlabs_api_key`
- **Auth Token**: `~/Library/Mobile Documents/iCloud~com~seayniclabs~sonique/Documents/SoniqueProfiles/shared/preferences.json`

## Testing

### Test TTS Endpoint
```bash
TOKEN=$(cat ~/Library/Mobile\ Documents/iCloud~com~seayniclabs~sonique/Documents/SoniqueProfiles/shared/preferences.json | python3 -c 'import json,sys; print(json.load(sys.stdin)["authToken"])')

curl -X POST http://localhost:8890/synthesize \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"text":"Test message","provider":"voicebox","voice":"default"}' \
  --output test.mp3

afplay test.mp3
```

### Test Voices Endpoint
```bash
curl http://localhost:8890/voices | python3 -m json.tool
```

## Troubleshooting

### iOS shows "demon voice"
- **Cause**: VoiceBoxTTS.fetchPCM() returned nil, fell back to SimpleTTS
- **Check**: Server logs, network connectivity, auth token
- **Fix**: Verify `/synthesize` endpoint returns 200 with audio/mpeg

### Voice selector says "couldn't load voices"
- **Cause**: `/voices` endpoint not reachable or returning error
- **Check**: `curl http://localhost:8890/voices`
- **Fix**: Ensure SoniqueBar is running and port 8890 is open

### LLM not responding
- **Check**: Ollama is running on port 11434
- **Start**: `ollama serve` (if installed via Homebrew: `/opt/homebrew/bin/ollama`)
- **Fallback**: Will use Claude CLI automatically if Ollama times out

## Future Improvements

### Piper TTS (Local, Free)
**Status**: Pending working arm64 binary  
**Issue**: GitHub releases contain x86_64 binary mislabeled as aarch64  
**When Ready**:
1. Download correct arm64 Piper binary
2. Install voice model: `en_US-lessac-medium.onnx`
3. Update CommandServer to prioritize Piper over ElevenLabs

### Settings UI
Location: `SoniqueBar/Views/SettingsView.swift` (created, not wired yet)

Allows users to configure:
- TTS provider (Piper vs ElevenLabs)
- ElevenLabs API key
- Piper voice selection
- LLM provider (Ollama vs Claude CLI vs Bedrock)
- Ollama host/model
- Fallback behavior

## Best Practices

### Recommended Setup (Cost-Free)
- **TTS**: Piper (when arm64 available) - local, fast, high quality
- **LLM**: Ollama with qwen2.5:14b - local, private, supports tool calling
- **Fallback**: Claude CLI (already paid subscription)

### Premium Setup (Subscription + Usage)
- **TTS**: ElevenLabs (current) - cloud, highest quality, $0.18/1K chars
- **LLM**: Claude CLI - subscription, best reasoning
- **Backup**: Ollama for offline use

## Ports Reference

| Service | Port | Purpose |
|---------|------|---------|
| SoniqueBar CommandServer | 8890 | HTTP API (health, command, synthesize, voices) |
| Ollama | 11434 | LLM inference |

## Authentication

All endpoints except `/health` and `/voices` require Bearer token authentication.

Token is auto-synced via iCloud to `SoniqueProfiles/shared/preferences.json`.

## Build Info

- **macOS**: SoniqueBar (Release)
- **iOS**: Sonique Build 160 (Release)
- **Last Updated**: 2026-07-17

## Known Issues

1. **Piper TTS unavailable** - arm64 binary not working, need proper release
2. **Settings UI not wired** - created but not accessible from menu bar yet
3. **Voice preview sampling** - iOS voice selector can't play samples (no preview_url from local server)

## Support

Check logs:
```bash
# SoniqueBar logs
log stream --predicate 'subsystem == "com.seayniclabs.soniquebar"' --style compact

# iOS app logs (via trace.log)
# TODO: Document iOS log extraction method
```
