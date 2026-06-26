#!/usr/bin/env python3
"""
Kokoro TTS FastAPI Service
Provides local TTS synthesis for SoniqueBar using KokoroCLI

This service bridges Swift/SoniqueBar to the kokoro-swift CLI via REST API.
Simpler than CoreML direct integration - just calls the pre-built binary.
"""

from fastapi import FastAPI, HTTPException
from fastapi.responses import FileResponse
from pydantic import BaseModel
import subprocess
import tempfile
import os
from pathlib import Path
import time

app = FastAPI(title="Kokoro TTS Service", version="1.0.0")

# Path to KokoroCLI binary
KOKORO_CLI = Path.home() / "Projects/sonique-mac/Packages/kokoro-swift/.build/debug/KokoroCLI"
WEIGHTS_DIR = Path.home() / "Library/Application Support/SoniqueBar/Kokoro"

# Model cache
models = {}
voices_cache = {}

class SynthesizeRequest(BaseModel):
    text: str
    voice: str = "af_bella"

def check_kokoro_cli():
    """Check if KokoroCLI is available"""
    if not KOKORO_CLI.exists():
        raise RuntimeError(f"KokoroCLI not found at {KOKORO_CLI}")
    return True

@app.get("/health")
async def health_check():
    """Health check endpoint"""
    try:
        check_kokoro_cli()
        return {
            "status": "healthy",
            "model": "kokoro-82m-coreml-ane",
            "cli_path": str(KOKORO_CLI),
            "weights_dir": str(WEIGHTS_DIR)
        }
    except Exception as e:
        return {"status": "unhealthy", "error": str(e)}

@app.post("/synthesize")
async def synthesize(request: SynthesizeRequest):
    """Synthesize speech from text using KokoroCLI"""
    try:
        start_time = time.time()

        # Create temp output file
        with tempfile.NamedTemporaryFile(delete=False, suffix=".wav") as f:
            output_path = f.name

        # Call KokoroCLI
        cmd = [
            str(KOKORO_CLI),
            "--text", request.text,
            "--voice", request.voice,
            "--output", output_path,
            "--backend", "coreml-ane-segmented",
            "--weights-dir", str(WEIGHTS_DIR),
            "--auto-download"  # Auto-download missing voices
        ]

        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=30
        )

        if result.returncode != 0:
            error_msg = result.stderr or result.stdout or "Unknown error"
            raise RuntimeError(f"KokoroCLI failed: {error_msg}")

        synthesis_time = int((time.time() - start_time) * 1000)
        print(f"[Kokoro] Synthesis completed in {synthesis_time}ms")

        # Return file
        return FileResponse(
            output_path,
            media_type="audio/wav",
            filename="synthesis.wav",
            headers={"X-Synthesis-Time-Ms": str(synthesis_time)},
            background=lambda: os.unlink(output_path)  # Cleanup after sending
        )

    except subprocess.TimeoutExpired:
        raise HTTPException(status_code=504, detail="Synthesis timeout")
    except Exception as e:
        import traceback
        traceback.print_exc()
        raise HTTPException(status_code=500, detail=str(e))

@app.get("/voices")
async def list_voices():
    """List available voices"""
    return {
        "voices": [
            {"id": "af_heart", "name": "Heart ❤️", "language": "en-US", "gender": "female", "grade": "A"},
            {"id": "af_bella", "name": "Bella 🔥", "language": "en-US", "gender": "female", "grade": "A-"}
        ]
    }

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="127.0.0.1", port=5903, log_level="info")
