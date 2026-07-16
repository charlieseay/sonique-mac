# Sonique Capabilities

**Last Updated:** 2026-07-16  
**Architecture:** Swift → ClaudeCodeBridge → ask_claude_bedrock → Claude Sonnet 4.5

---

## What Sonique Can Do

Sonique routes voice commands to Claude Bedrock (Sonnet 4.5) with full language model capabilities. There are **no artificial capability restrictions** - if Claude can do it via text, Sonique can do it via voice.

### ✅ Confirmed Working

| Category | Examples |
|----------|----------|
| **Time & Date** | "What time is it?", "What's today's date?" |
| **Calculations** | "What's 234 times 17?", "Convert 50 miles to kilometers" |
| **Information** | "Who wrote 1984?", "What's the capital of France?" |
| **Definitions** | "What does 'ubiquitous' mean?", "Define recursion" |
| **Explanations** | "How does photosynthesis work?", "Explain quantum entanglement" |
| **Comparisons** | "What's the difference between Java and JavaScript?" |
| **Lists** | "List 5 benefits of exercise", "Name the planets in order" |
| **Reasoning** | "If I leave at 3pm and it takes 45 minutes, when do I arrive?" |

### 🔧 Technical Capabilities

Because Sonique uses Claude Bedrock directly, it inherits:

- **200K token context window** (can process long questions)
- **Reasoning and analysis** (not just fact lookup)
- **Multi-step logic** (can break down complex questions)
- **Natural conversation** (understands context and follow-ups)
- **Error handling** (graceful fallback on API failures)

### ❌ Current Limitations

| Limitation | Why | Workaround |
|-----------|-----|------------|
| **No web search** | Claude doesn't have real-time web access | Knowledge cutoff is January 2025 |
| **No file system access** | Bedrock runs in isolation | Can't "read this file" or "check my calendar" |
| **No persistent memory** | Each request is stateless | Can't "remember what I said earlier" across sessions |
| **No tool calling** | ask_claude_bedrock is text-only | Can't execute commands or interact with macOS |

---

## Expanding Capabilities

### Near-Term Improvements (Feasible)

1. **Add MCP tool access** - Wire ClaudeCodeBridge to MCP servers for:
   - File operations (read/write vault notes)
   - Calendar queries (check appointments)
   - System info (battery level, network status)
   - Slack messaging (send/read messages)

2. **Add conversation memory** - Store recent exchanges in SQLite:
   - Load last 5 exchanges into prompt
   - "What did I ask you earlier?" works
   - Per-user conversation history

3. **Add web search fallback** - When Claude doesn't know:
   - Detect "I don't have current information" pattern
   - Route to DuckDuckGo/Brave search
   - Summarize results via Claude

### Long-Term Enhancements (Requires Architecture Changes)

1. **Proactive suggestions** - Sonique notices patterns and offers help:
   - "You usually check email at 9am - want me to check now?"
   - Requires background processing loop

2. **Multi-step workflows** - Chain actions together:
   - "Add meeting to calendar and send Slack notification"
   - Requires tool orchestration layer

3. **Context awareness** - Know what's happening on the Mac:
   - "Summarize this document" (grabs frontmost window)
   - Requires accessibility permissions + screen reading

---

## Testing Expanded Capabilities

### Test Commands (Beyond Time/Date)

Try these to verify Sonique's range:

```bash
# Calculations
curl -X POST http://localhost:8890/command \
  -H "Authorization: Bearer $(cat /Volumes/data/secrets/sonique_auth_token)" \
  -H "Content-Type: application/json" \
  -d '{"text": "If I invest $5000 at 7% annual interest for 10 years, how much will I have?"}'

# Explanations
curl -X POST http://localhost:8890/command \
  -H "Authorization: Bearer $(cat /Volumes/data/secrets/sonique_auth_token)" \
  -H "Content-Type: application/json" \
  -d '{"text": "Explain how HTTPS certificates work in simple terms"}'

# Reasoning
curl -X POST http://localhost:8890/command \
  -H "Authorization: Bearer $(cat /Volumes/data/secrets/sonique_auth_token)" \
  -H "Content-Type: application/json" \
  -d '{"text": "I have 3 apples. I buy 5 more. I eat 2. How many do I have left?"}'

# Lists
curl -X POST http://localhost:8890/command \
  -H "Authorization: Bearer $(cat /Volumes/data/secrets/sonique_auth_token)" \
  -H "Content-Type: application/json" \
  -d '{"text": "Give me 5 tips for better sleep"}'
```

---

## Architecture Notes

**Current flow:**
```
Voice → HTTP POST → CommandServer → ClaudeCodeBridge → ask_claude_bedrock → Claude Sonnet 4.5
```

**With MCP tools (future):**
```
Voice → HTTP POST → CommandServer → ClaudeCodeBridge (+ MCP) → Claude + tool execution → Response
```

**Key insight:** The bottleneck isn't Sonique's code - it's the `ask_claude_bedrock` CLI being text-only. To add tool calling, we'd need to:
1. Switch from `ask_claude_bedrock` to direct Bedrock Messages API
2. Implement tool calling loop (like Anthropic SDK's `tool_runner`)
3. Wire MCP servers into the tool registry

---

## Related Files

- **Architecture:** `ARCHITECTURE-SIMPLIFIED.md`
- **Handoff:** `Projects/Sonique/HANDOFF.md`
- **Bridge:** `SoniqueBar/Services/ClaudeCodeBridge.swift`
- **Server:** `SoniqueBar/Services/CommandServer.swift`
