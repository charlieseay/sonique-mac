# Sidecar

Embedded Python runtime that ships inside `SoniqueBar.app`.

When the app launches, `SidecarManager` (in `SoniqueBar/Services/`) spawns the CAAL microservices as child processes bound to `127.0.0.1`:

| Process | Source | Port |
|---|---|---|
| `caal-stt` | `charlieseay/cael` → `services/caal-stt/` | 8081 |
| `caal-tts` | `charlieseay/cael` → `services/caal-tts/` | 8082 |
| `caal-agent` | `charlieseay/cael` → `voice_agent.py` (wrapped) | 8080 |

Swift talks to them over local HTTP. No Docker. No network egress. Fully offline after install.

## Packaging

Target toolchain: **py2app** or **pyinstaller** to produce a self-contained Python 3.12 bundle under `Sidecar/bootstrap/`. Final `.app` structure (planned):

```
SoniqueBar.app/Contents/Resources/Sidecar/
  python/               # embedded interpreter
  caal-stt/server.py
  caal-tts/server.py
  caal-agent/...
  models/               # whisper + kokoro + llm weights
```

Bundle size budget: **2–3 GB** including models. Apple Silicon only (M1+). Notarized via the existing Apple Developer cert.

## Status

Scaffolding only. The bootstrap scripts that actually build the embedded Python runtime land during Phase 2 of the packaging plan. See the vault note: `Projects/Lab/Apps/Sonique/Packaging Plan.md`.
