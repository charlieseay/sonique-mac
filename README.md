# SoniqueBar (macOS)

Menu bar controller for CAAL: Docker **networked** stack or **embedded** sidecar runtime, Home Assistant hooks, and iOS onboarding QR.

## Build

Open `SoniqueBar.xcodeproj` in Xcode (or generate via XcodeGen if you add a spec). Scheme: **SoniqueBar**, destination: **My Mac**.

## CAAL directory

Point Settings at the cloned CAAL repo. SoniqueBar can start/stop the compose stack or run the bundled sidecar per deployment mode.

## LLM routing UI (task #284, prefs only)

SoniqueBar stores routing preferences in `UserDefaults` (keys in `LLMRoutingStorageKeys` in `SoniqueBar/Services/MacSettings.swift`). CAAL consumes snake_case fields (`LLMRoutingCAALKeys`) via `settings.json` and optional `.env` — see vault note `Projects/Sonique/NVIDIA Provider UI — Task 284 Handoff.md`.

Placeholder **server** `.env` lines (no real secrets in repo or docs):

```bash
NVIDIA_FEATURE_ENABLED=false
NVIDIA_BASE_URL=<nvidia-base-url>
NVIDIA_MODEL=<nvidia-model-placeholder>
# NVIDIA_API_KEY=<nvidia-api-key>
```

Client UI never stores NVIDIA API keys; base URL is optional text when the experimental toggle is on.

## Sidecar

See `Sidecar/README.md` for the embedded runtime layout and the same NVIDIA placeholder block.
