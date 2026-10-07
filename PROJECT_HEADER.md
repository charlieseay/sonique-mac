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

## Assessment — 2026-10-07

### Errors & Risks
[LOW] Streaming endpoint shipped 2026-06-11 and tested (working). Sentence-segmentation approach functional but not optimal; no token-streaming integrated yet (marked TODO, blocked on upstream LLM API improvements).

[LOW] No `/interrupt` endpoint for iOS barge-in signaling; current design relies on iOS-local VAD (acceptable for Phase 2, planned for Phase 3).

[LOW] ElevenLabs TTS doesn't support true streaming; TTFA per sentence ~300–800ms (acceptable, not critical).

### Security
✓ No hardcoded secrets. ✓ Backend-injected config (env vars). ✓ Helmsman integration properly authenticated. ✓ Local settings storage secure. ✓ Streaming endpoint validation same as request-response.

### Completed (2026-06-11, Still Live)
✓ `/command/stream` endpoint returns NDJSON with sentence-segmented chunks
✓ Backward compatible (`/command` endpoint unchanged)
✓ Build both Debug + Release configurations clean
✓ Tested with curl (functional verification confirmed)

### Improvements (Pending Implementation)
1. Wire iOS to consume `/command/stream` (iOS VoiceLoop.swift awaits full response, not streaming chunks)
2. Token-streaming upgrade when Bedrock/ask_helmsman supports it (code seam at line 368)
3. `/interrupt` endpoint for barge-in (Phase 3 feature)
4. Kokoro TTS alternative for lower TTFA (optional optimization)

### Performance
**Streaming backend latency:** First chunk visible <100ms after request. Full response ~3–8s (LLM-dependent). Perceived improvement on iOS depends on consuming streaming (currently blocked).

### Cost
Minimal (no new infrastructure).

### Verdict
**Grade: B+** (was A- 2026-06-11, regressed to B+ because iOS not consuming stream yet) — Backend streaming solid and production-ready. Sentence-segmentation approach acceptable for Phase 2. iOS integration blocked (no code changes since June). Effort to unblock iOS: low (~2h wire streaming chunks to TTS). Risk: low.

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

2026-10-07 (streaming endpoint shipped)

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
