# Sonique Latency Improvements — Handoff

**Date:** 2026-06-25  
**Owner:** Quinn  
**Status:** Partially scoped, not implemented

## Objective

Improve Sonique conversation latency by:
1. **Stream partial responses to TTS faster** — start playing audio within 200ms even if full response takes longer
2. **Expand native pattern-matching** — answer small talk locally without LLM calls (clarifications, acknowledgments, casual responses)
3. **Integrate Ollama** — use local inference for simple conversational queries instead of network API

## Current State

**Architecture mapped:**
- `CommandServer.swift` — response streaming partially implemented, can be optimized
- `NativeIntents.swift` — currently handles time/date/device control, can expand to small talk
- TTS streaming is in place but not fully optimized for partial/chunked responses
- Ollama not running locally (verified), but integration path is clear

**What's NOT done:**
- Small talk patterns not added to NativeIntents
- Ollama service integration not wired into CommandServer
- End-to-end streaming optimization not tested
- No validation that responses feel snappier

## Files to Touch

1. `CommandServer.swift` — Add Ollama check, optimize streaming timing
2. `NativeIntents.swift` — Expand pattern set for small talk
3. `OllamaService.swift` — New file for Ollama integration (optional if Ollama stays offline)

## Implementation Checklist

- [ ] Add small talk patterns to NativeIntents:
  - "Are you okay?" / "How are you?" → "Doing well, what can I do?"
  - "What are you up to?" → "Just helping you with whatever's next"
  - Clarifications: "What do you mean?" → "Can you say that again?"
  - Acknowledgments: "Got it", "Thanks", "Cool" → appropriate responses
- [ ] Optimize CommandServer streaming to send first chunk to TTS within 200ms
- [ ] Add OllamaService with health check (optional)
- [ ] Wire Ollama into CommandServer with fallback to Bedrock
- [ ] Test conversation flow for snappiness improvement
- [ ] Measure latency before/after (target: first audio within 200ms)

## Validation

Test these scenarios:
1. **Quick question:** "What time is it?" → Should be instant (native fast-path)
2. **Small talk:** "How are you?" → Should be local pattern, no LLM call, <100ms
3. **Conversational:** "What should I do about X?" → Should stream first sentence within 200ms
4. **Ollama (if running):** Simple questions should use local inference instead of Bedrock

## Blockers

- Helmsman webhook 404 on task dispatch (workflow not active) — not critical for this work

## Notes for Claude

- This is ~1-2 hours of implementation + testing, not a full refactor
- Focus on quick wins first: expand NativeIntents, then optimize streaming timing
- Ollama integration is nice-to-have but can be skipped if it's getting complex
- Charlie wants to *feel* the difference in conversation speed, not just see metrics

---

**When you pick this up:**
1. Read this file
2. Check CommandServer and NativeIntents structure (already mapped above)
3. Start with NativeIntents expansion — lowest risk, highest impact
4. Test in ConversationClient or via voice if possible
5. Commit with clear commit message
6. Update this handoff with what you shipped
