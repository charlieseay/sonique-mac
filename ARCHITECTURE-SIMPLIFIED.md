# Sonique Bar - Simplified Architecture (Option B)

**Date:** 2026-07-16  
**Decision:** Simplified personal-use design (Option B from assessment)

---

## Overview

SoniqueBar is a **macOS menu bar voice assistant** that routes commands directly to Claude Bedrock with bearer token authentication. This is the simplified architecture chosen for personal use.

**Key principle:** Keep it simple. No Python backend, no connector registry, no plugin system. Just Swift → Claude.

---

## Current Architecture

```
┌────────────────────────────────────────┐
│       SoniqueBar.app (Swift)           │
│  ┌──────────────────────────────────┐  │
│  │  SoniqueBarApp                   │  │  Menu bar UI
│  │  CommandServer (HTTP :8890)      │  │  ← Bearer token auth
│  │  ClaudeCodeBridge                │  │  → ask_claude_bedrock CLI
│  │  SoniqueBrain                    │  │  iCloud-synced personality
│  └──────────────────────────────────┘  │
└────────────────────────────────────────┘
                ↓ Bearer token
         [ask_claude_bedrock CLI]
                ↓
         [Claude Bedrock API]
```

---

## Components

### SoniqueBarApp.swift
- Menu bar UI with status indicator
- Displays: online/offline, request count, last command
- Actions: open logs, test connection, settings, quit

### CommandServer.swift (Port 8890)
- HTTP server for voice commands
- **Security:** Bearer token authentication (all endpoints except `/health`)
- **Endpoints:**
  - `GET /health` - No auth required
  - `POST /command` - Execute voice command (returns JSON)
  - `POST /command/stream` - Streaming response (NDJSON chunks)
  - `POST /synthesize` - TTS generation (macOS `say` command)

### ClaudeCodeBridge.swift
- Routes commands to `ask_claude_bedrock` CLI
- **Now uses SoniqueBrain** for personality (iCloud-synced)
- Timeout: 15 seconds
- Fallback: Returns "Assistant unavailable" on failure

### SoniqueBrain.swift
- iCloud-backed persona system
- Files synced via iCloud Drive:
  - `IDENTITY.md` - Who Quinn is
  - `RULES.md` - Behavioral rules
  - `SOUL.md` - Evolving traits
  - `assistant.json` - Name configuration
- Quota management: 50MB per device
- Supports: Desktop + mobile (mobile read-only)

---

## Security

### Authentication
- **Bearer token:** Required for all non-health endpoints
- **Token storage:** `/Volumes/data/secrets/sonique_auth_token`
- **Auto-generated:** If token doesn't exist, creates UUID on first launch

### Removed
- ❌ `/config` endpoint (previously exposed ElevenLabs API key)
- ❌ Python service (quinn-brain-svc.py) - security surface reduced

### Resource Management
- ✅ Connection leak fixed (error handling in `handleConnection`)
- ✅ Temp file leak fixed (defer cleanup in `handleSynthesize`)

---

## What Was Removed (Option B Decision)

### Deleted Python Backend
- ❌ `quinn-brain-svc.py` (HTTP server on port 5912)
- ❌ `connectors/` directory (5 connectors: Helmsman, Docker, NotebookLM, Vault, HomeAssistant)
- ❌ `async_handler.py` (async task management)
- ❌ Connector registry system

### Rationale
- **Orphaned code:** Python service was never called by Swift app
- **Complexity:** Dual LLM routing paths caused confusion
- **Personal use:** Don't need App Store plugin architecture
- **Simplicity:** Direct path (Swift → Bedrock) is clearer

---

## Deployment

### macOS Menu Bar App
- Built with SwiftPM (`swift build`)
- Runs as user agent (no LaunchDaemon)
- Logs: `/tmp/soniquebar.log`

### Configuration
- **Auth token:** `/Volumes/data/secrets/sonique_auth_token`
- **iCloud profile:** `iCloud.com.seayniclabs.sonique/Documents/SoniqueProfiles/`

---

## Future Considerations

### If App Store Path Needed Later
See `ARCHITECTURE.md` (original) for full plugin architecture design with:
- Settings UI for LLM/connector configuration
- Plugin bundle loader (`.soniquePlugin`)
- Marketplace scaffold
- Multi-provider LLM routing

**Current decision:** Keep it simple for personal use. Revisit if distribution is needed.

---

## API Usage

### Voice Command
```bash
curl -X POST http://localhost:8890/command \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/json" \
  -d '{"text": "What time is it?"}'
```

### Health Check
```bash
curl http://localhost:8890/health
# No auth required
```

### TTS Synthesis
```bash
curl -X POST http://localhost:8890/synthesize \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/json" \
  -d '{"text": "Hello world"}' \
  --output audio.aiff
```

---

## Lessons Learned

1. **Read-before-modify:** Assessment found 5 critical issues before any code changes
2. **Security-first:** Bearer token auth blocks LAN-based command injection
3. **Resource management:** Always use `defer` for cleanup (temp files, connections)
4. **Simplicity wins:** Deleted 1,293 lines of unused Python code
5. **iCloud sync:** SoniqueBrain provides cross-device personality without backend

---

## Related Files

- **Original architecture:** `ARCHITECTURE.md` (full App Store design)
- **Assessment:** `Projects/Sonique/Sonique Assessment - 2026-07-16.md`
- **Component map:** `Projects/Sonique/component-map-2026-07-16.html`
- **Handoff:** `Projects/Sonique/HANDOFF.md`
