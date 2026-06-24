# Quinn Voice Commands Reference
**SoniqueBar Build 58 - Complete Command List**

This document lists all voice commands available in Quinn (SoniqueBar). Commands are organized by capability category.

---

## 📅 Proactive Intelligence

### Morning Briefing
- **"morning briefing"** → Comprehensive summary of Calendar, Helmsman tasks, Docker status, and recent git activity
- **"brief me"** → Same as morning briefing
- **"briefing"** → Same as morning briefing

### System Status
- **"status"** → System status overview (same as morning briefing)
- **"system status"** → System status overview
- **"what's the status"** → System status overview

---

## 🖥️ Screenshot Analysis & Vision

### Screen Capture
- **"what's on my screen"** → Analyzes current screen using Claude Vision
- **"analyze my screen"** → Same as above
- **"screenshot"** → Same as above

### Error Detection
- **"what's this error"** → Identifies errors or issues on screen and suggests fixes

### OCR (Text Extraction)
- **"read my screen"** → Extracts text from current screen using Vision framework
- **"what does it say"** → Same as above
- **"read this"** → Same as above

---

## ✅ Task Management (Helmsman Integration)

### Query Tasks
- **"how many tasks"** → Returns count of pending tasks from helmsman.db
- **"pending tasks"** → Same as above
- **"task status"** → Same as above

### Create Tasks
- **"create task [description]"** → Creates task and auto-dispatches to appropriate agent
  - Example: "create task implement feature X"
  - Auto-routing based on task content (code → AIDER-GEM, research → NVIDIA-BAL, etc.)
- **"add task [description]"** → Same as above
- **"new task [description]"** → Same as above

### Complete Tasks
- **"mark complete [task description]"** → Fuzzy matches and marks task complete
  - Example: "mark complete feature implementation"
- **"task done [task description]"** → Same as above
- **"completed task [task description]"** → Same as above

### Task Suggestions
- **"what should I work on"** → Suggests next task based on priority (urgent → high-pri → oldest)
- **"next task"** → Same as above
- **"what's next"** → Same as above

---

## 🧠 Memory & Conversation

### Search History
- **"search conversations for [query]"** → Full-text search across conversation history
  - Example: "search conversations for screen capture"
- **"search conversation for [query]"** → Same as above
- **"search history for [query]"** → Same as above

### Statistics
- **"conversation stats"** → Total conversations + count from last 24 hours
- **"memory stats"** → Same as above
- **"stats"** → Same as above

---

## 💻 Code Understanding

### Code Analysis
- **"analyze this code"** → Analyzes currently visible file in Xcode or VSCode
- **"what does this code do"** → Same as above
- **"explain this code"** → Same as above

### Symbol Navigation
- **"find definition of [symbol]"** → Searches codebase for symbol definition using ripgrep
  - Example: "find definition of HelmsmanIntegration"
- **"find declaration of [symbol]"** → Same as above

### Usage Search
- **"where is [symbol] used"** → Lists all usages of a symbol in codebase
  - Example: "where is CodeAnalyzer used"

### Git Operations
- **"review my changes"** → Analyzes git diff using LLM for code review
- **"review diff"** → Same as above
- **"check my code"** → Same as above

### Git Status
- **"what branch"** → Returns current git branch name
- **"current branch"** → Same as above
- **"uncommitted changes"** → Returns count of uncommitted changes
- **"what changed"** → Same as above
- **"recent commits"** → Lists last 5 commits
- **"last commits"** → Same as above

---

## 📱 Multi-Device Orchestration

### Device Management
- **"connected devices"** → Lists all registered devices with last seen timestamps
- **"available devices"** → Same as above
- **"list devices"** → Same as above

### Device Routing
- **"which device should [task]"** → Routes task to best device based on capabilities
  - Example: "which device should build iOS app" → routes to Xcode-capable device
- **"what device should [task]"** → Same as above
- **"which device for [task]"** → Same as above
- **"what device for [task]"** → Same as above

---

## 🤝 Real-Time Collaboration

### Screen Monitoring
- **"start monitoring"** → Enables screen change detection (checks every 5 seconds)
- **"watch my screen"** → Same as above
- **"stop monitoring"** → Disables screen monitoring
- **"stop watching"** → Same as above

### Autonomous Mode
⚠️ **Use with caution** - Auto-fixes code issues without confirmation
- **"autonomous mode on"** → Enables automatic code fixing
- **"enable autonomous"** → Same as above
- **"autonomous mode off"** → Disables automatic fixing
- **"disable autonomous"** → Same as above

### Code Quality
- **"refactoring opportunities"** → Scans codebase for code smells (long functions, deep nesting, tech debt markers)
- **"code smells"** → Same as above

### Live Review
- **"review my changes live"** → Real-time review of current git diff
- **"check what I changed"** → Same as above

---

## ⚡ Quick Win Commands

### Focus Mode
- **"focus mode"** → Enables Do Not Disturb, closes Slack, stops non-essential Docker containers
- **"enter focus"** → Same as above
- **"start focus"** → Same as above
- **"exit focus mode"** → Disables Do Not Disturb, restores normal state
- **"end focus"** → Same as above
- **"stop focus"** → Same as above

### Wrap Up
- **"wrap up"** → End-of-day summary: checks git changes, stops Docker, counts commits, shows pending tasks
- **"end of day"** → Same as above
- **"wrap it up"** → Same as above

### Deep Work
- **"deep work"** → Starts 90-minute focused work session with timer + focus mode
- **"focus session"** → Same as above

### Quick Status
- **"quick status"** → Ultra-condensed system health (pending tasks, Docker status, commits)
- **"quick check"** → Same as above

---

## 🚀 Fast-Path Commands
*These respond in < 100ms with no LLM call*

### Time & Date
- **"what time is it"** → Current time (instant)
- **"what's the time"** → Same as above
- **"current time"** → Same as above
- **"what day"** → Current date (instant)
- **"what's the date"** → Same as above
- **"today's date"** → Same as above

### Math
- **"what is [number] [operation] [number]"** → Instant calculation
  - Supported operations: plus, minus, times, divided by
  - Example: "what is 7 times 8" → "56"

### Acknowledgment
- **"are you there"** → "I'm here. What do you need?"
- **"hello"** → Same as above
- **"hey"** → Same as above

### Cancel
- **"stop"** → Stops current operation
- **"cancel"** → Same as above
- **"never mind"** → Same as above

---

## 🎯 Usage Tips

### Command Clarity
- Speak naturally - Quinn understands conversational language
- Be specific when creating tasks - "create task implement login with OAuth" is better than "create task login"
- For symbol searches, use the exact symbol name as it appears in code

### Best Practices
1. **Morning Routine:** "morning briefing" → "what should I work on" → "focus mode"
2. **Code Session:** "analyze this code" → work → "review my changes" → commit
3. **End of Day:** "wrap up" → review uncommitted changes → commit → exit focus

### Safety Notes
- **Autonomous mode** auto-fixes code without confirmation - only enable in safe environments
- **Focus mode** closes Slack and stops containers - make sure this won't disrupt your work
- **Screen monitoring** runs every 5 seconds - stop it when not needed to save resources

### Performance
- Fast-path commands (time, date, math): < 100ms
- Helmsman queries: < 500ms (direct REST API)
- LLM commands (code analysis, review): 2-3 seconds
- Vision commands (screen capture): 3-5 seconds

---

## 📊 Statistics
- **Total Commands:** 50+
- **Categories:** 8
- **Fast-Path Commands:** 10
- **LLM-Powered Commands:** 40+
- **Voice Providers:** 3 (ElevenLabs, OpenAI TTS, System Voice)
- **LLM Providers:** 5 (Claude, Gemini, OpenAI, NVIDIA, Ollama)

---

## 🔧 Customization

### Wake Word
The wake word matches your assistant's name setting:
- Default: "Sonique" → ["hey sonique", "sonique", "okay sonique"]
- Custom: Set name to "Quinn" → ["hey quinn", "quinn", "okay quinn"]

### Voice Selection
Choose from multiple TTS providers in Settings:
- **ElevenLabs** (default): High-quality, natural-sounding
- **OpenAI TTS**: 6 voice options (alloy, echo, fable, onyx, nova, shimmer)
- **System Voice**: Built-in macOS voices (no API key required)

### LLM Selection
Quinn routes intelligently, but you can prefer specific providers:
- **Claude** (subscription): Best for reasoning and code
- **Gemini** (subscription): Best for research and large context
- **NVIDIA** (free): Fast tier for quick operations
- **Ollama** (local): Offline-capable, runs llama3.2:3b-instruct

---

## 🐛 Known Issues

### Minor Issues
- Some voice commands may route to LLM instead of fast-path (slightly slower, but functional)
- JSON responses with newlines can cause client-side parsing warnings (cosmetic only)

### Workarounds
- If a command doesn't respond as expected, try rephrasing it
- Use "quick status" for reliable task counts (always uses fast-path)

---

## 📝 Version
- **Build:** 58
- **Release:** v1.1.0-quinn
- **Date:** 2026-06-24
- **Status:** Production

---

## 🔗 Additional Resources
- **Architecture:** See `ARCHITECTURE.md` in repo
- **Validation Plan:** See `VALIDATION_PLAN.md` in repo
- **Implementation Status:** See `QUINN-ENHANCEMENTS.md` in repo
- **Project Notes:** `Projects/Sonique/Sonique.md` in vault
