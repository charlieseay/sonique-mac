# Sonique Phase 6 Enhancement Plan

**Date:** 2026-07-16  
**Goal:** Add all optional enhancements + MCP server integration

---

## Phase 6A: MCP Server Foundation

### Prerequisites Completed
- ✅ Expo MCP installed (`claude mcp add expo`)
- ✅ ASC MCP installed (`npm install -g @pofky/asc-mcp`)  
- ⚠️ ASC credentials need full `.p8` key (currently incomplete)

### Architecture Decision

**Current:** `ClaudeCodeBridge` → `ask_claude_bedrock` CLI (text-only, no tool calling)

**Option 1: Direct Bedrock Messages API**
- Replace CLI with AWS SDK for Swift
- Implement tool calling loop
- Register MCP tools manually
- **Pros:** Full control, native Swift
- **Cons:** Complex implementation, manual MCP integration

**Option 2: Route through Claude Desktop CLI**
- Change from `ask_claude_bedrock` to `claude` CLI
- Claude CLI has built-in MCP access
- **Pros:** Immediate MCP tool access, simpler
- **Cons:** Requires Claude Desktop running, less control

**Recommendation:** Start with Option 2 (Claude CLI routing) for fast MCP validation, then optionally migrate to Option 1 later.

### Implementation Steps (Option 2)

1. **Update ClaudeCodeBridge.swift:**
   ```swift
   // Change executable from:
   /Users/charlieseay/.local/bin/ask_claude_bedrock
   
   // To:
   /Users/charlieseay/.local/bin/claude
   
   // With arguments:
   ["-p", prompt]  // headless mode
   ```

2. **Test MCP tool access:**
   - Verify Expo MCP tools available
   - Test with: "List my Expo projects"
   - Test ASC when credentials ready

3. **Update personality context:**
   - Add MCP tool awareness to IDENTITY.md
   - Document available capabilities

---

## Phase 6B: Conversation Memory

### Database Schema

```sql
CREATE TABLE conversations (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id TEXT NOT NULL,
    timestamp INTEGER NOT NULL,
    role TEXT NOT NULL,  -- 'user' or 'assistant'
    content TEXT NOT NULL
);

CREATE INDEX idx_session_timestamp ON conversations(session_id, timestamp DESC);
```

### Implementation

1. Create `ConversationMemory.swift` service
2. Log all `/command` and `/command/stream` exchanges
3. Load last 5 exchanges in ClaudeCodeBridge prompt
4. Add `/clear-memory` endpoint to CommandServer

### Storage Location
`~/Library/Application Support/SoniqueBar/conversations.db`

---

## Phase 6C: Web Search Fallback

### Detection Pattern

Monitor for responses containing:
- "I don't have current information"
- "My knowledge cutoff is"
- "I cannot access real-time"
- "As of my last update"

### Implementation

1. Create `WebSearchService.swift`
2. Use DuckDuckGo API (no auth required): `https://api.duckduckgo.com/?q={query}&format=json`
3. On detection:
   - Extract search query from original user request
   - Fetch top 3-5 results
   - Re-prompt Claude with: "Based on these search results: [results], answer: [original question]"

### Fallback Chain
1. Try Claude directly
2. If uncertain → web search
3. Summarize results via Claude

---

## Phase 6D: ElevenLabs TTS

### API Setup

- Endpoint: `https://api.elevenlabs.io/v1/text-to-speech/{voice_id}`
- Auth: `xi-api-key` header
- Voice ID: Store in config (default: Rachel)

### Implementation

1. Update `handleSynthesize()` in CommandServer
2. Replace `Process("/usr/bin/say")` with ElevenLabs API call
3. Stream audio back (same AIFF format or MP3)
4. Add voice selection parameter

### Comparison Test

Side-by-side audio samples:
- macOS `say`: "Hello, this is Sonique using system text to speech"
- ElevenLabs: Same text
- Document quality difference

---

## Phase 6E: iOS Client

### New Project Structure

```
sonique-ios/
├── SoniqueApp.swift           # App entry point
├── Views/
│   ├── MainView.swift         # Voice interaction UI
│   └── SettingsView.swift     # Config (server URL, auth token)
├── Services/
│   ├── VoiceRecognition.swift # Speech → text
│   ├── APIClient.swift        # HTTP client for CommandServer
│   └── AudioPlayer.swift      # Streaming response playback
└── Models/
    └── CommandResponse.swift  # Codable models
```

### Features

1. **Voice Input:** iOS Speech Recognition → text
2. **HTTP Client:** POST to `http://192.168.68.80:8890/command/stream`
3. **Streaming Playback:** NDJSON chunks → TTS playback
4. **Auth:** Bearer token from settings
5. **UI:** Waveform indicator, transcript display

### Testing Flow

1. Tap mic button → record voice
2. Send to CommandServer
3. Display streaming response
4. Play audio chunks as they arrive

---

## Phase 6F: NotebookLM Integration

Throughout all phases, update the NotebookLM projects notebook:

```bash
# Query current state
nlm notebook query 201885bd-9c21-4d6d-ad7d-bb69e72d11df "What is the status of Sonique?"

# After each phase completion, update with new content
nlm source add 201885bd-9c21-4d6d-ad7d-bb69e72d11df \
  --text "$(cat Projects/Sonique/HANDOFF.md)" \
  --title "Sonique Handoff - Phase 6"
```

---

## Token Management

**Current:** 110K/200K tokens used

**Strategy:**
- Checkpoint after each phase (6A, 6B, 6C, 6D, 6E)
- Update NotebookLM after each checkpoint
- Compact if approaching 125K

---

## Testing Plan

### After 6A (MCP Integration)
- ✅ Ask: "List my Expo projects"
- ✅ Ask: "What Expo libraries are available for maps?"
- ✅ Ask: "Show my App Store Connect app status" (when ASC ready)

### After 6B (Conversation Memory)
- ✅ Ask: "What's the weather?"
- ✅ Ask: "What did I just ask you?"
- ✅ Verify database contains both exchanges

### After 6C (Web Search)
- ✅ Ask: "What happened in the news today?"
- ✅ Verify web search triggered
- ✅ Verify summarized results returned

### After 6D (ElevenLabs TTS)
- ✅ Generate same text with macOS and ElevenLabs
- ✅ Compare audio quality
- ✅ Document preference

### After 6E (iOS Client)
- ✅ Full voice loop: speak → hear response
- ✅ Test on iPhone
- ✅ Verify streaming works

---

## Next Actions

1. **Start with 6A:** Route ClaudeCodeBridge through `claude` CLI
2. **Test MCP access:** Verify Expo tools work
3. **Proceed to 6B:** Implement conversation memory
4. **Continue sequentially** through remaining phases

**Estimated total work:** 5-6 phases × 15K tokens each = 75-90K tokens (fits in remaining budget with compaction)
