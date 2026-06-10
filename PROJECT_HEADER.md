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

## Assessment — 2026-06-10

### Errors & Risks
[MED] CommandServer (port 8890) returns full response text in single HTTP response body. iOS app waits for complete response before sending to TTS (VoiceLoop.swift:149-159), blocking parallel TTS synthesis. To enable streaming voice mode on iOS, `/command` endpoint must support streaming responses (SSE, chunked HTTP/1.1, or gRPC streaming with incremental tokens).

[MED] No sentence-level segmentation at backend — responses are prose paragraphs. iOS must detect sentence boundaries client-side (regex on period/question mark) to trigger incremental TTS. Backend could optimize by structuring responses as JSON array of sentences or using special tokens.

[LOW] ElevenLabs TTS endpoint `/v1/audio/speech` doesn't support streaming synthesis (returns full audio in one chunk). For TTFA <500ms on long sentences, need to either: pre-cache common responses, use Kokoro TTS with streaming, or accept 300–800ms latency per sentence (current, acceptable).

[LOW] No audio echo cancellation at Mac — when iOS broadcasts TTS response via speaker, SoniqueBar can't detect live barge-in (interrupt) because Mac doesn't hear iOS audio. Mitigation: iOS-side VAD detects local speech; barge-in signal sent to Mac via HTTP callback or LiveKit data channel (not implemented). For now, interrupt logic is iOS-local.

### Security
✓ No API keys hardcoded. ✓ Backend routes secrets via environment. ✓ Helmsman task dispatch properly authenticated. ✓ Settings stored locally, no secrets in sync.

### Improvements
1. Add `/command/stream` endpoint that returns newline-delimited JSON with incremental LLM tokens + sentence boundaries → iOS can start TTS mid-generation
2. Optionally wire Kokoro TTS streaming (if available) instead of ElevenLabs for first-token-to-audio <300ms
3. Add `/interrupt` endpoint so iOS can signal barge-in (user spoke while TTS playing) → cancel in-flight LLM request + restart listening
4. Structure responses as sentence arrays in JSON for explicit boundary detection (vs regex guess)
5. Monitor SoniqueBar's LLM response latency — if TTFT >2s, iOS will perceive silence longer than necessary

**Related:** iOS app requires architectural changes (WhisperKit STT, streaming response handling, barge-in logic). Mac backend changes are minimal: add streaming endpoint + optional interrupt signal handling. Full spec: vault note `Voice Pipeline Redesign — 2026-06-10.md` (Phase 2 describes SoniqueBar streaming endpoint requirements).

### Cost
Low: Add `/command/stream` endpoint (20–30 min, copy ask_helmsman call + wrap in SSE or chunked response). Kokoro TTS swap is optional (if latency is critical). Time: ~4 hours including tests.

### Performance
Current: CommandServer processes request, returns full text response in ~1–3s (infrastructure) or ~3–8s (LLM). Streaming response makes latency transparent to iOS (first token visible in <100ms, not masked by server buffering). Overall response time unchanged; perceived latency improves due to early audio start.

### Verdict
**C+** (Adequate for now, needs streaming upgrade for iOS redesign) — Backend is stable and correct for request-response model. For iOS voice mode redesign to work, MUST add streaming response support (Phase 2 blocker). Current single-response model is acceptable for text-based interactions but insufficient for natural voice mode. Effort: low (backend changes ~4 hours). Risk: low (streaming is standard HTTP feature; no new dependencies). Recommend: Implement `/command/stream` endpoint before iOS Phase 2 begins (in parallel with iOS Phase 1 on-device STT work). Can keep `/command` endpoint for backwards compatibility (CLI, text-mode users).

---
## Last Updated

2026-06-10 (voice pipeline assessment)

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
