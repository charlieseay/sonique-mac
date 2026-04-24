"""
tts_server.py — macOS sidecar TTS server.

Same HTTP contract as services/caal-tts/server.py in the cael repo, but uses
the Piper standalone binary via subprocess instead of the `piper-tts` Python
package. The Python package depends on `piper-phonemize`, which has no
macOS arm64 wheels for any Python version. Shipping the binary keeps the
sidecar self-contained without that wheel pain.

Endpoints:
  GET  /health
  POST /v1/audio/speech       # OpenAI-compatible
  POST /synthesize            # minimal form used by caal-agent's synthesizer.py

Env:
  PIPER_BIN      path to the piper binary (default: $ROOT/piper/piper)
  TTS_VOICE_DIR  directory holding <voice>.onnx + <voice>.onnx.json files
  TTS_VOICE      default voice id (e.g. en_US-ryan-high)
  HOST, PORT     bind address
"""
import io
import os
import subprocess
import wave
from contextlib import asynccontextmanager
from pathlib import Path
from typing import AsyncIterator

from fastapi import FastAPI, HTTPException
from fastapi.responses import Response
from pydantic import BaseModel

PIPER_BIN = Path(os.environ.get("PIPER_BIN", "/opt/sonique/sidecar/piper/piper"))
VOICE_DIR = Path(os.environ.get("TTS_VOICE_DIR", "/opt/sonique/sidecar/models/piper"))
DEFAULT_VOICE = os.environ.get("TTS_VOICE", "en_US-ryan-high")


def _resolve_voice(name: str) -> Path:
    """
    Accepts either a bare voice id (`en_US-ryan-high`) or a HuggingFace-style
    path (`speaches-ai/piper-en_US-ryan-high`). Returns the path to the .onnx
    file; the matching .onnx.json must sit next to it.
    """
    candidate = name.split("/")[-1]  # drop any leading repo/path
    candidate = candidate.removeprefix("piper-")
    onnx = VOICE_DIR / f"{candidate}.onnx"
    if not onnx.exists():
        raise FileNotFoundError(f"{onnx} missing (check TTS_VOICE_DIR and bundled voices)")
    if not onnx.with_suffix(".onnx.json").exists():
        raise FileNotFoundError(f"{onnx.with_suffix('.onnx.json')} missing next to the model")
    return onnx


def _synthesize_wav(text: str, voice: str) -> bytes:
    """
    Run the Piper binary and capture its WAV output. Piper writes raw WAV to
    stdout when invoked without `--output_file`.
    """
    onnx_path = _resolve_voice(voice)
    proc = subprocess.run(
        [
            str(PIPER_BIN),
            "--model", str(onnx_path),
            "--output_raw",  # PCM s16le on stdout; we wrap it in a WAV header
        ],
        input=text.encode("utf-8"),
        capture_output=True,
        check=False,
    )
    if proc.returncode != 0:
        raise RuntimeError(f"piper exit {proc.returncode}: {proc.stderr.decode(errors='replace')[:200]}")

    # Piper emits 22050 Hz mono s16le raw PCM with --output_raw. Wrap in WAV.
    pcm = proc.stdout
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(22050)
        w.writeframes(pcm)
    return buf.getvalue()


@asynccontextmanager
async def lifespan(_app: FastAPI) -> AsyncIterator[None]:
    # Warm-resolve the default voice so startup fails loudly if the bundle is incomplete
    _resolve_voice(DEFAULT_VOICE)
    yield


app = FastAPI(title="sonique-tts-sidecar", version="0.1.0", lifespan=lifespan)


@app.get("/health")
def health() -> dict:
    return {
        "ok": True,
        "backend": "piper-binary",
        "piper_bin": str(PIPER_BIN),
        "voice_dir": str(VOICE_DIR),
        "default_voice": DEFAULT_VOICE,
    }


class OpenAISpeechRequest(BaseModel):
    input: str
    model: str | None = None
    voice: str | None = None
    response_format: str = "wav"
    speed: float = 1.0


@app.post("/v1/audio/speech")
def openai_speech(req: OpenAISpeechRequest) -> Response:
    if not req.input.strip():
        raise HTTPException(status_code=400, detail="input is empty")
    if req.response_format != "wav":
        raise HTTPException(
            status_code=400,
            detail=f"only response_format=wav supported, got {req.response_format!r}",
        )
    voice = req.voice or req.model or DEFAULT_VOICE
    try:
        wav = _synthesize_wav(req.input, voice)
    except FileNotFoundError as exc:
        raise HTTPException(status_code=400, detail=f"voice unavailable: {voice} ({exc})")
    except Exception as exc:
        raise HTTPException(status_code=500, detail=str(exc))
    return Response(content=wav, media_type="audio/wav")


class SynthesizeRequest(BaseModel):
    text: str
    voice: str | None = None


@app.post("/synthesize")
def synthesize(req: SynthesizeRequest) -> Response:
    if not req.text.strip():
        raise HTTPException(status_code=400, detail="text is empty")
    voice = req.voice or DEFAULT_VOICE
    try:
        wav = _synthesize_wav(req.text, voice)
    except FileNotFoundError as exc:
        raise HTTPException(status_code=400, detail=f"voice unavailable: {voice} ({exc})")
    return Response(content=wav, media_type="audio/wav")
