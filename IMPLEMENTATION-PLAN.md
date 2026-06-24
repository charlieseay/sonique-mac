# SoniqueBar → App Store Ready - Implementation Plan

**Goal:** All Jarvis capabilities + App Store distribution framework  
**Timeline:** 6 weeks to shippable MVP  
**Rule Compliance:** Documentation-first, read-before-modify, proof-required, subscriptions-first

---

## Week 1: Connector Architecture (Foundation)

### Day 1-2: Define Plugin Protocol
**Read docs first:**
- Swift plugin architecture patterns
- App extensions vs XPC services
- Secure credential storage (Keychain)

**Build:**
```swift
// Core/Connectors/ConnectorProtocol.swift
protocol ActionConnector {
    var id: UUID { get }
    var name: String { get }
    var version: String { get }
    var capabilities: [ConnectorCapability] { get }
    
    func execute(_ capability: String, parameters: [String: Any]) async throws -> ConnectorResult
    func healthCheck() async -> Bool
}

struct ConnectorCapability {
    var name: String              // "create_task"
    var description: String
    var parameters: [Parameter]
    var requiredAuth: AuthType
}

enum AuthType {
    case none
    case bearer(token: String)
    case apiKey(key: String, header: String)
    case oauth(token: String)
}
```

**Deliverable:** Protocol defined, documented, committed

---

### Day 3-4: Connector Registry + Settings UI

**Build:**
```swift
// Core/Connectors/ConnectorRegistry.swift
@MainActor
class ConnectorRegistry: ObservableObject {
    @Published var connectors: [any ActionConnector] = []
    
    func register(_ connector: any ActionConnector)
    func unregister(id: UUID)
    func findByCapability(_ capability: String) -> [any ActionConnector]
    
    // Load from user preferences
    func loadConnectors()
    func saveConnectors()
}

// App/Settings/ConnectorsView.swift
struct ConnectorsView: View {
    @StateObject var registry = ConnectorRegistry.shared
    
    var body: some View {
        List {
            ForEach(registry.connectors) { connector in
                ConnectorRow(connector: connector)
            }
        }
        .toolbar {
            Button("Add Connector") { showAddSheet = true }
        }
    }
}
```

**Deliverable:** Registry working, Settings UI shows connected services

---

### Day 5: Reference Implementation - Helmsman Connector

**Build:**
```swift
// Extensions/HelmsmanConnector.swift
struct HelmsmanConnector: ActionConnector {
    var name = "Helmsman Task Dispatch"
    var capabilities: [ConnectorCapability] = [
        .init(
            name: "create_task",
            description: "Create a task in Helmsman queue",
            parameters: [
                .init(name: "task", type: .string, required: true),
                .init(name: "owner", type: .string, required: true),
                .init(name: "project", type: .string, required: true),
                .init(name: "effort", type: .enum(["S","M","L","XL"]), required: true),
                .init(name: "context", type: .string, required: false),
            ],
            requiredAuth: .bearer(token: getSecret("dispatch_webhook_secret"))
        ),
        .init(
            name: "query_queue",
            description: "Get pending tasks",
            parameters: [
                .init(name: "status", type: .string, required: false),
                .init(name: "owner", type: .string, required: false),
            ],
            requiredAuth: .none
        )
    ]
    
    func execute(_ capability: String, parameters: [String: Any]) async throws -> ConnectorResult {
        switch capability {
        case "create_task":
            return try await createTask(parameters)
        case "query_queue":
            return try await queryQueue(parameters)
        default:
            throw ConnectorError.unknownCapability
        }
    }
    
    private func createTask(_ params: [String: Any]) async throws -> ConnectorResult {
        let endpoint = "http://localhost:5680/webhook/task-dispatch"
        let payload = [
            "task": params["task"],
            "owner": params["owner"],
            "project": params["project"],
            "effort": params["effort"],
            "context": params["context"] ?? ""
        ]
        
        // POST to webhook
        let response = try await URLSession.shared.post(endpoint, json: payload, auth: .bearer(token))
        return .success(message: "Task created", data: response)
    }
}
```

**Deliverable:** Helmsman connector working, Quinn can create tasks via connector API

**Validation proof:**
```bash
# Test via Quinn
curl -X POST http://localhost:8890/command -d '{"text":"create a task to test connectors"}' 

# Verify in helmsman
curl -s http://localhost:5682/tasks?status=pending | jq '.[] | select(.task | contains("test connectors"))'
```

---

## Week 2: LLM Provider Abstraction

### Day 1-2: LLM Provider Protocol

**Read docs first:**
- Anthropic Claude API docs
- OpenAI API docs  
- Google Gemini API docs
- Ollama local LLM docs

**Build:**
```swift
// Core/LLM/LLMProvider.swift
protocol LLMProvider {
    var name: String { get }
    var models: [String] { get }
    var features: [LLMFeature] { get }  // .conversation, .tools, .vision
    var pricing: Pricing? { get }        // For display in settings
    
    func complete(prompt: String, model: String, maxTokens: Int) async throws -> LLMResponse
    func chat(messages: [Message], model: String, tools: [Tool]?) async throws -> LLMResponse
    func healthCheck() async -> Bool
}

struct LLMResponse {
    var text: String
    var usage: TokenUsage
    var toolCalls: [ToolCall]?
}

enum LLMFeature {
    case conversation
    case tools
    case vision
    case streaming
}
```

**Deliverable:** Protocol defined, documented

---

### Day 3-4: Implement Providers

**Build:**
- `ClaudeProvider.swift` - Anthropic API
- `OpenAIProvider.swift` - OpenAI API
- `GeminiProvider.swift` - Google Gemini API
- `OllamaProvider.swift` - Local LLM

**Example:**
```swift
// Core/LLM/Providers/ClaudeProvider.swift
struct ClaudeProvider: LLMProvider {
    var name = "Claude (Anthropic)"
    var models = ["claude-sonnet-4.5", "claude-opus-4", "claude-haiku-4"]
    var features: [LLMFeature] = [.conversation, .tools, .vision, .streaming]
    
    private var apiKey: String  // From Keychain
    
    func chat(messages: [Message], model: String, tools: [Tool]?) async throws -> LLMResponse {
        let endpoint = "https://api.anthropic.com/v1/messages"
        let payload = [
            "model": model,
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
            "max_tokens": 4096,
            "tools": tools?.map { $0.toJSON() }
        ].compactMapValues { $0 }
        
        let response = try await URLSession.shared.post(
            endpoint,
            json: payload,
            headers: [
                "x-api-key": apiKey,
                "anthropic-version": "2023-06-01"
            ]
        )
        
        return try LLMResponse(from: response)
    }
}
```

**Deliverable:** All 4 providers working

**Validation proof:**
```bash
# Test each provider
curl -X POST http://localhost:8890/command -d '{"text":"test claude provider","model":"claude-sonnet-4.5"}'
curl -X POST http://localhost:8890/command -d '{"text":"test openai provider","model":"gpt-4"}'
curl -X POST http://localhost:8890/command -d '{"text":"test local llm","model":"llama3.2"}'
```

---

### Day 5: LLM Router + Model Selection

**Build:**
```swift
// Core/LLM/LLMRouter.swift
@MainActor
class LLMRouter: ObservableObject {
    @Published var providers: [any LLMProvider] = []
    @Published var preferenceOrder: [String] = []  // Provider names in order
    
    func selectProvider(for task: String, escalation: EscalationLevel) -> (any LLMProvider, String) {
        // Select provider based on:
        // 1. User preference order
        // 2. Escalation level (haiku/sonnet/opus)
        // 3. Provider availability
        // 4. Features required (tools, vision)
        
        switch escalation {
        case .fast:
            return (claudeProvider, "claude-haiku-4")
        case .think:
            return (claudeProvider, "claude-sonnet-4.5")
        case .emergency:
            return (claudeProvider, "claude-opus-4")
        }
    }
    
    func execute(prompt: String, escalation: EscalationLevel = .fast) async -> String {
        let (provider, model) = selectProvider(for: prompt, escalation: escalation)
        
        do {
            let response = try await provider.chat(
                messages: [.init(role: "user", content: prompt)],
                model: model
            )
            return response.text
        } catch {
            // Fallback to next provider in preference order
            return try await fallbackExecute(prompt, escalation: escalation)
        }
    }
}

enum EscalationLevel {
    case fast      // Haiku
    case think     // Sonnet
    case emergency // Opus
}
```

**Deliverable:** Model routing working, escalation paths functional

---

## Week 3: Voice Output System

### Day 1-2: Voice Provider Protocol

**Read docs first:**
- ElevenLabs API documentation
- OpenAI TTS API documentation
- Apple AVSpeechSynthesizer documentation

**Build:**
```swift
// Core/Voice/VoiceProvider.swift
protocol VoiceProvider {
    var name: String { get }
    var voices: [Voice] { get }
    var requiresAPIKey: Bool { get }
    
    func speak(_ text: String, voice: Voice, speed: Float) async throws
    func listVoices() async throws -> [Voice]
}

struct Voice {
    var id: String
    var name: String
    var language: String
    var gender: String?
    var previewURL: URL?
}

// Implementations
class ElevenLabsProvider: VoiceProvider { ... }
class OpenAITTSProvider: VoiceProvider { ... }
class AppleVoiceProvider: VoiceProvider { ... }
```

**Deliverable:** Voice provider protocol defined, 3 implementations ready

---

### Day 3: Voice Output Service

**Build:**
```swift
// Core/Voice/VoiceOutput.swift
@MainActor
class VoiceOutput: ObservableObject {
    @Published var currentProvider: any VoiceProvider
    @Published var selectedVoice: Voice
    @Published var enabled: Bool = true
    @Published var volume: Float = 0.8
    @Published var speed: Float = 1.0
    
    func speak(_ text: String, priority: Priority = .normal) async {
        guard enabled else { return }
        guard await PresenceDetection.shared.isUserPresent() else { return }
        
        // Strip technical details (file paths, URLs, task numbers)
        let cleaned = cleanForVoice(text)
        
        try? await currentProvider.speak(cleaned, voice: selectedVoice, speed: speed)
    }
    
    private func cleanForVoice(_ text: String) -> String {
        // Remove file paths
        var cleaned = text.replacingOccurrences(of: #"/[A-Za-z0-9/_.-]+\.(swift|md|json|sh)"#, with: "", options: .regularExpression)
        
        // Remove URLs
        cleaned = cleaned.replacingOccurrences(of: #"https?://[^\s]+"#, with: "", options: .regularExpression)
        
        // Remove task numbers
        cleaned = cleaned.replacingOccurrences(of: #"#\d+"#, with: "", options: .regularExpression)
        
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum Priority {
    case critical  // Always speak
    case normal    // Only if user present
    case background // Never speak
}
```

**Deliverable:** Voice output working with all 3 providers

**Validation proof:**
```bash
# Quinn should speak this out loud
curl -X POST http://localhost:8890/command -d '{"text":"test voice output"}' 

# Check audio output happened (look for ElevenLabs API call or AVSpeech activity)
tail -f ~/Library/Logs/SoniqueBar/stdout.log | grep -i "speak\|voice\|tts"
```

---

### Day 4-5: Proactive Alerts

**Build:**
```swift
// SoniqueBar/Services/ProactiveAlerts.swift
@MainActor
class ProactiveAlerts: ObservableObject {
    @Published var enabledAlerts: Set<AlertType> = [.critical, .morningBrief]
    
    func alert(_ message: String, type: AlertType) async {
        guard enabledAlerts.contains(type) else { return }
        
        // Speak it
        await VoiceOutput.shared.speak(message, priority: type.priority)
        
        // Show notification
        NotificationService.shared.notify(
            title: type.title,
            message: message,
            priority: type.notificationPriority
        )
    }
}

enum AlertType {
    case critical      // Build failed, service down
    case queueSpike    // Helmsman queue growing
    case morningBrief  // 6:10am summary
    case reminder      // Calendar events
    
    var priority: VoiceOutput.Priority {
        switch self {
        case .critical: return .critical
        case .morningBrief: return .normal
        default: return .background
        }
    }
}
```

**Wire into existing monitors:**
```swift
// BackgroundMonitor.swift - already exists, just add voice
private func checkHelmsmanQueue() async {
    let count = await getQueueCount()
    
    if let last = lastHelmsmanCheck, count > lastErrorCount + 10 {
        // Voice alert
        await ProactiveAlerts.shared.alert(
            "Helmsman queue spiked to \(count) tasks",
            type: .queueSpike
        )
        
        // Existing task dispatch stays the same
        await autoDispatchTask(...)
    }
}
```

**Deliverable:** Quinn speaks critical alerts out loud

---

## Week 4: Wake Word + Always-On Listening

### Day 1-2: Wake Word Detection

**Read docs first:**
- Porcupine wake word documentation
- Apple Speech framework background modes
- macOS audio permissions

**Build:**
```swift
// Core/Voice/WakeWordDetector.swift
class WakeWordDetector: ObservableObject {
    @Published var isListening: Bool = false
    @Published var wakeWord: String = "hey quinn"
    
    private var porcupine: Porcupine?
    private var audioEngine: AVAudioEngine?
    
    func startListening() {
        // Initialize Porcupine with custom wake word
        porcupine = try? Porcupine(keyword: wakeWord)
        
        // Start audio engine for background listening
        audioEngine = AVAudioEngine()
        let inputNode = audioEngine!.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        
        inputNode.installTap(onBus: 0, bufferSize: 512, format: format) { buffer, _ in
            // Process audio for wake word
            if let detected = self.porcupine?.process(buffer) {
                Task { @MainActor in
                    await self.onWakeWordDetected()
                }
            }
        }
        
        try? audioEngine?.start()
        isListening = true
    }
    
    private func onWakeWordDetected() async {
        // Beep or visual feedback
        NSSound.beep()
        
        // Start full speech recognition
        await SpeechRecognizer.shared.startListening()
    }
}
```

**Deliverable:** Wake word working, Quinn activates on "Hey Quinn"

**Validation proof:**
```bash
# Say "Hey Quinn, what time is it?" out loud
# Quinn should beep, then respond with the current time spoken back

# Check logs
tail -f ~/Library/Logs/SoniqueBar/stdout.log | grep "wake word detected"
```

---

### Day 3-5: Background Listening + Permissions

**Build:**
- Background audio permission handling
- Settings UI for wake word configuration
- Privacy controls (local processing only)
- Audio visualization (show when listening)

**Deliverable:** Quinn always listening in background, activates on wake word

---

## Week 5: Context Awareness + Intelligence

### Day 1-2: Presence Detection

**Build:**
```swift
// Services/PresenceDetection.swift
@MainActor
class PresenceDetection: ObservableObject {
    @Published var isPresent: Bool = false
    @Published var currentActivity: Activity = .idle
    @Published var activeWindow: String = ""
    @Published var idleTime: TimeInterval = 0
    
    func startMonitoring() {
        // Screen lock detection
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(screenLocked),
            name: NSWorkspace.screensDidSleepNotification
        )
        
        // Idle timer
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            self.updateIdleTime()
        }
        
        // Active window (accessibility)
        Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { _ in
            self.updateActiveWindow()
        }
    }
    
    private func updateIdleTime() {
        idleTime = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .mouseMoved)
        isPresent = idleTime < 300  // 5 minutes
    }
    
    private func updateActiveWindow() {
        // Use Accessibility API to get frontmost app + window title
        let app = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        activeWindow = app
        currentActivity = detectActivity(from: app)
    }
    
    private func detectActivity(from app: String) -> Activity {
        switch app {
        case "Xcode", "VS Code": return .coding
        case "Slack", "Messages": return .communicating
        case "Safari", "Chrome": return .browsing
        case "Zoom", "FaceTime": return .meeting
        default: return .idle
        }
    }
}

enum Activity {
    case idle, coding, communicating, browsing, meeting
}
```

**Deliverable:** Quinn knows when you're present and what you're doing

---

### Day 3: Predictive Notifications

**Build:**
```swift
// Services/PredictiveNotifications.swift
class PredictiveNotifications {
    func generateMorningBrief() async -> String {
        let calendar = await CalendarService.shared.getEventsToday()
        let queue = await HelmsmanConnector.queryQueue(status: "pending")
        let recent = await getRecentActivity()
        
        var brief = "Morning Charlie. "
        
        // Calendar
        if calendar.count > 0 {
            brief += "You have \(calendar.count) meetings today, first one at \(calendar[0].startTime). "
        }
        
        // Queue status
        brief += "Helmsman queue has \(queue.count) pending tasks. "
        
        // Recent completions
        if recent.completed > 0 {
            brief += "\(recent.completed) tasks closed overnight. "
        }
        
        // Anomalies
        if queue.count > 40 {
            brief += "Queue higher than usual, I've already dispatched \(recent.dispatched) to the team."
        }
        
        return brief
    }
}
```

**Schedule at 6:10 AM:**
```swift
// Add to launchd or use Timer
Timer.scheduledTimer(withTimeInterval: 24*60*60, repeats: true) { _ in
    let now = Date()
    if now.hour == 6 && now.minute == 10 {
        Task {
            let brief = await PredictiveNotifications.shared.generateMorningBrief()
            await VoiceOutput.shared.speak(brief, priority: .normal)
        }
    }
}
```

**Deliverable:** Morning brief spoken at 6:10 AM daily

---

### Day 4-5: Task Decomposition

**Build:**
```swift
// Core/Intelligence/TaskDecomposer.swift
class TaskDecomposer {
    func decompose(_ request: String) async -> [Subtask] {
        // Use LLM to break down complex request
        let prompt = """
        Break down this request into executable subtasks:
        "\(request)"
        
        Return JSON array of subtasks with:
        - action: what to do
        - connector: which connector to use
        - parameters: connector parameters
        - verifyCommand: how to verify success
        """
        
        let response = await LLMRouter.shared.execute(prompt, escalation: .think)
        let subtasks = try? JSONDecoder().decode([Subtask].self, from: response.data(using: .utf8)!)
        return subtasks ?? []
    }
    
    func execute(_ subtasks: [Subtask]) async -> [SubtaskResult] {
        var results: [SubtaskResult] = []
        
        for subtask in subtasks {
            // Execute via connector
            let connector = ConnectorRegistry.shared.findByCapability(subtask.connector).first
            let result = try? await connector?.execute(subtask.action, parameters: subtask.parameters)
            
            // Verify
            let verified = await verify(subtask.verifyCommand)
            
            results.append(.init(subtask: subtask, result: result, verified: verified))
            
            // Speak progress
            await VoiceOutput.shared.speak("Step \(results.count): \(subtask.action) complete")
        }
        
        return results
    }
}
```

**Example:**
```
You: "Get StoryChat ready to ship"

Quinn (decomposes):
1. Run test suite → verify all pass
2. Bump version to 1.2.0 → commit
3. Build for TestFlight → upload
4. Generate release notes → save

Quinn (executes + speaks):
"Step 1: Running tests... all pass"
"Step 2: Version bumped to 1.2.0, committed"
"Step 3: Building for TestFlight... uploaded"
"Step 4: Release notes generated"
"StoryChat 1.2.0 is live on TestFlight"
```

**Deliverable:** Multi-step workflow execution working

---

## Week 6: Polish + App Store Prep

### Day 1-2: Settings UI Complete
- All tabs implemented (General, Voice, LLM, Connectors, Privacy)
- Onboarding flow for first launch
- Help documentation
- Test connection buttons for all integrations

### Day 3: Packaging + Code Signing
- Create Apple Developer account (if needed)
- Configure code signing
- Sandbox entitlements
- Privacy manifest

### Day 4: App Store Submission
- Screenshots + app preview video
- App Store description
- Submit for review

### Day 5: Documentation
- User guide
- Connector development guide
- Privacy policy
- Support site

---

## Validation Protocol (Every Feature)

**For each deliverable:**
1. **Build** - Implement the feature
2. **Test** - Run validation proof (command + output)
3. **Document** - Update CAPABILITIES.md
4. **Commit** - Git commit with proof in commit message
5. **Voice Verify** - Test with actual voice input

**Example commit:**
```
Quinn Build 43: Voice output via ElevenLabs

Implemented VoiceProvider protocol with ElevenLabs integration.
Quinn now speaks responses out loud with presence detection.

Validation:
$ curl -X POST http://localhost:8890/command -d '{"text":"test voice"}'
[Quinn speaks: "This is a test"]

$ tail -1 ~/Library/Logs/SoniqueBar/stdout.log
[VoiceOutput] ElevenLabs TTS: "This is a test" (voice: Rachel, 1.2s)

Co-Authored-By: Claude Sonnet 4.5 <noreply@anthropic.com>
```

---

## Success Criteria

**Week 6 Complete:**
- ✅ Quinn speaks proactively (ElevenLabs voice)
- ✅ Wake word detection ("Hey Quinn")
- ✅ Morning brief at 6:10 AM
- ✅ Multi-step task execution
- ✅ Connector system working (Helmsman, Docker, Slack, etc.)
- ✅ LLM provider abstraction (Claude, OpenAI, Gemini, local)
- ✅ Settings UI complete with all configuration
- ✅ App Store ready (sandboxed, signed, submitted)
- ✅ Charlie's lab setup working via connectors (no code changes needed)

**The ultimate test:**
Go an entire day without manually checking anything. Quinn tells you what you need to know, when you need to know it, and handles multi-step requests autonomously.

---

## Cost Estimate

**Development time:** 6 weeks (240 hours)  
**External dependencies:**
- ElevenLabs API: ~$5/month (first 10k chars free)
- Porcupine wake word: Free tier available
- Apple Developer: $99/year

**Total:** 6 weeks of focused work → shippable App Store product + all Jarvis capabilities
