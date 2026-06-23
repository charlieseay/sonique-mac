# Quinn (Sonique) Issues & Task Dispatch

**Date:** 2026-06-23  
**Status:** 6 capability gaps identified, tasks dispatched to Helmsman

## Current Issues

### 1. **Conversational Response Rewrite**
Quinn is responding with file paths, task numbers, and technical output. Need pure voice-first, natural language responses.
- Example: Should say "I've dispatched the tasks" not "I've created TRANSCRIPT_ISSUES.md at /Users/..."
- Remove all file paths, line numbers, and technical scaffolding from voice output

### 2. **Response Latency Optimization**
Wake-up and response time is too slow. Target <200ms for pattern-based queries (time, date, device control).
- Use native-first layer (NativeIntents.swift)
- Ollama for system LLM if available
- Bundled Phi-3 model as fallback
- Network APIs last resort

### 3. **Autonomous Problem Detection & Task Dispatch**
Quinn should catch infrastructure issues and automatically create tasks instead of waiting for user direction.
- Monitor Helmsman queue, Docker health, disk space
- Create task briefs automatically when issues detected
- Send to team without requiring user confirmation

### 4. **Self-Diagnosis & Capability Gap Detection**
Quinn should identify missing features and auto-task them (like we just did with Helmsman POST).
- Read CAPABILITIES.md
- Identify gaps vs actual implementation
- POST improvements to Helmsman automatically

### 5. **Voice-as-Approval Action Framework**
User voice commands should trigger immediate action without confirmation loops.
- "Dispatch tasks" → POST to Helmsman
- "Send to Slack" → POST to Slack API
- "Create a note" → Write to vault
- No "should I..?" questions back to user

### 6. **Persistent Memory Sync**
Quinn's identity, rules, and persona should persist across restarts and devices.
- IDENTITY.md, RULES.md, SOUL.md, CAPABILITIES.md stored in iCloud
- Desktop and mobile memory synced
- Recent lessons and directives preserved

## Success Criteria

- ✅ Quinn speaks naturally without technical output (Build 33)
- ⏳ Response time <1 second for common queries (partially — fast-path for current_time works)
- ❌ Automatically creates and dispatches tasks when detecting issues
- ❌ Identifies own capability gaps and tasks improvements
- ❌ Executes on voice commands without asking permission

## Status (2026-06-23, Build 33)

✅ **FIXED:** Priority 1 — Conversational response rewrite
- New voice-first system prompt at SoniqueBar/Services/CommandServer.swift:635-665
- Eliminates file paths, task numbers, technical scaffolding from responses
- Tested and working: "Tell me a joke" → brief, natural response
- Tested and working: "What do we have on tap" → conversational summary

⏳ **PARTIAL:** Priority 2 — Response latency
- Fast-path exists for current_time (handled at line 620)
- Most queries still hit ask_claude (2-3 second latency)
- Need to expand fast-path coverage (weather, simple math, device control)

❌ **NOT STARTED:** Priority 3 — Autonomous task dispatch
- BackgroundMonitor exists (60s health checks) but doesn't auto-dispatch tasks
- Docker self-healing works (auto-restarts unhealthy containers)
- Need to add: helmsman queue monitoring → auto-task creation

❌ **NOT STARTED:** Priority 4 — Voice-as-approval framework
- Still pattern-matching some requests (IntentRouter)
- Need to trust LLM judgment more, reduce confirmation loops

## Known Issues

**Task creation broken:** When user says "create tasks", Quinn fails with:
```
Failed to create task: The operation couldn't be completed. (SoniqueBar.TaskDispatcher.DispatchError error 1.)
```
Root cause unknown — IntentRouter.createTask() exists but appears never called. Needs investigation.

## What Claude Should Focus On Next

1. **Priority 2:** Expand fast-path coverage for common queries (<200ms responses)
2. **Priority 3:** Autonomous task dispatch when detecting issues
3. **Fix:** Debug task creation failure (DispatchError error 1)
4. **Priority 4:** Voice-as-approval framework
