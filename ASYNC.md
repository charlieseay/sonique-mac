# Quinn Async Task Handling

## Overview

Quinn handles long-running operations asynchronously to provide immediate feedback and prevent silent waits.

## How It Works

1. **Immediate Acknowledgment**
   - Quinn detects long-running operations (NotebookLM queries, research, analysis)
   - Returns instant acknowledgment: "Let me check the knowledge base. This might take a minute."
   - User knows something is happening - no silent wait

2. **Background Execution**
   - Task runs in separate thread
   - User can continue talking to Quinn
   - Status tracked in memory

3. **Polling & Completion**
   - SoniqueBar polls `/tasks/{id}` every 2s
   - Max 60s timeout (30 attempts)
   - Speaks result when complete

## Operations That Go Async

### Currently Async
- **NotebookLM queries** - 30-60s Google service latency
  - `"Query team-kb: helmsman"`
  - `"Query projects notebook: what's the status?"`

### Future Async (not yet implemented)
- Complex research ("research X", "analyze Y")
- Multi-step tasks ("solve X then Y")
- Long computations

## API Endpoints

### POST /respond
Normal endpoint - returns sync or async response:

**Sync response:**
```json
{
  "response": "You have 20 running containers.",
  "connector": "docker",
  "status": "ok"
}
```

**Async response:**
```json
{
  "response": "Let me check the knowledge base. This might take a minute.",
  "task_id": "418d9137",
  "status": "async",
  "message": "I'm working on that in the background."
}
```

### GET /tasks/active
List all active (pending/running) tasks:

```json
{
  "tasks": [
    {
      "id": "418d9137",
      "name": "notebooklm_query",
      "status": "running",
      "created": "2026-07-15T09:37:36.535544",
      "started": "2026-07-15T09:37:36.536595"
    }
  ]
}
```

### GET /tasks/{task_id}
Get specific task status:

```json
{
  "id": "418d9137",
  "name": "notebooklm_query",
  "status": "completed",
  "created": "2026-07-15T09:37:36.535544",
  "started": "2026-07-15T09:37:36.536595",
  "completed": "2026-07-15T09:38:36.546274",
  "result": "Helmsman is a task orchestration service...",
  "error": null
}
```

**Status values:**
- `pending` - queued, not started
- `running` - in progress
- `completed` - finished successfully
- `failed` - error occurred

## Task Lifecycle

```
User: "Query team-kb: helmsman"
  ↓
Quinn Brain: Detects long-running operation
  ↓
Returns: {status: "async", task_id: "abc123", response: "Let me check..."}
  ↓
User hears: "Let me check the knowledge base. This might take a minute."
  ↓
Background thread: Execute NotebookLM query (30-60s)
  ↓
SoniqueBar polls: GET /tasks/abc123 every 2s
  ↓
Status changes: pending → running → completed
  ↓
Quinn speaks result when complete
```

## Configuration

### Timeouts

| Operation | Timeout | Reason |
|-----------|---------|--------|
| NotebookLM query | 60s | Google service latency |
| Polling interval | 2s | Balance responsiveness vs load |
| Max poll attempts | 30 | 60s total (30 × 2s) |

### Acknowledgment Messages

Defined in `async_handler.py`:

```python
acknowledgments = {
    "notebooklm": "I'm checking the knowledge base. This might take a minute.",
    "research": "I'm researching that. Give me a moment.",
    "analysis": "I'm analyzing that. One moment.",
    "complex": "That's a complex question. Let me work through it.",
    "default": "I'm working on that. Just a moment."
}
```

## Adding New Async Operations

1. **Detect operation in `quinn-brain-svc.py`:**
   ```python
   if "research" in lower:
       def _do_research():
           # Long-running work
           return result

       return task_handler.create_task(
           name="research_task",
           work_func=_do_research,
           acknowledgment="I'm researching that. Give me a moment."
       )
   ```

2. **Update `is_long_running_operation()` in `async_handler.py`:**
   ```python
   if any(word in lower for word in ["research", "analyze", ...]):
       return True
   ```

3. **Add acknowledgment message** (optional):
   ```python
   acknowledgments = {
       "research": "Custom acknowledgment message",
       ...
   }
   ```

## Testing

```bash
# Start Quinn
cd ~/Projects/sonique-mac
python3 quinn-brain-svc.py

# Test sync operation (fast)
curl -X POST http://127.0.0.1:5912/respond \
  -H "Content-Type: application/json" \
  -d '{"text":"List running containers"}'

# Test async operation (slow)
curl -X POST http://127.0.0.1:5912/respond \
  -H "Content-Type: application/json" \
  -d '{"text":"Query team-kb: helmsman"}'
# Returns task_id immediately

# Check status
curl http://127.0.0.1:5912/tasks/{task_id}

# List active tasks
curl http://127.0.0.1:5912/tasks/active
```

## User Experience

**Before (sync):**
- User: "Query team-kb: helmsman"
- *[60 seconds of silence]*
- Quinn: "Helmsman is a task orchestration service..."
- **Problem:** User thinks Quinn is broken

**After (async):**
- User: "Query team-kb: helmsman"
- Quinn: "Let me check the knowledge base. This might take a minute."
- *[User can ask other questions or wait]*
- Quinn: "Helmsman is a task orchestration service..."
- **Result:** User knows Quinn is working, no confusion

## Notes

- Tasks are stored in memory only (not persisted)
- Old completed tasks cleaned up after 1 hour
- Max 100 tasks kept in memory
- Thread-safe via Python threading
- No database required
