# Quinn Lab Connectors - Integration Guide

Quinn Brain Service connects to all lab systems via a modular connector architecture. Each connector handles one lab subsystem.

## Architecture

```
iOS/Mac (SoniqueBar) 
    → Quinn Brain Service (port 5912)
    → Connector Registry
    → [Helmsman | Docker | Slack | Vault | Home Assistant]
```

## Available Connectors

### 1. Helmsman Connector
**Purpose:** Task queue and lab orchestration  
**Status:** ✅ Working

**Operations:**
- `create_task` - Create a new task in helmsman.db
- `list_pending` - List pending tasks
- `get_task` - Get details about a task
- `complete_task` - Mark a task as complete

**Example commands:**
```
"Create task: Test Sonique integration"
"What tasks are pending?"
"What's task #285 about?"
```

**Implementation:** `connectors/helmsman.py`
- Uses helmsman.db REST API (localhost:5682)
- NO subscriptions or API keys needed (internal lab service)

### 2. Docker Connector
**Purpose:** Container management  
**Status:** ✅ Working

**Operations:**
- `list_containers` - List running containers
- `restart_container` - Restart a container
- `stop_container` - Stop a container
- `start_container` - Start a container
- `container_status` - Get status of a specific container

**Example commands:**
```
"List running containers"
"Restart the bridge container"
"What's the status of n8n-control?"
"Stop the hone container"
```

**Implementation:** `connectors/docker.py`
- Uses Docker CLI (`docker ps`, `docker restart`, etc.)
- No API calls needed

### 3. Slack Connector
**Purpose:** Post messages to Slack  
**Status:** ✅ Working

**Operations:**
- `post_message` - Post a message to a Slack channel

**Example commands:**
```
"Post to #alerts: Testing Sonique"
"Send a message to #general: Quinn is online"
```

**Implementation:** `connectors/slack.py`
- Uses `slack-post-filtered` command
- Respects priority levels (low/normal/high/question/error)
- Low-priority messages are silent in Slack

### 4. Vault Connector
**Purpose:** Query Obsidian vault via MCP  
**Status:** ⚠️ Partial (needs MCP vault server running)

**Operations:**
- `read_note` - Read a note from vault
- `search` - Search vault for notes
- `create_note` - Create a new note
- `append_note` - Append to existing note

**Example commands:**
```
"What does the Sonique project note say?"
"Search vault for 'Quinn Brain'"
"Read the latest daily note"
```

**Implementation:** `connectors/vault.py`
- Calls MCP vault-mcp server (localhost:3700)
- Requires vault MCP server running separately

### 5. Home Assistant Connector
**Purpose:** Smart home device control  
**Status:** ⚠️ Partial (needs Home Assistant running)

**Operations:**
- `turn_on` - Turn on a device/light
- `turn_off` - Turn off a device/light
- `toggle` - Toggle device state
- `set_brightness` - Set light brightness (0-255)
- `activate_scene` - Activate a Home Assistant scene
- `list_devices` - List available devices
- `get_state` - Get device state

**Example commands:**
```
"Turn on the bedroom light"
"Turn off all lights"
"Set living room brightness to 50%"
"Activate movie mode"
```

**Implementation:** `connectors/home_assistant.py`
- Calls Home Assistant REST API (192.168.68.80:8123)
- Requires HA token in `/Volumes/data/secrets/home_assistant_token`

## How Quinn Routes Commands

Quinn uses simple pattern matching to detect connector operations:

1. **User speaks:** "Create task: Fix barge-in latency"
2. **Quinn parses:** Detects "create" + "task" → Helmsman connector
3. **Connector executes:** Posts task to helmsman.db
4. **Response:** "Task created successfully: Fix barge-in latency"

If no connector matches, Quinn falls back to Claude conversation (Haiku/Sonnet/Opus).

## Testing

Run the connector test suite:

```bash
bash test-connectors.sh
```

Output: 10 tests across all 5 connectors

### Manual Testing

Health check all connectors:
```bash
curl http://127.0.0.1:5912/connectors/health | jq
```

Send a command to Quinn:
```bash
curl -X POST http://127.0.0.1:5912/respond \
  -H "Content-Type: application/json" \
  -d '{"text":"List running containers"}'
```

## Setup Instructions

### 1. Start Quinn Brain Service

```bash
cd ~/Projects/sonique-mac
python3 quinn-brain-svc.py
```

Service runs on `127.0.0.1:5912`

### 2. Verify Personality Loaded

Quinn personality files should be in iCloud:
```
~/Library/Mobile Documents/iCloud~com~seayniclabs~sonique/Documents/SoniqueProfiles/shared/
├── IDENTITY.md
├── RULES.md
└── SOUL.md
```

### 3. Enable Vault Integration (Optional)

Start vault MCP server:
```bash
# From your vault MCP setup
# Requires vault running at localhost:3700
```

### 4. Enable Home Assistant (Optional)

1. Get HA token from Home Assistant UI
2. Save to `/Volumes/data/secrets/home_assistant_token`
3. Verify HA is accessible at `192.168.68.80:8123`

## Architecture Details

### Connector Protocol

All connectors implement `ConnectorBase`:

```python
class ConnectorBase(ABC):
    @abstractmethod
    def health_check(self) -> ConnectorResult:
        """Verify the connector is working"""

    @abstractmethod
    def execute(self, operation: str, **kwargs) -> ConnectorResult:
        """Execute an operation"""
```

### ConnectorResult

Standard response format:

```python
@dataclass
class ConnectorResult:
    success: bool
    data: Any = None
    error: Optional[str] = None
    connector: str = ""
```

### ConnectorRegistry

Manages all connectors:

```python
registry = ConnectorRegistry()

# Execute an operation
result = registry.execute("helmsman", "create_task", task="...")

# Check health
health = registry.health_check_all()

# List available
connectors = registry.list_connectors()
```

## Performance Targets

- Native connector operation: < 500ms
- Helmsman query: < 2s
- Docker operation: < 5s
- Slack post: < 1s
- Home Assistant device control: < 2s
- Claude conversation fallback: < 5s (Haiku) / < 10s (Sonnet)

## Error Handling

Each connector includes:
- Timeout protection (5-30s depending on operation)
- Graceful fallback to conversation
- Detailed error logging
- Health check before operations

If a connector fails:
1. Operation returns error in `ConnectorResult`
2. Quinn logs the error
3. User gets spoken error message
4. Falls back to Claude conversation if applicable

## Adding New Connectors

1. Create `connectors/myservice.py`
2. Inherit from `ConnectorBase`
3. Implement `health_check()` and `execute()`
4. Add to `registry.py` initialization
5. Add pattern matching in `quinn-brain-svc.py`

## Troubleshooting

### Helmsman connector fails
```bash
curl http://127.0.0.1:5682/health
```
Verify helmsman.db REST service is running.

### Docker connector fails
```bash
docker ps
```
Verify Docker daemon is running.

### Slack connector fails
```bash
which slack-post-filtered
```
Verify command is installed. Test with:
```bash
slack-post-filtered "#test" "Test message" --priority=high
```

### Home Assistant connector fails
- Verify HA is accessible: `curl http://192.168.68.80:8123/api/`
- Verify token is set: `cat /Volumes/data/secrets/home_assistant_token`
- Check HA logs for connection errors

## Performance Notes

- Helmsman: REST calls, ~100ms each
- Docker: CLI calls, ~500ms each  
- Slack: CLI wrapper, ~200ms each
- Home Assistant: REST calls, ~500ms each

Quinn pattern matching happens before any connector call, so simple operations are detected in < 10ms.

## Security

- NO API keys hardcoded in code
- Secrets in `/Volumes/data/secrets/`
- Docker uses local CLI (no network)
- Helmsman is internal lab service
- Slack uses subprocess (no direct API)
- All passwords/tokens loaded from secrets at runtime

## Next Steps

Phase 2 enhancements:
1. Add GitHub connector (PR status, issue creation)
2. Add NotebookLM connector (knowledge base queries)
3. Add calendar/reminder connectors (iOS native)
4. Add content pipeline connector (Hone n8n workflows)
5. Improve pattern matching with NLP (Connor classification)

Phase 3 enhancements:
1. Multi-step task chaining
2. Context-aware device targeting
3. Error recovery and retry logic
4. Usage metrics and analytics
5. User preference learning
