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
import json
import logging
import os
import re
import subprocess
import tempfile
import wave
from base64 import b64decode
from contextlib import asynccontextmanager
from pathlib import Path
from typing import AsyncIterator, Iterator
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

from fastapi import FastAPI, HTTPException
from fastapi.responses import Response, StreamingResponse
from pydantic import BaseModel
from piper.voice import PiperVoice

logger = logging.getLogger(__name__)

PIPER_BIN = Path(os.environ.get("PIPER_BIN", "/opt/sonique/sidecar/piper/piper"))
VOICE_DIR = Path(os.environ.get("TTS_VOICE_DIR", "/opt/sonique/sidecar/models/piper"))
DEFAULT_VOICE = os.environ.get("TTS_VOICE", "en_US-ryan-high")
TTS_PROVIDER = os.environ.get("TTS_PROVIDER", "piper").strip().lower()
ORPHEUS_API_URL = os.environ.get("ORPHEUS_API_URL", "").strip()
ORPHEUS_API_KEY = os.environ.get("ORPHEUS_API_KEY", "").strip()
ORPHEUS_API_FORMAT = os.environ.get("ORPHEUS_API_FORMAT", "wav").strip().lower()
_PIPER_CACHE: dict[str, PiperVoice] = {}


def _extract_audio_bytes(data: bytes, content_type: str | None) -> bytes:
    ctype = (content_type or "").lower()
    if "audio/" in ctype:
        return data
    try:
        payload = json.loads(data.decode("utf-8"))
    except Exception as exc:
        raise RuntimeError(f"unexpected Orpheus API response type: {ctype or 'unknown'}") from exc

    # Common JSON shapes from hosted/wrapper APIs.
    for key in ("audio_base64", "audio", "wav_base64"):
        value = payload.get(key)
        if isinstance(value, str) and value:
            return b64decode(value)
    if isinstance(payload.get("data"), dict):
        inner = payload["data"]
        for key in ("audio_base64", "audio", "wav_base64"):
            value = inner.get(key)
            if isinstance(value, str) and value:
                return b64decode(value)
    raise RuntimeError("Orpheus API response did not include audio bytes")


def _resolve_voice(name: str) -> Path:
    """
    Accepts either a bare voice id (`en_US-ryan-high`) or a HuggingFace-style
    path (`speaches-ai/piper-en_US-ryan-high`). Returns the path to the .onnx
    file; the matching .onnx.json must sit next to it.
    """
    candidate = name.split("/")[-1]  # drop any leading repo/path
    candidate = candidate.removeprefix("piper-")
    onnx = VOICE_DIR / f"{candidate}.onnx"
    if not onnx.exists() and candidate.endswith("-medium"):
        # Backward-compatible fallback for existing bundles that only include
        # Ryan high while we migrate defaults to medium.
        fallback = candidate.replace("-medium", "-high")
        onnx = VOICE_DIR / f"{fallback}.onnx"
    if not onnx.exists():
        raise FileNotFoundError(f"{onnx} missing (check TTS_VOICE_DIR and bundled voices)")
    if not onnx.with_suffix(".onnx.json").exists():
        raise FileNotFoundError(f"{onnx.with_suffix('.onnx.json')} missing next to the model")
    return onnx


def _load_piper_voice(voice: str) -> PiperVoice:
    model_path = _resolve_voice(voice)
    key = str(model_path)
    cached = _PIPER_CACHE.get(key)
    if cached is not None:
        return cached
    config_path = model_path.with_suffix(".onnx.json")
    loaded = PiperVoice.load(model_path=model_path, config_path=config_path)
    _PIPER_CACHE[key] = loaded
    return loaded


def _split_sentences(text: str) -> list[str]:
    parts = [s.strip() for s in re.split(r"(?<=[.!?])\s+", text.strip()) if s.strip()]
    return parts or [text.strip()]


def _piper_pcm_stream(text: str, voice: str) -> Iterator[bytes]:
    piper_voice = _load_piper_voice(voice)
    for chunk in piper_voice.synthesize(text):
        pcm = chunk.audio_int16_bytes
        if pcm:
            yield pcm


def _synthesize_wav(text: str, voice: str) -> bytes:
    """
    Run the Piper binary and capture its WAV output. Piper writes raw WAV to
    stdout when invoked without `--output_file`.
    """
    primary_err: BaseException | None = None
    try:
        pcm = b"".join(_piper_pcm_stream(text, voice))
        buf = io.BytesIO()
        with wave.open(buf, "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(22050)
            w.writeframes(pcm)
        return buf.getvalue()
    except Exception as exc:
        primary_err = exc

    # Fallback to macOS /usr/bin/say if Piper path fails (dev / partial bundles).
    try:
        with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
            wav_path = tmp.name
        subprocess.run(
            [
                "/usr/bin/say",
                "-o",
                wav_path,
                "--file-format=WAVE",
                "--data-format=LEI16@22050",
                text,
            ],
            check=True,
            capture_output=True,
            timeout=10.0,
        )
        data = Path(wav_path).read_bytes()
        Path(wav_path).unlink(missing_ok=True)
        return data
    except Exception as e:
        logger.error("macOS say fallback failed: %s", e)
        if primary_err is not None:
            raise RuntimeError(f"TTS failed (Piper: {primary_err}, say: {e})") from e
        raise RuntimeError(f"TTS failed (say: {e})") from e


def _synthesize_orpheus_api(text: str, voice: str) -> bytes:
    if not ORPHEUS_API_URL:
        raise RuntimeError("ORPHEUS_API_URL is not set")

    body = {
        "voice": voice,
        "prompt": text,
        "input": text,
        "text": text,
        "response_format": ORPHEUS_API_FORMAT,
        "format": ORPHEUS_API_FORMAT,
        "stream": False,
    }
    req = Request(
        ORPHEUS_API_URL,
        data=json.dumps(body).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    if ORPHEUS_API_KEY:
        req.add_header("Authorization", f"Api-Key {ORPHEUS_API_KEY}")

    try:
        with urlopen(req, timeout=45) as resp:
            raw = resp.read()
            return _extract_audio_bytes(raw, resp.headers.get("Content-Type"))
    except HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")[:400]
        raise RuntimeError(f"Orpheus API HTTP {exc.code}: {detail}") from exc
    except URLError as exc:
        raise RuntimeError(f"Orpheus API unavailable: {exc.reason}") from exc


@asynccontextmanager
async def lifespan(_app: FastAPI) -> AsyncIterator[None]:
    # Warm-resolve the default voice so startup fails loudly if the bundle is incomplete
    _resolve_voice(DEFAULT_VOICE)
    # Warm one short synthesis so first real user turn has lower latency.
    try:
        _ = _synthesize_wav("Hi.", DEFAULT_VOICE)
    except Exception:
        pass
    yield


app = FastAPI(title="sonique-tts-sidecar", version="0.1.0", lifespan=lifespan)


@app.get("/health")
def health() -> dict:
    provider_ok = True
    provider_error = None
    if TTS_PROVIDER.startswith("orpheus") and not ORPHEUS_API_URL:
        provider_ok = False
        provider_error = "ORPHEUS_API_URL is required when TTS_PROVIDER=orpheus_api"
    return {
        "ok": True,
        "backend": "orpheus-api" if TTS_PROVIDER.startswith("orpheus") else "piper-binary",
        "provider": TTS_PROVIDER,
        "provider_ok": provider_ok,
        "provider_error": provider_error,
        "piper_bin": str(PIPER_BIN),
        "voice_dir": str(VOICE_DIR),
        "default_voice": DEFAULT_VOICE,
        "orpheus_api_url": ORPHEUS_API_URL if ORPHEUS_API_URL else None,
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
        if TTS_PROVIDER.startswith("orpheus"):
            try:
                wav = _synthesize_orpheus_api(req.input, voice)
            except Exception:
                wav = _synthesize_wav(req.input, voice)
        else:
            wav = _synthesize_wav(req.input, voice)
    except FileNotFoundError as exc:
        raise HTTPException(status_code=400, detail=f"voice unavailable: {voice} ({exc})")
    except Exception as exc:
        raise HTTPException(status_code=500, detail=str(exc))
    return Response(content=wav, media_type="audio/wav")


class SynthesizeRequest(BaseModel):
    text: str
    voice: str | None = None


def _pcm_sentence_stream(text: str, voice: str) -> Iterator[bytes]:
    for sentence in _split_sentences(text):
        try:
            for chunk in _piper_pcm_stream(sentence, voice):
                yield chunk
        except Exception:
            wav = _synthesize_wav(sentence, voice)
            with wave.open(io.BytesIO(wav), "rb") as w:
                yield w.readframes(w.getnframes())


@app.post("/synthesize")
def synthesize(req: SynthesizeRequest) -> Response:
    if not req.text.strip():
        raise HTTPException(status_code=400, detail="text is empty")
    voice = req.voice or DEFAULT_VOICE
    try:
        if TTS_PROVIDER.startswith("orpheus"):
            try:
                wav = _synthesize_orpheus_api(req.text, voice)
            except Exception:
                wav = _synthesize_wav(req.text, voice)
        else:
            wav = _synthesize_wav(req.text, voice)
    except FileNotFoundError as exc:
        raise HTTPException(status_code=400, detail=f"voice unavailable: {voice} ({exc})")
    except Exception as exc:
        raise HTTPException(status_code=500, detail=str(exc))
    return Response(content=wav, media_type="audio/wav")


@app.post("/synthesize_stream")
def synthesize_stream(req: SynthesizeRequest) -> StreamingResponse:
    if not req.text.strip():
        raise HTTPException(status_code=400, detail="text is empty")
    voice = req.voice or DEFAULT_VOICE
    if TTS_PROVIDER.startswith("orpheus"):
        raise HTTPException(status_code=400, detail="streaming endpoint currently supports piper only")
    try:
        _resolve_voice(voice)
    except FileNotFoundError as exc:
        raise HTTPException(status_code=400, detail=f"voice unavailable: {voice} ({exc})")
    return StreamingResponse(
        _pcm_sentence_stream(req.text, voice),
        media_type="audio/L16",
        headers={
            "X-Sample-Rate": "22050",
            "X-Channels": "1",
            "X-Sample-Width-Bytes": "2",
        },
    )
