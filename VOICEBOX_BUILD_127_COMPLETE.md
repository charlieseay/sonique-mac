# VoiceBox/Kokoro Integration - Build 127 FINAL

**Date:** 2026-06-29  
**iOS Build:** 127  
**macOS:** e7ea2eee (with /voices endpoint)  
**Status:** ✅ **READY FOR TESTING**

---

## All Issues Fixed

### ✅ Issue 1: Settings Gear Icon Missing
**Fixed:** Added settings button to ContentView (top-left)

### ✅ Issue 2: TTS Provider Section Not Showing  
**Fixed:** Removed duplicate root SettingsView.swift, corrected Xcode project path to use Sonique/SettingsView.swift

### ✅ Issue 3: Hardcoded Build Number
**Fixed:** About section now reads dynamically from Bundle

### ✅ Issue 4: Voice Picker "Couldn't Load Voices"
**Fixed:** Added `/voices` endpoint to SoniqueBar CommandServer  
Returns 10 ElevenLabs voices (Jessica, Rachel, Adam, Callum, Charlotte, Chris, Brian, Sarah, Elli, Josh)

### ✅ Issue 5: Tailscale Config Inconsistency
**Fixed:** SettingsView now syncs toggle changes to both @AppStorage and Config.tailscaleFallbackEnabled

---

## What Was Built

### macOS (SoniqueBar)
- **Embedded TTS Binary:** 211MB Kokoro model in app bundle
- **EmbeddedTTSProvider:** Subprocess management for standalone binary
- **KokoroProvider:** TTS provider using embedded binary with ElevenLabs fallback
- **/synthesize endpoint:** POST endpoint for TTS synthesis
- **/voices endpoint:** GET endpoint returning voice list for picker

### iOS (Sonique)
- **TTSClient:** Unified client supporting both ElevenLabs and Kokoro
- **Settings UI:** 
  - Settings gear icon (top-left)
  - Server Connection section
  - Voice section
  - **TTS Provider picker** (ElevenLabs / Kokoro)
  - About section with dynamic build number
  - Test Connection button
- **Config sync:** Tailscale toggle properly updates all storage layers

---

## Testing Instructions

### Prerequisites
1. **Reboot iPad** to clear LaunchServices cache
2. Ensure SoniqueBar (macOS) is running the latest build from DerivedData

### Test 1: Settings UI
1. Launch Sonique on iPad
2. Tap **gear icon** (top-left)
3. Verify all sections present:
   - ✓ Server Connection (with Tailscale toggle)
   - ✓ Voice (Current Voice: Adam)
   - ✓ TTS Provider (ElevenLabs/Kokoro segmented control)
   - ✓ About (showing Build 127)
   - ✓ Test Connection button
4. **PASS if:** All sections visible, no missing UI

### Test 2: Voice Picker
1. From main screen, tap **waveform icon** (top-right)
2. **PASS if:** Voice list loads (Jessica, Rachel, Adam, etc.)
3. **FAIL if:** "Couldn't load voices" appears

### Test 3: Tailscale Config Sync
1. Open Settings
2. Toggle "Use Tailscale" ON
3. Close Settings
4. Reopen Settings
5. **PASS if:** Toggle still shows ON
6. Toggle OFF, repeat
7. **PASS if:** Toggle correctly persists both states

### Test 4: Kokoro TTS Synthesis
1. Open Settings
2. Switch TTS Provider to **"Kokoro (Local)"**
3. Tap Done
4. Ask: "What time is it?"
5. Check logs:
```bash
xcrun devicectl device copy from \
  --device 00008027-0015599C2185002E \
  --domain-type appDataContainer \
  --domain-identifier com.seayniclabs.sonique \
  --user mobile --source Documents/trace.log \
  --destination /tmp/sonique-trace.log && \
tail -50 /tmp/sonique-trace.log | grep tts
```
6. **PASS if:** Logs show `[tts] fetched X PCM bytes from Kokoro`
7. On Mac, during synthesis: `ps aux | grep sonique-tts` shows subprocess running
8. **PASS if:** Audio plays correctly

### Test 5: ElevenLabs Fallback
1. Keep "Kokoro (Local)" selected in Settings
2. Stop SoniqueBar on Mac: `killall SoniqueBar`
3. Ask another question
4. **PASS if:** Logs show `[tts] Falling back to ElevenLabs`
5. **PASS if:** Audio still plays (via ElevenLabs)

---

## Known Limitations

1. **Kokoro subprocess overhead:** ~15-20s per synthesis (subprocess restarts each time for stability)
2. **No Kokoro voice selection:** Always uses `af_bella`, no UI to switch Kokoro voices
3. **WAV-only output:** Kokoro returns WAV files, iPad extracts PCM (works but not optimal)

---

## Future Optimizations

### Performance
1. **Subprocess persistence:** Keep sonique-tts warm instead of restarting per synthesis (saves ~10-15s)
2. **Model preloading:** Background process keeps model loaded
3. **Streaming audio:** Stream chunks instead of waiting for full synthesis

### Features
4. **Kokoro voice picker:** UI to select af_bella, af_heart, af_sky, etc.
5. **Quality toggle:** High (24kHz) vs Fast (16kHz) mode
6. **Network detection:** Auto-switch to Kokoro on LAN, ElevenLabs on cellular

### Code Quality
7. **Structured logging:** Better error visibility
8. **Metrics:** Track synthesis time, provider usage, fallback rate
9. **Unit tests:** WAV extraction, provider selection, fallback logic

---

## Files Modified

### macOS (sonique-mac)
- `SoniqueBar/Services/CommandServer.swift` - Added `/voices` endpoint
- `tts-engine/main.py` - TTS server
- `tts-engine/setup.sh` - Build script
- `tts-engine/dist/sonique-tts` - Standalone binary (211MB)
- `SoniqueBar/Core/Voice/EmbeddedTTSProvider.swift` - Subprocess manager
- `SoniqueBar/Core/Voice/KokoroProvider.swift` - TTS provider
- `SoniqueBar/Services/CommandServer.swift` - `/synthesize` endpoint

### iOS (sonique-ios)
- `Sonique/ContentView.swift` - Added settings gear + sheet
- `Sonique/SettingsView.swift` - Added TTS Provider section, fixed build number, Tailscale sync
- `Sonique/TTSClient.swift` - Unified TTS client
- `Sonique/VoiceLoop.swift` - Uses TTSClient
- `Sonique/Config.swift` - soniqueBarHost property
- Deleted: root `SettingsView.swift` (duplicate)

---

## Commits

**macOS:**
- `e7ea2eee` - Add /voices endpoint to CommandServer

**iOS:**
- `f328549` - iOS Build 126: Fix SettingsView path, add TTS Provider picker, dynamic build number
- `da84b85` - iOS Build 127: Fix Tailscale config sync

---

## Verification Commands

### Check SoniqueBar is running latest build
```bash
# Latest build location
find ~/Library/Developer/Xcode/DerivedData/SoniqueBar-*/Build/Products/Debug/SoniqueBar.app -maxdepth 0

# Currently running binary
ps aux | grep SoniqueBar | grep -v grep

# Test /voices endpoint
curl -s http://localhost:8890/voices | python3 -m json.tool

# Should return 10 voices with id and name
```

### Check iOS build installed
```bash
xcrun devicectl device info apps --device 00008027-0015599C2185002E 2>&1 | grep Sonique

# Should show: Sonique  com.seayniclabs.sonique  2.1.0  127
```

---

## Success Criteria

- [x] All build issues fixed
- [x] iOS Build 127 compiled and installed
- [x] macOS /voices endpoint working
- [x] Settings UI complete with all sections
- [x] TTS Provider picker functional
- [x] Tailscale config syncs properly
- [ ] **User testing:** Settings visible on iPad (requires reboot)
- [ ] **User testing:** Kokoro synthesis works end-to-end
- [ ] **User testing:** ElevenLabs fallback works
- [ ] **User testing:** Voice picker loads voices

---

## Next Steps

1. **User reboots iPad** - Clears LaunchServices cache
2. **User runs Test 1-5** - Validates all functionality
3. **If all tests pass** - Integration complete, ready for daily use
4. **If tests fail** - Debug with logs + screenshots, fix in Build 128

---

**All known issues fixed. Ready for user acceptance testing.**
