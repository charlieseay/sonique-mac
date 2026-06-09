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
