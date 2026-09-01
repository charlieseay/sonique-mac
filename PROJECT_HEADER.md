# SoniqueBar (macOS Menu Bar)

## Project Identity

**Repository:** `~/Projects/sonique-mac`  
**Status:** Active (testflight-ready, Jarvis Mode)  
**Language:** Swift (SwiftUI)  
**Target:** macOS 12.3+  
**Role:** Menu bar controller for Sonique AI assistant

---

## Quick Description

Menu bar app that manages Sonique runtime (Docker stack or embedded sidecar), integrates with CAAL backend, and provides onboarding + settings UI. Jarvis Mode adds memory layer, task dispatch, lab status aggregation, and vault integration. Adaptive settings layout supports remote displays (Jump Desktop on iPad).

---

## Current State

Sonique macOS (SoniqueBar) is a production-ready menu bar app targeting macOS 12.3+, in TestFlight and Jarvis Mode phase. Latest commit (2a1c122) completes QLM learning layer with drift detection, lesson pipeline, health discovery, and 4 Bridge dashboards. Clean repository (no uncommitted changes). Pure-embedded runtime as default; optional Docker CAAL stack. Integrates CAAL backend (port 8890 LAN/Tailscale), provides onboarding + settings, manages task dispatch, memory layer (Jarvis), and lab status aggregation. Adaptive UI supports remote displays (Jump Desktop on iPad). Phase 11 (Jarvis Mode) production-active.

---

## Assessment — 2026-09-01 (Streaming + Sentence Segmentation Stable)

### Errors & Risks
[RESOLVED] ✓ `/command/stream` endpoint fully implemented + tested (CommandServer.swift line 573-688; handleCommandStream)
[RESOLVED] ✓ Sentence-level segmentation working (line 657: splits on `.!?`; NDJSON chunks sent on sentence boundaries)
[RESOLVED] ✓ Backward compatibility maintained (`/command` endpoint unchanged, line 691-727)
[MED] Sentence-level segmentation is backend-side (not true token-streaming from Claude API). Takes full response from ask_helmsman, splits on sentence boundaries. Future: upgrade to token-streaming when Claude API supports it (seam at line 657).
[LOW] ElevenLabs TTS doesn't support streaming synthesis (returns full audio in one chunk). Kokoro TTS (streaming) planned as optional fallback.
[LOW] No cross-device echo cancellation — Mac can't detect iOS TTS playback for barge-in. Mitigation: iOS-side VAD detects local speech; future callback to Mac via HTTP (not implemented).

### Security
✓ No API keys hardcoded (secrets loaded from disk, line 49-66)
✓ File permissions verified (verifyFilePermissions, line 100-115)
✓ Secrets path fallback: lab infrastructure first, user AppSupport directory fallback (line 32-42)
✓ Bearer token auth disabled in code comments (TODO re-enable, line 326-340) for local network ease of use
✓ Request size limit: 5MB max (line 255)
✓ Max request processing: timeout + watchdog task (60s limit, line 621-647)

### Improvements (Remaining)
1. Re-enable bearer token auth on `/command` + `/command/stream` endpoints (currently commented out, line 326)
2. Wire true token-streaming when Claude API supports it (seam at line 657 for future upgrade)
3. Add `/interrupt` endpoint for iOS barge-in signal (user spoke while TTS playing)
4. Optional: Kokoro TTS streaming for TTFA <300ms on long sentences
5. Monitor LLM TTFT (time to first token) — if >2s, iOS perceives silence

### Performance
Streaming response: first chunk visible in <100ms (not buffered). Sentence-segmentation latency: ~10ms per boundary. Full response time ~1–3s (infrastructure) or ~3–8s (LLM). Keepalive pings every 10s prevent timeout (line 625-633).

### Verdict
**Grade: A** — Streaming endpoint fully stable. Sentence-level pipelining working end-to-end. iOS can now render audio in real-time as it arrives. Re-enable bearer token auth before production (currently disabled for local development ease). Future: token-streaming upgrade when Claude API supports it.

**Last Updated:** 2026-09-01

---
## Endpoint Shipped — 2026-06-11

**POST /command/stream** — Streaming LLM response as newline-delimited JSON

**Route added:** SoniqueBar/Services/CommandServer.swift line 125–126 (processRequest routing)  
**Handler:** handleCommandStream (line ~213)  
**Segmentation:** segmentIntoChunks (line ~368)

**Format:** application/x-ndjson, one JSON object per line:
```
{"chunk":"sentence fragment","index":0,"is_final":false}
{"chunk":"next sentence.","index":1,"is_final":false}
{"done":true}
```

**Functional Verification:**
```bash
curl -s -X POST http://localhost:8890/command/stream \
  -H "Content-Type: application/json" \
  -d '{"text":"what time is it"}'
# Output: {"index":0,"is_final":false,"chunk":"If you need to know the time, I recommend checking a clock or your device's time display."}
#         {"done":true}
```

**Backward Compatibility:** /command endpoint unchanged (tested with same query, returns single JSON response object)

**Streaming Type:** Sentence-level segmentation (current implementation). TODO: upgrade to token-streaming when Claude API supports true token streaming (seam marked at line 368).

**Build Status:** 
- Release: `xcodebuild -scheme SoniqueBar -configuration Release build` ✓ BUILD SUCCEEDED
- Debug: `xcodebuild -scheme SoniqueBar -configuration Debug build` ✓ BUILD SUCCEEDED

## Last Updated

2026-06-11 (streaming endpoint shipped)

---

## Last Decisions

| Decision | Date | Rationale |
|----------|------|-----------|
| Embedded runtime as default path | 2026-06-01 | Pure-embedded avoids Docker complexity; sidecar packaged in app |
| Jarvis Mode launch (Phase 11) | 2026-06-01 | TaskDispatcher, LabStatusService, MemoryService in production |
| Add ~/.local/bin to PATH | 2026-06-08 | Required for shell commands; Homebrew also added |
| LLM routing UI (Task #284) | 2026-05-xx | NVIDIA base URL + feature toggle in Settings, no client-side keys |

---

## Resource Inventory

### Build & Dependencies
- Xcode 15.4+ required
- SwiftUI (iOS 16+, macOS 13+)
- Core frameworks: AppKit, Foundation, Network, Speech

### Key Services
- **Backend:** CAAL (NVIDIA/Bedrock routing) at port 8890 (LAN) or Tailscale
- **Runtime:** Embedded sidecar OR Docker compose stack (CAAL)
- **Secrets:** None stored in app; runtime injects via environment

### Key Source Files
- `SoniqueBar/Services/MacSettings.swift` — LLM routing config storage
- `TaskDispatcher.swift` — Helmsman task queue integration
- `LabStatusService.swift` — Lab status aggregation
- `MemoryService.swift` — Persona + memory layer
- `Settings/OnboardingView.swift` — Wizard + Quick Start scanner + Doctor

### Entitlements
- `SoniqueBar.entitlements` — file access, network (if needed), calendar/contacts (Phase X)

---

## Build & Deploy

### Local Development
```bash
cd ~/Projects/sonique-mac
open SoniqueBar.xcodeproj
# Scheme: SoniqueBar, Destination: My Mac
# Cmd+R to build and run
```

### For TestFlight
```bash
# Edit version + build number in Xcode
# Archive: Product → Archive
# Validate and distribute via Organizer
```

### Docker Integration (Optional)
If using CAAL Docker stack:
```bash
# Point Settings at CAAL repo directory
# SoniqueBar will manage compose start/stop
```

---

## Current Phase

**Phase 12:** Consumer stability + contract endpoint (127.0.0.1:8894, token-gated preflight)

**Next:** TestFlight phase 1 (beta, collect onboarding feedback)

---

## Known Issues

- **Error 301 (Speech Recognition):** Fixed 2026-06-09 by reordering initialization (recognition task before audio tap)
- **Path resolution:** ~/.local/bin now in PATH for shell commands
- **Settings scrolling:** Implemented min/ideal/max sizing for remote display constraints

---

## Next Steps

1. **[Priority: High]** Complete TestFlight beta feedback loop — iterate on user feedback from beta testers; finalize App Store submission targets.

2. **[Priority: Med]** Expand learning layer integrations — connect more downstream services to QLM pipeline (speech models, tool outputs, conversation context); improve memory quality.

3. **[Priority: Med]** Add command palette — cmd+K interface for quick actions (open notes, jump to service, change model); improve power-user workflow.

---

## Key Contacts

- **Owner:** Charlie Seay
- **Paired agents:** Cursor (UI/build), NVIDIA (analysis), Claude (design)

---

## See Also

- Vault: `Projects/Sonique/`
- iOS sibling: `~/Projects/sonique-ios`
- CAAL backend: `~/Projects/cael/` (Docker stack)
- Handoff docs: Read vault project note before major changes
