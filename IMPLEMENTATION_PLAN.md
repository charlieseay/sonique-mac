# Sonique User-Configurable Provider System

## Requirements (2026-07-20)

### TTS Requirements
- **Primary**: VoiceBox (Kokoro) - bundled, local, fast, free
- **Optional**: ElevenLabs - user can add API key if they choose premium quality
- **Fallback**: System voice (macOS `say`) when both unavailable

### LLM Requirements
- **User-Configurable Providers**:
  - Local: Ollama on ThinkPad (192.168.68.89:11434)
  - Subscription: Claude CLI (Haiku/Sonnet/Opus via subscription)
  - Subscription: Gemini CLI
  - API: Bedrock (AWS)
  - API: NVIDIA
  - API: OpenAI
  - Custom: User-defined endpoint

- **Automatic Tier Escalation**:
  - **Conversational**: Fast, cheap models (Haiku/Ollama/Gemini Flash)
  - **Thinking**: Medium models when reasoning detected
  - **Tools**: Complex models when MCP tools invoked
  - **Auto-revert**: Back to conversational after task complete

- **UI Control**: Slider in SoniqueBar Settings
  - Dynamically generated based on user's configured models
  - Example: If user enables Claude CLI with Opus, slider allows escalation to Opus
  - If user only has Ollama, slider shows local models only

### Performance Target
- Response time: As fast and accurate as possible
- Prefer local/subscription over paid API
- Escalate only when genuinely needed

---

## Architecture

### Current State (Build 618cf63e)
```
SoniqueBar
├── ModelRouter (exists, needs enhancement)
│   ├── Single mode: one provider for all
│   └── Tiered mode: simple/medium/complex
└── CommandServer
    └── /synthesize → ElevenLabs or macOS say
```

### Target State
```
SoniqueBar
├── Enhanced ModelRouter
│   ├── User Provider Registry
│   │   ├── Available providers scan
│   │   ├── User-enabled providers
│   │   └── Priority/tier assignment
│   ├── Dynamic Tier Escalation
│   │   ├── Conversational tier (default)
│   │   ├── Thinking tier (reasoning detected)
│   │   ├── Tools tier (MCP tools invoked)
│   │   └── Auto-revert logic
│   └── Performance Optimization
│       ├── Timeout management
│       ├── Parallel probing
│       └── Failover chains
└── Enhanced TTS System
    ├── VoiceBox (primary, embedded)
    ├── ElevenLabs (optional, user config)
    └── System Voice (fallback)
```

---

## Implementation Phases

### Phase 1: Enhanced ModelRouter Config Schema
**File**: `/Volumes/data/secrets/sonique_model_router.json`

```json
{
  "mode": "adaptive",  // "single", "tiered", or "adaptive"
  
  "providers": {
    "ollama_local": {
      "enabled": true,
      "type": "ollama",
      "endpoint": "http://192.168.68.89:11434",
      "models": {
        "conversational": "qwen2.5:14b-instruct-q4_K_M",
        "thinking": "deepseek-r1:14b",
        "tools": "qwen2.5-coder:14b-q4"
      },
      "timeout": 15.0,
      "priority": 1  // Try first
    },
    
    "claude_cli": {
      "enabled": true,
      "type": "claudeCLI",
      "cliCommand": "/opt/homebrew/bin/claude",
      "models": {
        "conversational": "haiku",
        "thinking": "sonnet",
        "tools": "opus"
      },
      "timeout": 30.0,
      "priority": 2  // Fallback if Ollama fails/timeout
    },
    
    "elevenlabs_optional": {
      "enabled": false,  // User must enable + add API key
      "type": "elevenLabsAPI",
      "apiKey": null,
      "voiceID": "21m00Tcm4TlvDq8ikWAM"  // Rachel
    }
  },
  
  "escalation": {
    "enabled": true,
    "triggers": {
      "thinking_keywords": ["explain", "why", "analyze", "summarize", "compare"],
      "tool_use_detected": true,
      "response_unsatisfactory": true  // If conversational model says "I don't know"
    },
    "revert_after_response": true  // Auto-downgrade after complex query answered
  },
  
  "tts": {
    "primary": "voicebox",  // "voicebox", "elevenlabs", or "system"
    "fallback_chain": ["voicebox", "system"]
  }
}
```

### Phase 2: Dynamic Provider Detection
**New File**: `SoniqueBar/Services/ProviderDetector.swift`

```swift
class ProviderDetector {
    static func detectAvailableProviders() async -> [String: ProviderStatus] {
        var status: [String: ProviderStatus] = [:]
        
        // Check Ollama
        if await checkOllama("http://localhost:11434") {
            status["ollama_local"] = .available
        }
        
        // Check Claude CLI
        if FileManager.default.fileExists(atPath: "/opt/homebrew/bin/claude") {
            status["claude_cli"] = .available
        }
        
        // Check VoiceBox binary
        if Bundle.main.path(forResource: "sonique-tts", ofType: nil) != nil {
            status["voicebox"] = .available
        }
        
        return status
    }
}
```

### Phase 3: Adaptive Tier Selection
**Update**: `ModelRouter.swift`

```swift
enum QueryTier {
    case conversational  // Fast, cheap
    case thinking        // Medium reasoning
    case tools           // Complex tool use
}

class ModelRouter {
    func route(prompt: String, context: QueryContext? = nil) async throws -> String {
        // 1. Determine tier
        let tier = determineTier(prompt: prompt, context: context)
        
        // 2. Get provider for tier
        let providers = getProvidersForTier(tier)
        
        // 3. Try in priority order
        for provider in providers {
            do {
                let response = try await callProvider(provider, prompt: prompt)
                
                // 4. Check if escalation needed
                if shouldEscalate(response, currentTier: tier) {
                    return try await route(prompt: prompt, 
                                         context: QueryContext(forceTier: .tools))
                }
                
                return response
            } catch {
                // Continue to next provider
                continue
            }
        }
        
        throw RouterError.allProvidersFailed
    }
    
    private func determineTier(prompt: String, context: QueryContext?) -> QueryTier {
        if let forced = context?.forceTier { return forced }
        
        // Check for tool invocation context
        if context?.mcpToolsAvailable == true {
            return .tools
        }
        
        // Check for thinking keywords
        let thinkingKeywords = ["explain", "why", "analyze", "summarize", "compare"]
        if thinkingKeywords.contains(where: { prompt.lowercased().contains($0) }) {
            return .thinking
        }
        
        return .conversational
    }
    
    private func shouldEscalate(_ response: String, currentTier: QueryTier) -> Bool {
        guard currentTier != .tools else { return false }  // Already at max
        
        // Escalate if model indicates uncertainty
        let uncertainPhrases = [
            "I don't have current information",
            "I'm not sure",
            "I cannot",
            "I don't know"
        ]
        
        return uncertainPhrases.contains(where: { response.contains($0) })
    }
}
```

### Phase 4: Settings UI (SwiftUI)
**New File**: `SoniqueBar/Views/ProviderSettingsView.swift`

```swift
struct ProviderSettingsView: View {
    @StateObject private var config = ProviderConfig.shared
    @State private var availableProviders: [String: ProviderStatus] = [:]
    
    var body: some View {
        Form {
            // LLM Providers Section
            Section("LLM Providers") {
                ForEach(config.llmProviders) { provider in
                    ProviderRow(provider: provider, 
                              isAvailable: availableProviders[provider.id] == .available)
                }
            }
            
            // Escalation Settings
            Section("Auto-Escalation") {
                Toggle("Enable Smart Escalation", isOn: $config.escalationEnabled)
                
                if config.escalationEnabled {
                    Picker("Max Tier", selection: $config.maxTier) {
                        Text("Conversational Only").tag(QueryTier.conversational)
                        Text("Allow Thinking").tag(QueryTier.thinking)
                        Text("Allow Tools (Full)").tag(QueryTier.tools)
                    }
                }
            }
            
            // TTS Providers Section
            Section("Voice Synthesis") {
                Picker("Primary TTS", selection: $config.primaryTTS) {
                    Text("VoiceBox (Local)").tag("voicebox")
                    if config.elevenLabsEnabled {
                        Text("ElevenLabs (Cloud)").tag("elevenlabs")
                    }
                    Text("System Voice").tag("system")
                }
                
                if !config.elevenLabsEnabled {
                    Button("Add ElevenLabs...") {
                        // Show API key input sheet
                    }
                }
            }
        }
        .task {
            availableProviders = await ProviderDetector.detectAvailableProviders()
        }
    }
}
```

---

## Migration Path

### Step 1: Non-Breaking Enhancement
- Keep existing ModelRouter working
- Add new adaptive mode alongside `single`/`tiered`
- VoiceBox integration doesn't break existing ElevenLabs path

### Step 2: User Migration
- On first launch after update, detect available providers
- Generate recommended config based on what's installed
- Show one-time setup wizard in Settings

### Step 3: Default Config
```json
{
  "mode": "adaptive",
  "providers": {
    "system_voice": {
      "enabled": true,
      "type": "system",
      "priority": 99
    }
  },
  "tts": {
    "primary": "system"
  }
}
```
Users add Ollama/Claude CLI/ElevenLabs as they install them.

---

## Testing Plan

### Test 1: Conversational Tier (Fast Path)
```
User: "What time is it?"
Expected: Ollama qwen2.5:14b responds in <2s
```

### Test 2: Auto-Escalation to Thinking
```
User: "Explain how barge-in detection works in VoiceSession"
Expected: 
1. Qwen2.5 starts response
2. Router detects "explain" keyword
3. Escalates to DeepSeek-R1:14b for reasoning
```

### Test 3: Tool Use Escalation
```
User: "Create a task in helmsman to fix the TTS issue"
Expected:
1. Router detects MCP tool call needed
2. Escalates to Claude CLI Opus (has MCP access)
3. Task created via MCP
4. Reverts to Qwen2.5 for conversational response
```

### Test 4: Fallback Chain
```
Scenario: Ollama ThinkPad offline
Expected:
1. Attempt Ollama → timeout 5s
2. Fall back to Claude CLI Haiku
3. Response in <8s total
```

### Test 5: VoiceBox Primary TTS
```
User asks any question
Expected:
1. LLM responds (any provider)
2. SoniqueBar calls embedded VoiceBox binary
3. Audio plays through iOS client
4. Quality matches Kokoro af_bella voice
```

---

## Performance Targets

| Metric | Target | Notes |
|--------|--------|-------|
| Conversational response | <3s | Ollama local + VoiceBox TTS |
| Thinking response | <8s | DeepSeek-R1 reasoning |
| Tools response | <15s | Claude Opus + MCP calls |
| Escalation decision | <500ms | Keyword detection + tier selection |
| Provider failover | <5s timeout | Quick fallback to next provider |
| TTS synthesis | <1s | VoiceBox PCM generation |

---

## Files to Create/Modify

### New Files
- [ ] `SoniqueBar/Services/ProviderDetector.swift`
- [ ] `SoniqueBar/Services/ProviderConfig.swift`
- [ ] `SoniqueBar/Views/ProviderSettingsView.swift`
- [ ] `SoniqueBar/Models/QueryContext.swift`
- [ ] `tts-engine/` directory (VoiceBox minimal extraction)
- [ ] `tts-engine/build_binary.py`
- [ ] `SoniqueBar/TTS/EmbeddedTTSProvider.swift`

### Modified Files
- [ ] `SoniqueBar/Services/ModelRouter.swift` (enhance with adaptive mode)
- [ ] `SoniqueBar/Services/CommandServer.swift` (add VoiceBox synthesis)
- [ ] `SoniqueBar/Services/ClaudeCodeBridge.swift` (pass QueryContext)
- [ ] `/Volumes/data/secrets/sonique_model_router.json` (new schema)

---

## Next Actions

1. Extract VoiceBox minimal TTS engine
2. Build PyInstaller binary
3. Implement EmbeddedTTSProvider in Swift
4. Enhance ModelRouter with adaptive mode
5. Create Settings UI for provider config
6. Test end-to-end with all tiers
7. Document user setup guide

---

**Status**: Ready to implement  
**Priority**: HIGH (core requirements missed for weeks)  
**Estimated Time**: 8-12 hours total
