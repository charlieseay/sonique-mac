# SoniqueBar (macOS)

Menu bar controller for CAAL: Docker **networked** stack or **embedded** sidecar runtime, Home Assistant hooks, and iOS onboarding QR.

## Quick Start scan (first install)

The Settings/Onboarding view now includes a **Quick Start** scanner to reduce manual setup. It probes local prerequisites and pre-fills suggestions:

- Docker availability
- Ollama availability
- CLI tools (`claude`, `gemini`, `cursor`, `gh`)
- common CAAL repo paths
- common Obsidian vault path

This is intentionally local-only and safe to run repeatedly. It does not read secrets.

## Adaptive settings layout

Onboarding/Settings is now scrollable and resizable (`min/ideal/max` sizing) so controls remain reachable on constrained remote displays (for example Jump Desktop on iPad).

## Onboarding wizard + doctor

Quick Start now runs as a step-based wizard:

- Mode
- Models
- Capabilities
- Knowledge
- Doctor

The Capabilities step persists host/bridge access preferences (calendar, contacts, mail, files, iOS bridge fallback). The Doctor step now runs local probes for frontend/backend reachability, Docker daemon, CLI readiness/auth, and current permission states for Contacts/Calendar.

Profiles can also be exported/imported as JSON from the Quick Start panel to move setup between devices or restore known-good local configs quickly.

Doctor rows now include context-aware **Fix** actions for common local blockers (privacy panes, Docker app launch, CLI auth/install docs). Quick Start can also export a runtime contract JSON snapshot for Helmsman/team tooling alignment. Phase 6 adds deeper live probes for sidecar STT/TTS health, backend `/health`, and routing policy parity against the selected local provider.

Phase 7 adds an opt-in **Preflight repair** action that re-scans local prerequisites, re-starts the selected runtime path (embedded sidecar or networked CAAL), and reruns Doctor checks to confirm readiness before save/deploy.

Phase 8 adds direct permission-request remediation actions for not-determined Contacts/Calendar states and a Doctor check that verifies the published runtime contract path exists for consumer tooling.

## Build

Open `SoniqueBar.xcodeproj` in Xcode (or generate via XcodeGen if you add a spec). Scheme: **SoniqueBar**, destination: **My Mac**.

## CAAL directory

Point Settings at the cloned CAAL repo. SoniqueBar can start/stop the compose stack or run the bundled sidecar per deployment mode.

## LLM routing UI (task #284, prefs only)

SoniqueBar stores routing preferences in `UserDefaults` (keys in `LLMRoutingStorageKeys` in `SoniqueBar/Services/MacSettings.swift`). CAAL consumes snake_case fields (`LLMRoutingCAALKeys`) via `settings.json` and optional `.env` — see vault note `Projects/Sonique/NVIDIA Provider UI — Task 284 Handoff.md`.

Placeholder **server** `.env` lines (no real secrets in repo or docs). Swift names for these keys live in `LLMRoutingEnvVarNames` next to `LLMRoutingCAALKeys` in `SoniqueBar/Services/MacSettings.swift`.

```bash
NVIDIA_FEATURE_ENABLED=false
NVIDIA_BASE_URL=<nvidia-base-url>
NVIDIA_MODEL=<nvidia-model-placeholder>
# NVIDIA_API_KEY=<nvidia-api-key>
```

Client UI never stores NVIDIA API keys; base URL is optional text when the experimental toggle is on.

## Sidecar

See `Sidecar/README.md` for the embedded runtime layout and the same NVIDIA placeholder block.
