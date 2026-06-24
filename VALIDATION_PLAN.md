# Quinn Enhancements Validation Plan
**Build 58 - All 8 Phases**

## Test Categories

### Phase 1.1: Proactive Intelligence (Build 51)
- [ ] **Morning briefing** - "morning briefing" → should return Calendar + Helmsman + Docker + Git summary
- [ ] **Status command** - "status" → should return system status summary
- [ ] **Context switching** - Monitors git branch changes, app switching (background monitoring)

### Phase 2: Screenshot Analysis + Vision (Build 52)
- [ ] **Screen capture** - "what's on my screen" → should analyze current screen
- [ ] **Error detection** - "what's this error" → should identify errors on screen
- [ ] **OCR** - "read my screen" → should extract text via Vision

### Phase 3: Deep Helmsman Integration (Build 54)
- [ ] **Task status** - "how many tasks" → should query helmsman.db and return count
- [ ] **Create task** - "create task test quinn integration" → should auto-dispatch to agent
- [ ] **Mark complete** - "mark complete [task]" → should fuzzy match and complete
- [ ] **Next task** - "what should I work on" → should suggest priority task

### Phase 4: Memory + Learning (Build 55)
- [ ] **Search conversations** - "search conversations for screen" → should return matches
- [ ] **Conversation stats** - "conversation stats" → should return total + last 24h count

### Phase 5: Code Understanding (Build 56)
- [ ] **Analyze code** - "analyze this code" → should analyze visible file in Xcode/VSCode
- [ ] **Find symbol** - "find definition of HelmsmanIntegration" → should search codebase
- [ ] **Find usages** - "where is CodeAnalyzer used" → should list usages
- [ ] **Review diff** - "review my changes" → should analyze git diff via LLM
- [ ] **Current branch** - "what branch" → should return active git branch
- [ ] **Recent commits** - "recent commits" → should list last 5 commits

### Phase 6: Multi-Device Orchestration (Build 57)
- [ ] **Connected devices** - "connected devices" → should list registered devices
- [ ] **Device routing** - "which device should build iOS app" → should route to Xcode-capable device

### Phase 7: Real-Time Collaboration (Build 58)
- [ ] **Start monitoring** - "start monitoring" → should enable screen change detection
- [ ] **Stop monitoring** - "stop monitoring" → should disable monitoring
- [ ] **Autonomous mode** - "autonomous mode on" → should enable auto-fix (test with caution!)
- [ ] **Refactoring** - "refactoring opportunities" → should scan for code smells
- [ ] **Live review** - "review my changes live" → should analyze current diff

### Phase 8: Quick Win Commands (Build 53)
- [ ] **Focus mode** - "focus mode" → should enable DND, close Slack, stop containers
- [ ] **Exit focus** - "exit focus mode" → should restore normal state
- [ ] **Wrap up** - "wrap up" → should check git changes, stop Docker, count commits
- [ ] **Deep work** - "deep work" → should start 90-min timer + focus mode
- [ ] **Quick status** - "quick status" → should return condensed system health

### Fast-Path Commands (Pre-existing)
- [ ] **Time** - "what time is it" → <50ms response
- [ ] **Date** - "what's the date" → <50ms response
- [ ] **Math** - "what is 7 times 8" → instant calculation
- [ ] **Greeting** - "hello" → instant acknowledgment

## Integration Tests

### End-to-End Workflows
1. **Morning workflow:**
   - "morning briefing" → get overview
   - "what should I work on" → get next task
   - "focus mode" → enter deep work
   - Work for 10 minutes
   - "review my changes" → get code review
   - "wrap up" → end of session

2. **Code exploration:**
   - Open file in Xcode
   - "analyze this code" → understand purpose
   - "find definition of [symbol]" → locate implementation
   - "where is [symbol] used" → see call sites
   - "review my changes" → pre-commit check

3. **Task management:**
   - "how many tasks" → see current queue
   - "create task implement feature X" → auto-dispatch
   - "what should I work on" → get suggestion
   - Work on task
   - "mark complete [task]" → close it

## Performance Tests
- [ ] All fast-path queries complete in <100ms
- [ ] LLM queries (ask_claude) complete in <3s
- [ ] Memory search returns results in <1s
- [ ] Symbol search completes in <2s

## Stress Tests
- [ ] 100 rapid queries don't crash CommandServer
- [ ] Screen monitoring runs for 1 hour without memory leak
- [ ] Conversation search with 1000+ entries performs well

## Security Tests
- [ ] Autonomous mode requires explicit opt-in
- [ ] File operations stay within authorized paths
- [ ] No credential leakage in logs

## Next Steps After Validation
1. [ ] Test all Phase 3-8 commands with real data
2. [ ] Measure actual response times
3. [ ] Verify iOS→Mac communication still works
4. [ ] Merge feature/sidecar-packaging to main
5. [ ] Update iOS app to match macOS capabilities
6. [ ] Document all voice commands in user guide
