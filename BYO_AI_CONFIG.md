# Sonique BYO-AI Configuration Guide

## Overview

Sonique supports **Bring Your Own AI** — users can configure their own LLM providers using either:

1. **Subscriptions** (CLI-based, zero API cost)
2. **API Keys** (user-provided, pay-per-use)
3. **Local Models** (Ollama, bundled, free)

## Default Configuration (Seaynic Labs)

**Zero API cost** — all subscription-based or local:

| Provider | Type | Models | Cost |
|----------|------|--------|------|
| **Ollama** | Local | llama3.3, qwen3 | Free (bundled) |
| **Claude CLI** | Subscription | Claude Sonnet 4.6 | $20/mo (Max 5x) |
| **Antigravity** | Subscription | Gemini 3, Claude, GPT | $20-$100/mo |

## User Configuration (BYO-AI)

Users can add their own providers in Settings → AI Providers:

### Supported Provider Types

1. **Anthropic API**
   - API key from console.anthropic.com
   - Models: Claude Opus 5, Sonnet 4.6, Haiku 4.5
   - Cost: $3-15 per million tokens

2. **OpenAI API**
   - API key from platform.openai.com
   - Models: GPT-4o, GPT-4o-mini, o1, o3-mini
   - Cost: $0.15-60 per million tokens

3. **Google AI API**
   - API key from ai.google.dev
   - Models: Gemini 3 Flash, Pro, Ultra
   - Cost: Free tier + paid

4. **Grok API**
   - API key from x.ai
   - Models: grok-3, grok-3-vision
   - Cost: Variable

5. **OpenRouter**
   - API key from openrouter.ai
   - Models: 200+ models (Claude, GPT, Gemini, Llama, Mistral, etc.)
   - Cost: Variable (per-model)

6. **Custom Endpoints**
   - Any OpenAI-compatible endpoint
   - LocalAI, LM Studio, vLLM, etc.

## Configuration File

**Location:** `~/Library/Application Support/SoniqueBar/config/model_router.json`

**Format:**

```json
{
  "mode": "adaptive",
  "providers": {
    "<provider-name>": {
      "enabled": true|false,
      "type": "ollama" | "claudeAPI" | "openaiAPI",
      "endpoint": "<optional-custom-endpoint>",
      "cliCommand": "<optional-cli-command>",
      "apiKey": "<optional-api-key>",
      "models": {
        "conversational": "<model-for-chat>",
        "thinking": "<model-for-reasoning>",
        "tools": "<model-for-tool-use>"
      },
      "timeout": 30.0,
      "priority": 1
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

## Provider Examples

### 1. Anthropic API (User Brings API Key)

```json
"anthropic-api": {
  "enabled": true,
  "type": "claudeAPI",
  "endpoint": "https://api.anthropic.com/v1/messages",
  "apiKey": "sk-ant-api03-...",
  "models": {
    "conversational": "claude-sonnet-4.6-20250922",
    "thinking": "claude-opus-5-20250514",
    "tools": "claude-sonnet-4.6-20250922"
  },
  "timeout": 60.0,
  "priority": 2
}
```

### 2. OpenAI API (User Brings API Key)

```json
"openai-api": {
  "enabled": true,
  "type": "openaiAPI",
  "endpoint": "https://api.openai.com/v1/chat/completions",
  "apiKey": "sk-...",
  "models": {
    "conversational": "gpt-4o-mini",
    "thinking": "o3-mini",
    "tools": "gpt-4o"
  },
  "timeout": 60.0,
  "priority": 3
}
```

### 3. OpenRouter (User Brings API Key)

```json
"openrouter": {
  "enabled": true,
  "type": "openaiAPI",
  "endpoint": "https://openrouter.ai/api/v1/chat/completions",
  "apiKey": "sk-or-v1-...",
  "models": {
    "conversational": "anthropic/claude-3.5-sonnet",
    "thinking": "openai/o3-mini",
    "tools": "google/gemini-2.0-flash-thinking-exp"
  },
  "timeout": 60.0,
  "priority": 4
}
```

### 4. LocalAI (Custom Endpoint, No API Key)

```json
"localai": {
  "enabled": true,
  "type": "openaiAPI",
  "endpoint": "http://localhost:8080/v1/chat/completions",
  "models": {
    "conversational": "llama-3.3-70b-instruct",
    "thinking": "deepseek-r1-distill-qwen-32b",
    "tools": "qwen2.5-coder-32b-instruct"
  },
  "timeout": 120.0,
  "priority": 5
}
```

### 5. Ollama (Local, Already Bundled)

```json
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
}
```

### 6. Claude CLI (Subscription, Zero API Cost)

```json
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
}
```

### 7. Antigravity CLI (Subscription, Zero API Cost)

```json
"antigravity": {
  "enabled": true,
  "type": "openaiAPI",
  "cliCommand": "agy -p",
  "models": {
    "conversational": "gemini-3-flash",
    "thinking": "claude-sonnet-4.6",
    "tools": "gemini-3-pro"
  },
  "timeout": 60.0,
  "priority": 3
}
```

## Routing Modes

### 1. **Adaptive** (Recommended)

Automatically selects provider based on query complexity:

- **Conversational** → Fast local models (Ollama llama3.3)
- **Thinking** → Reasoning models (Claude Sonnet, o3-mini)
- **Tools** → Tool-use optimized (Claude Sonnet, Gemini Pro)

Escalates if response is unsatisfactory.

### 2. **Tiered**

Uses all enabled providers in priority order:
1. Try priority 1 first
2. If it fails, try priority 2
3. Continue until success

### 3. **Single**

Uses only the highest-priority enabled provider.

## Priority System

Lower number = higher priority:

- **Priority 1**: Local/free first (Ollama)
- **Priority 2**: Subscription CLI (Claude, Antigravity)
- **Priority 3**: User API keys (only if enabled)
- **Priority 4+**: Fallbacks

## Escalation Rules

When enabled, Sonique automatically escalates to higher-tier models when:

1. **Thinking keywords detected** ("explain", "analyze", "why")
2. **Tool use detected** (calendar, Slack, vault search)
3. **Response unsatisfactory** (contains "I don't know", "I'm not sure")

Reverts to lower tier after complex query completes.

## TTS Configuration

```json
"tts": {
  "primary": "fish",
  "fallbackChain": ["fish", "elevenLabs", "system"]
}
```

**Supported TTS providers:**
- `"fish"` — Bundled Fish Speech (free, local)
- `"elevenlabs"` — User API key (if provided)
- `"system"` — macOS native TTS (fallback)

## Settings UI

Users configure providers in:

**SoniqueBar → Settings → AI Providers**

Fields:
- Provider name
- Type (dropdown: Anthropic, OpenAI, Custom)
- API key (password field)
- Endpoint (optional)
- Enabled toggle
- Priority slider
- Model selection per tier

## Security

- API keys stored in **macOS Keychain** (never in JSON)
- Config file only stores keychain references
- Keys never logged or transmitted except to configured endpoint

## Cost Tracking

Sonique tracks token usage per provider:

- **Free tier warnings** when approaching limits
- **Cost estimates** based on provider pricing
- **Monthly spend** dashboard in Settings

## Example: Complete BYO-AI Setup

**User has:**
- Anthropic API key
- OpenAI API key
- Ollama running locally

**Config:**

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
    "anthropic": {
      "enabled": true,
      "type": "claudeAPI",
      "endpoint": "https://api.anthropic.com/v1/messages",
      "apiKey": "<keychain:anthropic-api-key>",
      "models": {
        "conversational": "claude-sonnet-4.6-20250922",
        "thinking": "claude-opus-5-20250514",
        "tools": "claude-sonnet-4.6-20250922"
      },
      "timeout": 60.0,
      "priority": 2
    },
    "openai": {
      "enabled": true,
      "type": "openaiAPI",
      "endpoint": "https://api.openai.com/v1/chat/completions",
      "apiKey": "<keychain:openai-api-key>",
      "models": {
        "conversational": "gpt-4o-mini",
        "thinking": "o3-mini",
        "tools": "gpt-4o"
      },
      "timeout": 60.0,
      "priority": 3
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

**Routing behavior:**

1. Simple chat → **Ollama llama3.3** (local, instant, free)
2. "Explain quantum entanglement" → Escalates to **Claude Opus 5** (thinking tier)
3. "Add task to Helmsman" → Escalates to **Claude Sonnet 4.6** (tool use)
4. Ollama offline → Falls back to **Anthropic API**
5. Anthropic fails → Falls back to **OpenAI API**

## Testing

After adding a provider, test it:

```bash
# Test via CLI
curl -X POST http://127.0.0.1:8890/query \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <sonique-token>" \
  -d '{"query":"Test message","provider":"anthropic"}'

# Or via Settings → AI Providers → Test
```

## Troubleshooting

**Provider not responding:**
1. Check API key in Keychain Access
2. Verify endpoint URL
3. Test with `curl` directly
4. Check SoniqueBar logs: `/tmp/soniquebar.log`

**Escalation not working:**
1. Verify `escalation.enabled: true`
2. Check priority order (lower = higher priority)
3. Ensure multiple providers enabled

**Cost too high:**
1. Enable Ollama for conversational tier
2. Reserve Claude/OpenAI for thinking/tools only
3. Set usage limits in provider config

## Migration from Gemini CLI

**Old (deprecated):**
```json
"gemini": {
  "cliCommand": "gemini --prompt"
}
```

**New (Antigravity):**
```json
"antigravity": {
  "cliCommand": "agy -p"
}
```

Install Antigravity: `curl -fsSL https://antigravity.google/install.sh | sh`
