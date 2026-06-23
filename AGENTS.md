# Agent Roster

Quinn can dispatch tasks to real automation agents. This file lists **actual working agents** that can execute tasks autonomously.

## Quick Reference

| Owner | Use For | Speed | Cost |
|-------|---------|-------|------|
| **AIDER-GEM** | Code/file editing (Swift, TS, Python, configs) | Medium | Free (Gemini subscription) |
| **NVIDIA-FAST** | Quick research, log parsing, simple analysis | <30s | Free (NVIDIA tier) |
| **NVIDIA-BAL** | Deeper investigation, multi-step research | 30s-2min | Free (NVIDIA tier) |
| **NVIDIA-THINK** | Complex reasoning, decision trees, planning | 2-5min | Free (NVIDIA tier) |
| **CLAUDE** | Architecture, design docs, coordination | Variable | Subscription (Claude Max) |
| **CHARLIE** | Manual tasks (credentials, recordings, approvals) | Human | N/A |

## Detailed Capabilities

### AIDER-GEM
**What it does:** Direct file and code editing
**Best for:**
- Swift/TypeScript/Python code changes
- Config file updates (.env, .plist, .json)
- Multi-file refactoring
- Test writing

**How Quinn routes:** Any task requiring file modifications or code implementation
**Example:** "Add a new endpoint to the API" → AIDER-GEM

---

### NVIDIA-FAST
**What it does:** Fast research and analysis using NVIDIA free tier
**Best for:**
- Quick fact lookup
- Log file parsing
- Simple grep/search operations
- Status checks

**How Quinn routes:** Quick information gathering that doesn't need deep reasoning
**Example:** "What port is Bridge running on?" → NVIDIA-FAST

---

### NVIDIA-BAL
**What it does:** Balanced research with deeper investigation
**Best for:**
- Multi-step research
- Cross-file analysis
- Dependency investigation
- Pattern finding across codebase

**How Quinn routes:** Research tasks requiring 2-5 steps of investigation
**Example:** "Find all places we use the old API endpoint" → NVIDIA-BAL

---

### NVIDIA-THINK
**What it does:** Deep reasoning and complex problem solving
**Best for:**
- Architecture decisions
- Debug complex issues
- Design tradeoff analysis
- Planning multi-phase work

**How Quinn routes:** Tasks requiring careful reasoning and tradeoff evaluation
**Example:** "Should we use WebSockets or Server-Sent Events for this?" → NVIDIA-THINK

---

### CLAUDE
**What it does:** High-quality design, documentation, and coordination
**Best for:**
- Writing tech specs
- Architecture design
- Complex documentation
- Multi-agent task coordination
- Final quality review

**How Quinn routes:** Design-first tasks or work requiring highest quality output
**Example:** "Design the cross-device sync architecture" → CLAUDE

---

### CHARLIE
**What it does:** Human-only tasks
**Best for:**
- Recording interactions (Playwright Codegen)
- Adding credentials/secrets
- Manual approvals
- Tasks requiring UI interaction

**How Quinn routes:** Anything requiring human judgment or manual steps
**Example:** "Record the Freelancer login flow with Playwright" → CHARLIE

---

## Invalid Owners (Don't Use)

These are **NOT real agents** and tasks assigned to them will sit unprocessed:

- ❌ `ENGINEERINGHOOK` - placeholder, doesn't exist
- ❌ `nvidia-agent` - old name, use specific lanes (FAST/BAL/THINK)
- ❌ `ENGINEERING` - vague, no executor
- ❌ `GEM` / `CURSOR` - external tools, require manual relay

## When Owner is `null`

If Quinn can't determine the right agent, it sets `owner: null` and the task goes to the manual queue for you to assign.

**Better:** Help Quinn choose by being specific:
- "Write code to..." → AIDER-GEM
- "Research whether..." → NVIDIA-BAL
- "Design the..." → CLAUDE
- "I need to record..." → CHARLIE

---

## Testing Task Dispatch

Try: **"Create a small task to test task dispatch to NVIDIA-FAST"**

Quinn should:
1. Extract metadata with `owner: "NVIDIA-FAST"`
2. Generate a complete 18-section brief
3. Dispatch via `/webhook/task-dispatch`
4. Return the task number

You can verify on Bridge Mission Manifest or query:
```bash
curl -s "http://localhost:5682/tasks?status=pending&owner=NVIDIA-FAST"
```

---

**Last updated:** 2026-06-23 (Build 25+)
