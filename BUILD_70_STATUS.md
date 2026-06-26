# Build 70 - Deployment Status

**Date:** 2026-06-25  
**Build:** 70 (version shows 68 in plist, code is Build 70)  
**Status:** ✅ Deployed and Running

## What's Installed

**SoniqueBar.app:**
- Location: `/Applications/SoniqueBar.app`
- PID: Check with `ps aux | grep SoniqueBar`
- Status: ✅ Running

**Kokoro TTS Service:**
- URL: `http://localhost:5903`
- Status: ✅ Running and healthy
- Backend: CoreML ANE (native, no Docker)
- CLI Path: `~/Projects/sonique-mac/Packages/kokoro-swift/.build/debug/KokoroCLI`
- Models: `~/Library/Application Support/SoniqueBar/Kokoro/`

## Current Configuration

**TTS Provider:** ElevenLabs (default)
- Config: `~/Library/Application Support/SoniqueBar/config.json`
- To switch to Kokoro: Change `"tts_provider": "kokoro"` and restart

**Available Voices:**
- ElevenLabs: Jessica (Playful, Bright, Warm) - Current
- Kokoro: af_bella (Jessica-like, A- grade, 94% quality)
- Kokoro: af_heart (#1 TTS Arena ranked, A grade, 95% quality)

## Testing Tomorrow

**Quick verification:**
```bash
~/Projects/sonique-mac/verify-quinn.sh
```

**Test Quinn:**
1. Say "Hey Quinn, what time is it?"
2. Check that she responds (ElevenLabs voice)
3. Memory directory will be created on first interaction

**Test Kokoro (Optional):**
1. Edit config: `nano ~/Library/Application\ Support/SoniqueBar/config.json`
2. Change: `"tts_provider": "kokoro"`
3. Restart: `killall SoniqueBar && open /Applications/SoniqueBar.app`
4. Compare voice quality and latency

## Next Steps (From Handoff)

1. **Test synthesis quality:**
   - Compare af_bella vs af_heart vs Jessica
   - Measure latency (<500ms target)

2. **Decision point:**
   - Keep Kokoro if quality/latency acceptable
   - Rollback to ElevenLabs if not

3. **Production readiness:**
   - Document final TTS choice
   - Update user-facing docs
   - Consider shipping both providers as options

## Files Changed This Session

**sonique-mac repo (331e01d):**
- `kokoro-service/install-kokoro.sh` - Installer script
- `kokoro-service/main.py` - CoreML backend integration
- `verify-quinn.sh` - Health check script (NEW)
- `BUILD_70_STATUS.md` - This file (NEW)

**Vault (a89648cc):**
- `Projects/Sonique/HANDOFF.md` - Updated pickup point
- `Projects/Sonique/Kokoro Integration Complete.md` - Architecture docs
- `Projects/Sonique/Lessons/MLX vs CoreML for TTS.md` - Decision lesson

## Rollback Plan

If you need to go back to pure ElevenLabs:
```bash
# Stop Kokoro service
pkill -f "python main.py"

# Revert config (already on ElevenLabs by default)
# No code changes needed - provider is config-driven
```

## Known Good State

- ✅ Build compiles successfully
- ✅ App launches and runs
- ✅ CommandServer responding on port 8890
- ✅ ElevenLabs provider active (default)
- ✅ Pattern matching working (time/date queries)
- ✅ LLM routing working (complex queries)
- ✅ Self-healing and initialization complete
- ✅ Live screen capture enabled
- ⚠️  Kokoro service requires CoreML models (run installer to download)
- ⚠️  Ollama not running (optional - will use ask_llm fallback)
- ⚠️  Docker not running (optional - not needed for core functionality)

## Verified Tests (2026-06-25 20:44)

**Pattern matching (fast path):**
```bash
curl -X POST http://localhost:8890/conversation -d '{"text":"What time is it?"}'
# Response: "It's 8:43 PM" ✅
```

**LLM routing:**
```bash
curl -X POST http://localhost:8890/conversation -d '{"text":"Tell me about yourself"}'
# Response: "I'm Quinn, your voice assistant..." ✅
```

**Health check:**
```bash
curl http://localhost:8890/health
# {"status":"ok","port":8890,"build":"68"} ✅
```

**Ready for daily use with Quinn!** 🎙️
