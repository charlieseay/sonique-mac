# SoniqueBar Architecture - App Store Ready

**Design Principle:** SoniqueBar is a general-purpose voice assistant framework. Charlie's lab automation is a **reference implementation** that connects via documented APIs.

---

## Core vs Custom Split

### Core (Ships in App Store)
**SoniqueBar.app** - The voice assistant engine:
- Wake word detection ("Hey Quinn")
- Voice input (Apple Speech framework)
- Voice output (ElevenLabs, OpenAI TTS, Apple AVSpeech)
- LLM routing (pluggable: Claude API, OpenAI, local models)
- Memory system (iCloud-synced profiles)
- Fast-path responses (time, date, math, greetings)
- Plugin/connector architecture
- Settings UI for configuration

### Custom (Private, connects via plugins)
**Charlie's Lab** - Internal infrastructure that SoniqueBar talks to:
- Helmsman task dispatch webhook
- Docker container management API
- Vault MCP server
- HomeKit/HomeAssistant
- Slack integration
- Custom tooling (ask_claude, nvidia-agent, etc.)

---

## Plugin Architecture

### 1. LLM Providers (User-Configurable)

**Built-in providers (ships with app):**
- Claude API (Anthropic)
- OpenAI API
- Google Gemini API
- Local LLM via Ollama
- Bedrock (AWS)

**User configures via Settings:**
```swift
struct LLMProvider {
    var name: String              // "Claude API"
    var endpoint: String?         // Optional custom endpoint
    var apiKey: String            // Encrypted in Keychain
    var model: String             // "claude-sonnet-4.5"
    var preference: Int           // 1 = primary, 2 = fallback
    var features: [String]        // ["conversation", "tools", "vision"]
}
```

**Settings UI:**
- Add/remove LLM providers
- Configure API keys (secure input, stored in Keychain)
- Set preference order (primary → fallback chain)
- Test connection button

---

### 2. Action Connectors (Plugin System)

**What it is:** External webhooks/APIs that SoniqueBar can call to execute actions.

**Example connectors:**
- Task Management (Helmsman, Todoist, Linear, Jira)
- Home Automation (HomeKit, HomeAssistant, IFTTT)
- Communication (Slack, Discord, Email, SMS)
- Calendar (Apple Calendar, Google Calendar, Notion)
- Notes (Obsidian MCP, Notion, Apple Notes)
- Development (GitHub, Docker, CI/CD)

**Connector Interface:**
```swift
protocol ActionConnector {
    var name: String { get }           // "Helmsman Task Dispatch"
    var endpoint: URL { get }          // "http://localhost:5680/webhook/task-dispatch"
    var authType: AuthType { get }     // .bearer, .apiKey, .none
    var credentials: String? { get }   // API key/token
    var capabilities: [String] { get } // ["create_task", "query_status"]
    
    func execute(action: String, parameters: [String: Any]) async -> Result
}
```

**Settings UI:**
- Browse connector marketplace (built-in + community)
- Add custom connectors (URL + auth)
- Configure credentials per connector
- Enable/disable connectors
- Test connection

**Example: Charlie's Setup**
```
Connectors:
  ✓ Helmsman Task Dispatch
    - Endpoint: http://localhost:5680/webhook/task-dispatch
    - Auth: Bearer token (from /Volumes/data/secrets/dispatch_webhook_secret)
    - Capabilities: create_task, query_queue, dispatch_brief
  
  ✓ Docker Management
    - Endpoint: http://localhost:2375
    - Auth: None (local trusted)
    - Capabilities: list_containers, restart, health_check
  
  ✓ Obsidian Vault (MCP)
    - Endpoint: stdio://mcp-server-obsidian
    - Auth: None
    - Capabilities: search_notes, read_note, create_note
  
  ✓ Slack
    - Endpoint: https://slack.com/api
    - Auth: OAuth token
    - Capabilities: post_message, list_channels
```

---

### 3. Voice Providers (User-Configurable)

**Built-in TTS options:**
- ElevenLabs (premium, natural)
- OpenAI TTS (good quality)
- Apple AVSpeech (free, built-in)
- Google Cloud TTS
- Azure TTS

**Settings UI:**
- Choose voice provider
- Select voice (list available voices from provider)
- Adjust speed, pitch, stability
- Test voice output
- Configure API key for premium providers

---

### 4. Knowledge Sources (MCP Protocol)

**What it is:** Data sources Quinn can query for context.

**MCP servers (user can add custom):**
- Obsidian/Notion (notes)
- Google Drive (documents)
- Slack (messages/channels)
- GitHub (repos, issues, PRs)
- Email (IMAP/Gmail API)
- Calendar (events)

**Settings UI:**
- Add MCP server (stdio or HTTP)
- Configure auth credentials
- Test connection
- Set permissions (read-only vs write)

---

## Settings UI Design

### Main Settings Window

```
┌─────────────────────────────────────────────────────────────┐
│  SoniqueBar Settings                                   [x]  │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  ┌─ Sidebar ───────┐  ┌─ Content ────────────────────────┐ │
│  │                  │  │                                   │ │
│  │ General          │  │  General Settings                │ │
│  │ Voice & Audio    │  │                                   │ │
│  │ LLM Providers    │  │  Wake Word: [Hey Quinn ▼]        │ │
│  │ Connectors       │  │  Assistant Name: [Quinn    ]      │ │
│  │ Knowledge        │  │  Voice Activation: [x] Enabled   │ │
│  │ Privacy          │  │  [] Push-to-talk mode            │ │
│  │ Advanced         │  │                                   │ │
│  │                  │  │  Proactive Alerts:               │ │
│  │                  │  │  [x] Speak critical events        │ │
│  │                  │  │  [x] Morning brief (6:10 AM)     │ │
│  │                  │  │  [] All notifications            │ │
│  │                  │  │                                   │ │
│  │                  │  │  Response Style:                 │ │
│  │                  │  │  [x] Concise (1-2 sentences)     │ │
│  │                  │  │  [] Detailed explanations        │ │
│  └──────────────────┘  └───────────────────────────────────┘ │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### Voice & Audio Tab

```
Voice Input:
  Engine: [Apple Speech ▼]
  Language: [English (US) ▼]
  Noise Cancellation: [x] Enabled

Voice Output:
  Provider: [ElevenLabs ▼]
  Voice: [Rachel - American Female ▼] [🔊 Test]
  Speed: [======|===] 1.0x
  API Key: [••••••••••••••] [Configure]

Output Settings:
  [x] Speak responses out loud
  [x] Only when screen unlocked (presence detection)
  [] Always speak, even when away
  
  Volume: [=======|==] 80%
  Output Device: [System Default ▼]
```

### LLM Providers Tab

```
Configured Providers:
┌─────────────────────────────────────────────────────────────┐
│ ✓ Claude API (Anthropic)                          [Primary] │
│   Model: claude-sonnet-4.5                                  │
│   API Key: ••••••••sk-ant-abc123                            │
│   Features: Conversation, Tools, Vision                     │
│   [Edit] [Test Connection] [Remove]                         │
├─────────────────────────────────────────────────────────────┤
│ ✓ OpenAI API                                      [Fallback] │
│   Model: gpt-4                                              │
│   API Key: ••••••••sk-proj-xyz789                           │
│   Features: Conversation, Tools                             │
│   [Edit] [Test Connection] [Remove]                         │
├─────────────────────────────────────────────────────────────┤
│ ✓ Local LLM (Ollama)                            [Offline]   │
│   Endpoint: http://localhost:11434                          │
│   Model: llama3.2                                           │
│   Features: Conversation                                    │
│   [Edit] [Test Connection] [Remove]                         │
└─────────────────────────────────────────────────────────────┘

[+ Add Provider]

Model Selection Strategy:
  [x] Use primary, fallback on rate limit
  [] Load balance across all providers
  [] Cheapest first
  
Escalation Rules:
  Default: Fastest/cheapest (Haiku)
  "Think harder": Sonnet
  "Emergency": Opus
```

### Connectors Tab

```
Available Connectors:
┌─────────────────────────────────────────────────────────────┐
│ 🔌 Task Management                                          │
│   ✓ Helmsman (Custom)               [charlie@local]  [...]  │
│   ○ Todoist                          [Add]                   │
│   ○ Linear                           [Add]                   │
│   ○ Jira                             [Add]                   │
├─────────────────────────────────────────────────────────────┤
│ 🏠 Home Automation                                          │
│   ✓ HomeKit (Built-in)              [System]         [...]  │
│   ○ HomeAssistant                    [Add]                   │
│   ○ IFTTT                            [Add]                   │
├─────────────────────────────────────────────────────────────┤
│ 💬 Communication                                            │
│   ✓ Slack                            [charlie@...]   [...]  │
│   ○ Discord                          [Add]                   │
│   ○ Email (SMTP)                     [Add]                   │
├─────────────────────────────────────────────────────────────┤
│ 🛠️ Development                                              │
│   ✓ Docker (Local)                   [localhost]     [...]  │
│   ✓ GitHub                           [charlieseay]   [...]  │
│   ○ GitLab                           [Add]                   │
└─────────────────────────────────────────────────────────────┘

[+ Add Custom Connector]

When clicked on a connector:
┌─ Helmsman Configuration ────────────────────────────┐
│ Name: Helmsman Task Dispatch                       │
│ Endpoint: http://localhost:5680/webhook/task-dispatch │
│ Auth Type: [Bearer Token ▼]                        │
│ Token: [•••••••••••] [Reveal]                      │
│ Capabilities:                                       │
│   [x] Create tasks                                  │
│   [x] Query queue                                   │
│   [x] Dispatch briefs                              │
│ Test: [Test Connection] ✓ Connected                │
│                                    [Save] [Cancel]  │
└─────────────────────────────────────────────────────┘
```

### Knowledge Sources Tab

```
MCP Servers:
┌─────────────────────────────────────────────────────────────┐
│ ✓ Obsidian Vault                                   [Active] │
│   Type: stdio                                               │
│   Command: mcp-server-obsidian                              │
│   Vault: /Users/charlie/Documents/SeaynicNet                │
│   Permissions: Read + Write                                 │
│   [Edit] [Test] [Remove]                                    │
├─────────────────────────────────────────────────────────────┤
│ ✓ Google Drive                                     [Active] │
│   Type: HTTP                                                │
│   Endpoint: https://drive-mcp.example.com                   │
│   Auth: OAuth (charlie@gmail.com)                           │
│   Permissions: Read-only                                    │
│   [Edit] [Test] [Remove]                                    │
├─────────────────────────────────────────────────────────────┤
│ ✓ Slack Workspace                                  [Active] │
│   Type: HTTP                                                │
│   Workspace: seayniclabs                                    │
│   Auth: OAuth                                               │
│   Channels: #cael, #general (12 total)                      │
│   [Edit] [Test] [Remove]                                    │
└─────────────────────────────────────────────────────────────┘

[+ Add MCP Server] [Browse Marketplace]
```

### Privacy Tab

```
Data Storage:
  [x] Store conversation history (encrypted, iCloud)
  [x] Store memory/context (iCloud sync across devices)
  Retention: [30 days ▼] [Clear History]

Telemetry:
  [] Send anonymous usage data to improve SoniqueBar
  [] Share crash reports
  
Local Processing:
  [x] Wake word detection (local only, never sent to cloud)
  [x] Voice activity detection (local)
  [] Prefer local LLM when available (slower but private)

Permissions:
  Screen Recording: ✓ Granted (for visual context)
  Microphone: ✓ Granted
  Accessibility: ✓ Granted (for window detection)
  Full Disk Access: ✓ Granted (for calendar via AppleScript)
  
  [Open System Preferences]
```

---

## Code Architecture

### Core App Structure

```
SoniqueBar/
├── App/
│   ├── SoniqueBarApp.swift              # Main app entry
│   ├── Settings/
│   │   ├── SettingsWindow.swift         # Settings UI
│   │   ├── GeneralSettingsView.swift
│   │   ├── VoiceSettingsView.swift
│   │   ├── LLMProvidersView.swift       # LLM configuration
│   │   ├── ConnectorsView.swift         # Plugin management
│   │   └── PrivacySettingsView.swift
│   └── MenuBar/
│       └── MenuBarView.swift            # Menu bar UI
│
├── Core/                                # App Store-ready core
│   ├── Voice/
│   │   ├── WakeWordDetector.swift       # "Hey Quinn" detection
│   │   ├── SpeechRecognizer.swift       # Apple Speech input
│   │   └── VoiceOutput.swift            # TTS abstraction
│   ├── LLM/
│   │   ├── LLMProvider.swift            # Protocol for LLM providers
│   │   ├── ClaudeProvider.swift
│   │   ├── OpenAIProvider.swift
│   │   ├── GeminiProvider.swift
│   │   └── LLMRouter.swift              # Model selection logic
│   ├── Memory/
│   │   ├── MemoryService.swift          # Conversation history
│   │   └── ProfileManager.swift         # iCloud-synced profiles
│   ├── Connectors/
│   │   ├── ConnectorProtocol.swift      # Plugin interface
│   │   ├── ConnectorRegistry.swift      # Manage installed connectors
│   │   └── BuiltInConnectors/
│   │       ├── HomeKitConnector.swift
│   │       ├── CalendarConnector.swift
│   │       └── EmailConnector.swift
│   └── MCP/
│       ├── MCPClient.swift              # MCP protocol client
│       └── MCPServerManager.swift       # Manage MCP servers
│
├── Services/                            # Shared services
│   ├── CommandServer.swift             # HTTP server (local control)
│   ├── NotificationService.swift       # Alerts
│   └── PresenceDetection.swift         # User presence (screen lock, idle)
│
└── Extensions/                          # Charlie's custom connectors
    ├── HelmsmanConnector.swift         # Task dispatch webhook
    ├── DockerConnector.swift           # Container management
    └── VaultConnector.swift            # Obsidian MCP wrapper
```

### Plugin Bundle Format

**Custom connectors are separate .soniquePlugin bundles:**

```
HelmsmanConnector.soniquePlugin/
├── Info.plist
│   - Name: "Helmsman Task Dispatch"
│   - Version: 1.0.0
│   - Capabilities: ["create_task", "query_queue"]
│   - Author: "Charlie Seay"
├── connector.json              # Connector manifest
└── icon.png                    # 128x128 icon
```

**connector.json:**
```json
{
  "name": "Helmsman Task Dispatch",
  "version": "1.0.0",
  "endpoint": "http://localhost:5680/webhook/task-dispatch",
  "auth": {
    "type": "bearer",
    "tokenEnvVar": "HELMSMAN_DISPATCH_SECRET"
  },
  "capabilities": [
    {
      "name": "create_task",
      "description": "Create a new task in Helmsman queue",
      "parameters": {
        "task": "string",
        "owner": "string",
        "project": "string",
        "effort": "enum[S,M,L,XL]",
        "context": "string"
      }
    },
    {
      "name": "query_queue",
      "description": "Get pending tasks from Helmsman",
      "parameters": {
        "status": "enum[pending,running,done]",
        "owner": "string?"
      }
    }
  ]
}
```

---

## Deployment Strategy

### App Store Distribution

**What ships:**
- SoniqueBar.app (core voice assistant)
- Built-in LLM providers (Claude, OpenAI, Gemini, local)
- Built-in connectors (HomeKit, Calendar, Email, Notes)
- Settings UI for configuration
- Plugin system for extending

**What's private (Charlie's setup):**
- Custom connectors (Helmsman, Docker, Vault)
- API keys/secrets (user provides their own)
- Lab automation scripts
- Internal infrastructure

**Pricing model options:**
1. Free with limited features (local LLM only, no TTS)
2. Premium subscription ($9.99/mo): All LLM providers, premium TTS, unlimited connectors
3. One-time purchase ($49.99): Lifetime access

---

## Migration Path (Charlie's Current Setup → App Store Ready)

### Phase 1: Extract Connector Interface (This Week)
- Define `ConnectorProtocol` for plugins
- Refactor Helmsman webhook calls to use connector
- Move Docker/Slack to separate connector classes
- Settings UI for adding/configuring connectors

### Phase 2: LLM Provider Abstraction (Next Week)
- Abstract `ask_claude`, `ask_gemini`, etc. into `LLMProvider` protocol
- Settings UI for API key configuration
- Model routing logic (preference chain, escalation)

### Phase 3: Voice Output System (Week 3)
- Implement `VoiceOutput` protocol (ElevenLabs, OpenAI, AVSpeech)
- Settings UI for voice selection
- Presence detection (only speak when user present)
- Proactive alerts

### Phase 4: Wake Word + Always-On (Week 4)
- Integrate Porcupine wake word detection
- Background audio listening
- Privacy settings (local-only processing)

### Phase 5: Polish for App Store (Week 5-6)
- Settings UI complete
- Onboarding flow for new users
- Documentation + help system
- Submit to App Store review

---

## Key Benefits of This Architecture

1. **Shippable to App Store** - No proprietary code or secrets in distributed app
2. **User-Friendly** - Anyone can configure their own LLM API keys, connectors
3. **Extensible** - Plugin system allows custom integrations without forking
4. **Privacy-First** - User controls what data is sent where
5. **Revenue-Ready** - Can monetize as SaaS or one-time purchase
6. **Reference Implementation** - Charlie's lab setup becomes documentation for power users

---

## Next Steps

**Want me to start building this?** I'll implement:
1. Connector protocol + registry
2. LLM provider abstraction
3. Settings UI scaffold
4. Helmsman connector as reference implementation
5. Voice output system with ElevenLabs

Then we'll have the foundation for a shippable product while keeping all your bells and whistles working.
