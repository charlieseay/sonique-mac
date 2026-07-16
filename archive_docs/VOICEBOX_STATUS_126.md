# VoiceBox/Kokoro Integration - Build 126 Status

**Date:** 2026-06-29  
**iOS Build:** 126 (installed, pending reboot test)  
**macOS Build:** 71 (from prior session)  
**Status:** 🔄 **NEEDS VALIDATION**

---

## What Was Fixed in Build 126

### iOS App Changes

1. **Settings gear icon added** - Top-left corner of main screen
2. **SettingsView.swift path corrected** - Was referencing root file instead of Sonique/ folder
3. **Dynamic build number** - About section now reads from Bundle instead of hardcoded "Build 118"
4. **TTS Provider picker added** - Segmented control to switch between ElevenLabs and Kokoro

### Files Modified
- `Sonique/ContentView.swift` - Added settings button and sheet
- `Sonique/SettingsView.swift` - Added TTS Provider section, fixed build version display
- `Sonique.xcodeproj/project.pbxproj` - Fixed path to SettingsView.swift
- Deleted root `SettingsView.swift` (duplicate file causing confusion)

---

## Known Issues (Not Yet Fixed)

### 1. Voice Picker - "Couldn't load voices"
**Root cause:** SoniqueBar's `/voices` endpoint doesn't exist  
**Impact:** Users can't change voice from the voice picker screen  
**Workaround:** Voice can still be set via Config/UserDefaults  
**Fix needed:** Add `/voices` endpoint to CommandServer.swift (macOS)

### 2. Tailscale Config Inconsistency
**Root cause:** UserDefaults vs SoniqueBrain.Preferences sync issue  
**Impact:** Settings screen shows different Tailscale states on different views  
**Fix needed:** Audit Config.swift for single source of truth

### 3. Build Number Display
**Root cause:** iOS LaunchServices cache  
**Impact:** Settings may show old build number until device reboot  
**Workaround:** Reboot iPad after installing new build  
**Note:** This is an iOS caching issue, not our code

---

## Testing Checklist

### ✅ Pre-Test (Completed)
- [x] Build 126 compiled successfully
- [x] Uninstalled old app
- [x] Installed Build 126
- [x] Device shows Build 126 installed

### ⏸️ Awaiting User (iPad Reboot Required)
- [ ] Reboot iPad to clear LaunchServices cache
- [ ] Force quit and relaunch Sonique
- [ ] Verify settings gear icon visible (top-left)
- [ ] Open Settings → verify all sections present
- [ ] Check About section shows "Build 126"
- [ ] Verify TTS Provider picker shows ElevenLabs/Kokoro options

### 🔄 Kokoro Integration Test
- [ ] Switch to "Kokoro (Local)" in Settings
- [ ] Return to main screen
- [ ] Ask "What time is it?"
- [ ] Check logs for: `[tts] fetched X PCM bytes from Kokoro`
- [ ] Verify on Mac: `ps aux | grep sonique-tts` shows process during synthesis

### 🔄 Fallback Test
- [ ] Keep Kokoro selected
- [ ] Stop SoniqueBar on Mac
- [ ] Ask another question
- [ ] Verify logs show: `[tts] Falling back to ElevenLabs`
- [ ] Confirm audio still plays

---

## What's Left for Full Integration

### macOS (SoniqueBar)
1. **Add `/voices` endpoint** - Returns list of available voices for picker
2. **Test Kokoro stability** - Currently restarts subprocess per synthesis (~15s overhead)
3. **Optimize subprocess lifecycle** - Consider keeping process warm

### iOS (Sonique)
1. **Fix Config.swift sync** - Ensure UserDefaults and SoniqueBrain.Preferences stay in sync
2. **Test Kokoro end-to-end** - Full flow from Settings → synthesis → playback
3. **Verify fallback works** - Test automatic fallback to ElevenLabs on error

### Documentation
1. **Update project notes** - Document new Settings architecture
2. **Capture lessons** - Build number caching, duplicate file issues, Xcode path corrections
3. **Update VOICEBOX_FINAL_STATUS.md** - Replace with validated results

---

## Critical Path to "Done"

1. **User reboots iPad** → clears LaunchServices cache
2. **User tests Build 126** → verifies Settings UI shows correctly
3. **User switches to Kokoro** → tests synthesis
4. **Check logs** → confirms Kokoro or ElevenLabs is used
5. **If all pass** → mark integration complete
6. **If issues found** → diagnose and fix in Build 127

---

## Session Summary

**Time spent:** ~2 hours  
**Builds attempted:** 121, 122, 123, 124, 125, 126  
**Root issues found:**
- Duplicate SettingsView.swift (root vs Sonique/ folder)
- Xcode referencing wrong file path
- Hardcoded build number in About section
- iOS LaunchServices caching old metadata

**Key learning:** Always verify Xcode project file paths, not just file existence. Duplicate files with same name cause silent failures where wrong version compiles.

---

## Next Session

**If test passes:**
- Optimize Kokoro subprocess (keep warm instead of restart)
- Add `/voices` endpoint
- Document final architecture

**If test fails:**
- Capture screenshots of actual vs expected
- Pull full device logs
- Check if SettingsView code is actually running (add debug prints)
- Consider using Xcode "Build and Run" instead of devicectl

---

**Ready for testing after iPad reboot.**
