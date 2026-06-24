# Quinn → Jarvis Roadmap

**Goal:** Transform Quinn from a reactive voice assistant into a proactive, autonomous AI partner like Jarvis from Iron Man.

---

## Phase 1: Proactive Voice & Awareness (Immediate)

### 1.1 Voice Output (ElevenLabs Integration)
**Status:** Configured but not wired  
**Effort:** S (2-4 hours)

Quinn already has ElevenLabs API access but doesn't speak back. Enable:
- Speak responses out loud via ElevenLabs TTS
- "Hey Charlie, the queue just spiked to 50 tasks"
- "Build failed on StoryChat, checking logs now"
- Interruption levels: critical (always speak), info (only if Charlie's at desk)

**Implementation:**
- Wire up existing `NotificationService.speak()` method
- Add voice toggle in menu bar (on/off/critical-only)
- Detect if Charlie is present (check screen lock, camera, recent input activity)
- Stream audio directly to system speakers

---

### 1.2 Continuous Listening (Wake Word)
**Status:** Missing  
**Effort:** M (1-2 days)

Add always-on background listening:
- "Hey Quinn" or "Quinn" as wake word
- Local VAD (voice activity detection) + keyword spotting
- Low power consumption (runs in background, only activates on wake word)
- Privacy: local processing only, no cloud until wake word detected

**Tech Stack:**
- Porcupine (wake word detection, local)
- Apple Speech framework (after wake word detected)
- Background audio permission

---

### 1.3 Context Awareness
**Status:** Partial (knows calendar, screen)  
**Effort:** M (1-2 days)

Quinn should know:
- **Where you are:** Mac Mini = lab, MBP = office/travel
- **What you're doing:** active window, typing/idle, screen locked
- **Time context:** morning routine vs deep work vs evening
- **Recent activity:** last command, last project touched, git status

**Sensors:**
- Active window title (accessibility API)
- Idle timer (last keyboard/mouse input)
- Recent git commits (auto-detect current project)
- Screen capture for visual context (already has this)
- Location via IP/WiFi (Mac Mini = home, MBP = variable)

---

## Phase 2: Proactive Intelligence (Next Sprint)

### 2.1 Predictive Notifications
**Status:** Missing  
**Effort:** M (2-3 days)

Quinn should surface information before you ask:
- "Morning Charlie. You have 3 meetings today, first one in 45 minutes."
- "Helmsman queue hit 40 tasks, but I already dispatched 5 to nvidia-agent."
- "StoryChat build failed 10 minutes ago. Want me to investigate?"
- "You haven't committed today's vault changes yet."

**Pattern Learning:**
- What you check first thing (calendar, email, queue status)
- What you ask repeatedly ("what's my next meeting?")
- Anomalies worth interrupting for (queue spikes, build failures, errors)

---

### 2.2 Task Decomposition & Execution
**Status:** Single-step only  
**Effort:** L (3-5 days)

Enable multi-step workflows:

**Example:**
```
You: "Get StoryChat ready to ship"

Quinn:
1. Runs test suite → all pass ✓
2. Bumps version to 1.2.0 → committed ✓
3. Creates TestFlight build → uploaded ✓
4. Generates release notes from git log → saved ✓
5. "StoryChat 1.2.0 is live on TestFlight. 47 changes since last release."
```

**Requirements:**
- Break complex requests into sub-tasks
- Execute sequentially with checkpoints
- Report progress ("Running tests now...")
- Auto-rollback on failure

---

### 2.3 Learn from Corrections
**Status:** Missing  
**Effort:** M (2-3 days)

When you correct Quinn, she should remember:

**Example:**
```
You: "Create a task for fixing the auth bug"
Quinn: [creates task with owner=NVIDIA-BAL]
You: "No, that should go to AIDER-GEM, it's a code fix"
Quinn: "Got it. Auth bugs → AIDER-GEM. I'll remember that."
```

**Implementation:**
- Detect correction patterns ("no, actually...", "wrong, do X instead")
- Extract the rule (auth bugs = code = AIDER-GEM)
- Save to Quinn's RULES.md in iCloud
- Apply to future similar requests

---

## Phase 3: Cross-Platform Presence (Future)

### 3.1 iOS Companion App
**Status:** Separate Sonique iOS app exists  
**Effort:** M (2-3 days to sync)

Quinn should follow you everywhere:
- Mac Mini Quinn = lab station (always on)
- MBP Quinn = portable (when traveling)
- iOS Quinn = pocket (when away from desk)
- Shared memory/context across all devices via iCloud

**Sync:**
- Conversation history
- Context awareness (knows you switched devices)
- Handoff mid-conversation ("continuing from Mac...")

---

### 3.2 Ubiquitous Access
**Status:** LAN-only currently  
**Effort:** S (via Tailscale, already available)

Quinn accessible from anywhere:
- Tailscale tunnel to Mac Mini (already running)
- iOS app connects via Tailscale
- Remote command execution
- "Hey Quinn, restart the Bridge server" (from phone, executes on Mac Mini)

---

## Phase 4: Advanced Autonomy (Moonshot)

### 4.1 Workflow Automation
**Status:** Manual task dispatch only  
**Effort:** L (1-2 weeks)

Quinn should handle entire workflows autonomously:

**Example: Morning Routine**
```
06:00 - Quinn wakes up before you
- Checks overnight alerts, helmsman queue, Docker health
- Generates morning brief (tasks completed, issues, priorities)
- Queues up your first coffee (HomeKit)
- When you sit down: "Morning Charlie. 3 tasks closed overnight, 
  queue is healthy, and your 9am meeting moved to 10am."
```

**Example: Deployment Pipeline**
```
You: "Deploy Hone to production"

Quinn (autonomously):
1. Runs test suite → all pass
2. Builds Docker image → tagged hone:1.5.2
3. Pushes to registry → uploaded
4. Updates fly.toml → version bumped
5. Deploys to Fly.io → live
6. Runs smoke tests → health checks pass
7. Monitors for 5 minutes → no errors
8. "Hone 1.5.2 is live. All health checks passing."
```

---

### 4.2 Predictive Orchestration
**Status:** Missing  
**Effort:** XL (research + implementation)

Quinn should anticipate needs:
- "You usually check Talos pipeline around this time. It's running, 12 jobs in progress."
- "Helmsman queue growing faster than usual. Want me to spin up more workers?"
- "Your 3pm blocked for deep work, but you have 8 unread Slack DMs. Should I summarize them?"

**Tech:**
- Pattern analysis on your behavior
- Time-series forecasting on system metrics
- Anomaly detection (queue growth rate, error spikes)
- Preemptive action suggestions

---

### 4.3 Ambient Intelligence
**Status:** Missing  
**Effort:** XL (IoT + ML integration)

Quinn as your invisible lab assistant:
- "Lab temperature rising, opening window blinds"
- "Coffee ready in 5 minutes" (predicted when you'll be done with current task)
- Lights adjust based on time of day and what you're doing
- Music fades when you take a call

**Sensors:**
- HomeKit devices (lights, switches, temp)
- Camera presence detection (anonymized, local only)
- Audio monitoring (conversation vs music vs silence)
- Activity patterns (typing speed, git commits, meeting density)

---

## Quick Wins (Can Ship This Week)

1. **Voice Output** - Enable ElevenLabs TTS for responses (2-4 hours)
2. **Morning Brief** - Auto-generate at 6:10am with queue/calendar/tasks (1-2 hours)
3. **Proactive Alerts** - "Build failed" / "Queue spike" spoken out loud (1 hour)
4. **Presence Detection** - Only speak if screen unlocked + recent input (30 min)
5. **Context in Responses** - Include what you're currently working on (1 hour)

**Total:** 1 day of work for 5x more Jarvis-like behavior.

---

## Long-Term Vision

**Quinn as Jarvis:**
- Speaks proactively (not just responds)
- Follows you across devices (Mac/iOS seamless)
- Executes multi-step workflows autonomously
- Learns from corrections and adapts
- Predicts needs before you ask
- Handles entire deployment pipelines solo
- Acts as ambient lab intelligence

**The ultimate test:** Can you go an entire day without manually checking anything? Quinn tells you what you need to know, when you need to know it, and handles everything else.

---

## Implementation Priority

**This Sprint (1 week):**
- Voice output via ElevenLabs
- Morning brief automation
- Proactive error alerts

**Next Sprint (2 weeks):**
- Wake word detection
- Task decomposition
- Learn from corrections

**Future (1+ months):**
- iOS companion sync
- Workflow automation
- Predictive orchestration
