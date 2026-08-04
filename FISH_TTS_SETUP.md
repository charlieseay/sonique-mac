# Fish Speech TTS - Setup & Next Steps

## ✅ What's Done (Build 77)

1. **Compiled Fish Speech Rust** - 17MB static binary with Metal support
2. **Bundled in SoniqueBar** - Binary + default voice in Resources/
3. **Swift Integration** - FishTTSManager + FishTTS client
4. **Auto-launch** - Starts on SoniqueBar startup
5. **Process Running** - Confirmed via `ps aux`

## ⚠️ First Run: Model Download

Fish TTS needs to download models from HuggingFace on first run (~2GB):

```bash
# The binary will auto-download on first TTS request
# Or manually trigger:
cd ~/Applications/SoniqueBar.app/Contents/Resources
./fish-tts --port 3000 --voice-dir voices
# Watch for HuggingFace download progress
```

**Models downloaded to:** `~/.cache/huggingface/`

## 🔧 Remaining Tasks

### 1. Xcode Project - Add Resources to Build Phase

Currently fish-tts binary is manually copied. Need to add to Xcode:

1. Open `SoniqueBar.xcodeproj` in Xcode
2. Select SoniqueBar target → Build Phases
3. Add "Copy Files" phase:
   - Destination: Resources
   - Add: `SoniqueBar/Resources/fish-tts`
   - Add: `SoniqueBar/Resources/voices/` (folder reference)

### 2. iOS Update

Update iOS to use Fish TTS endpoint:

**File:** `Sonique/VoiceBoxTTS.swift` (rename to `FishTTS.swift`)

```swift
// Change endpoint from:
let url = URL(string: "http://\(soniqueBarHost):8890/synthesize/voicebox")

// To:
let url = URL(string: "http://\(soniqueBarHost):8890/synthesize/fish")
```

### 3. LLM Provider Configuration (BYO-AI)

**Architecture:** Sonique supports both **subscriptions** (CLI) and **API keys** (user brings own).

**Seaynic Labs defaults (zero API cost):**
- ✅ Ollama (local, bundled)
- ✅ Claude CLI (`ask_claude` subscription)
- ✅ Antigravity CLI (`agy` subscription - replaces Gemini CLI)

**User can provide (BYO-AI):**
- Anthropic API key
- OpenAI API key
- Gemini API key
- Grok API key
- Custom endpoints (e.g., OpenRouter, LocalAI)

**Config file:** `~/Library/Application Support/SoniqueBar/config/model_router.json`

Example config showing both patterns:

```json
{
  "mode": "adaptive",
  "providers": {
    "ollama": {
      "enabled": true,
      "type": "ollama",
      "endpoint": "http://localhost:11434",
      "models": {
        "conversational": "llama3.3",
        "thinking": "llama3.3:70b",
        "tools": "qwen3"
      },
      "timeout": 30.0,
      "priority": 1
    },
    "claude-cli": {
      "enabled": true,
      "type": "claudeAPI",
      "cliCommand": "ask_claude -p",
      "models": {
        "conversational": "claude-sonnet-4.6",
        "thinking": "claude-sonnet-4.6",
        "tools": "claude-sonnet-4.6"
      },
      "timeout": 60.0,
      "priority": 2
    },
    "antigravity": {
      "enabled": true,
      "type": "openaiAPI",
      "cliCommand": "agy -p",
      "models": {
        "conversational": "gemini-3-flash",
        "thinking": "gemini-3-pro",
        "tools": "gemini-3-pro"
      },
      "timeout": 60.0,
      "priority": 3
    },
    "anthropic-api": {
      "enabled": false,
      "type": "claudeAPI",
      "endpoint": "https://api.anthropic.com/v1/messages",
      "apiKey": "<user-provided-anthropic-key>",
      "models": {
        "conversational": "claude-sonnet-4.6",
        "thinking": "claude-opus-5",
        "tools": "claude-sonnet-4.6"
      },
      "timeout": 60.0,
      "priority": 4
    },
    "openai-api": {
      "enabled": false,
      "type": "openaiAPI",
      "endpoint": "https://api.openai.com/v1/chat/completions",
      "apiKey": "<user-provided-openai-key>",
      "models": {
        "conversational": "gpt-4o-mini",
        "thinking": "gpt-4o",
        "tools": "gpt-4o"
      },
      "timeout": 60.0,
      "priority": 5
    }
  },
  "escalation": {
    "enabled": true,
    "thinkingKeywords": true,
    "toolUseDetected": true,
    "responseUnsatisfactory": true,
    "revertAfterResponse": true
  },
  "tts": {
    "primary": "fish",
    "fallbackChain": ["fish", "system"]
  }
}
```

**Install Antigravity CLI** (replaces deprecated Gemini CLI):

```bash
# Install agy CLI
curl -fsSL https://antigravity.google/install.sh | sh

# Login with Google Account (subscription required: $20/mo Pro or $100/mo Ultra)
agy login

# Test multi-model access
agy -p "test" --model gemini-3-flash
agy -p "test" --model claude-sonnet-4.6
```

## 📊 Architecture

```
SoniqueBar.app
├── Contents/
│   ├── MacOS/
│   │   └── SoniqueBar (main binary)
│   └── Resources/
│       ├── fish-tts (17MB Rust binary) ← bundled
│       └── voices/
│           ├── default.npy
│           └── index.json
```

**Process tree:**
```
SoniqueBar (PID 95985)
└── fish-tts --port 3000 --voice-dir <resources>/voices (PID 96014)
```

**API:**
- Fish TTS: `http://127.0.0.1:3000` (OpenAI-compatible)
- SoniqueBar proxy: `http://127.0.0.1:8890/synthesize/fish`

## 🧪 Testing

Once models are downloaded:

```bash
# Test Fish TTS directly
curl -X POST http://127.0.0.1:3000/v1/audio/speech \
  -H "Content-Type: application/json" \
  -d '{"input":"Hello world","voice":"default","model":"tts-1","response_format":"wav"}' \
  --output test.wav

# Test via SoniqueBar
curl -X POST http://127.0.0.1:8890/synthesize/fish \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <token>" \
  -d '{"text":"Hello from Fish TTS"}' \
  --output test.pcm
```

## 📚 References

- [Fish Speech GitHub](https://github.com/fishaudio/fish-speech)
- [Fish Speech Rust](https://github.com/EndlessReform/fish-speech.rs)
- [Antigravity CLI Guide](https://pasqualepillitteri.it/en/news/3422/antigravity-cli-agy-install-migrate-gemini-cli)
