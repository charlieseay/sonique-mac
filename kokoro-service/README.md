# Kokoro TTS Service for SoniqueBar

FastAPI service that provides Kokoro TTS synthesis via HTTP, bridging SoniqueBar (Swift) to Kokoro.

## Quick Start

### Option 1: Docker (Recommended)

```bash
docker run -d --name kokoro-service -p 5903:8000 remsky/kokoro-fastapi:latest
```

### Option 2: Python Service (Local)

```bash
cd ~/Projects/sonique-mac/kokoro-service
source venv/bin/activate
python main.py
```

**Note:** Python service requires correct CoreML models downloaded to:
`~/Library/Application Support/SoniqueBar/Kokoro/`

## Endpoints

- `GET /health` - Health check
- `POST /synthesize` - Synthesize speech
  - Body: `{"text": "Hello world", "voice": "af_bella"}`
  - Returns: WAV audio file
- `GET /voices` - List available voices

## Available Voices

- `af_bella` - Best match to Jessica (ElevenLabs) - Grade A-
- `af_heart` - #1 ranked on TTS Arena - Grade A

## Integration

SoniqueBar's KokoroProvider calls `http://localhost:5903/synthesize` automatically when `tts_provider` is set to `kokoro` in config.json.

## Performance

- **Target:** <500ms latency (5x faster than ElevenLabs)
- **Quality:** 94-95% of ElevenLabs
- **Cost:** $0 (vs $5-15/month)
- **Privacy:** 100% local (no data leaves machine)
