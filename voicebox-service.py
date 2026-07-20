#!/usr/bin/env python3
"""
VoiceBox TTS Service for Sonique
Lightweight FastAPI service that wraps VoiceBox backend
Endpoint: POST /synthesize {text} -> PCM audio (24kHz mono 16-bit)
Port: 8891
"""

from fastapi import FastAPI, HTTPException
from fastapi.responses import Response
from pydantic import BaseModel
import httpx
import asyncio
import logging

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

app = FastAPI(title="VoiceBox TTS Service")

# VoiceBox backend configuration
VOICEBOX_HOST = "http://localhost:17493"
KOKORO_JESSICA_PROFILE_ID = None  # Will be set on startup

class SynthesizeRequest(BaseModel):
    text: str
    voice: str = "jessica"  # Default to Jessica


@app.on_event("startup")
async def startup():
    """Initialize VoiceBox connection and create/find Jessica profile"""
    global KOKORO_JESSICA_PROFILE_ID

    # Check if VoiceBox is running
    try:
        async with httpx.AsyncClient() as client:
            response = await client.get(f"{VOICEBOX_HOST}/health", timeout=5.0)
            if response.status_code != 200:
                logger.error("VoiceBox backend not healthy")
                return
            logger.info("✓ VoiceBox backend is healthy")
    except Exception as e:
        logger.error(f"Cannot connect to VoiceBox backend: {e}")
        logger.error("Start VoiceBox with: cd ~/Projects/voicebox/backend && source venv/bin/activate && python -m backend.main")
        return

    # Find or create Kokoro Jessica profile
    try:
        async with httpx.AsyncClient() as client:
            # List all profiles
            response = await client.get(f"{VOICEBOX_HOST}/profiles")
            profiles = response.json()

            # Look for existing Kokoro Jessica profile
            for profile in profiles:
                if profile.get("engine") == "kokoro" and profile.get("voice_name") == "af_jessica":
                    KOKORO_JESSICA_PROFILE_ID = profile["id"]
                    logger.info(f"✓ Found existing Kokoro Jessica profile: {KOKORO_JESSICA_PROFILE_ID}")
                    return

            # Create new Kokoro Jessica profile
            create_data = {
                "name": "Jessica (Kokoro)",
                "engine": "kokoro",
                "voice_name": "af_jessica",  # Kokoro voice ID for American Female Jessica
                "language": "en",
                "description": "Kokoro Jessica voice for Sonique"
            }
            response = await client.post(f"{VOICEBOX_HOST}/profiles", json=create_data)
            profile = response.json()
            KOKORO_JESSICA_PROFILE_ID = profile["id"]
            logger.info(f"✓ Created Kokoro Jessica profile: {KOKORO_JESSICA_PROFILE_ID}")

    except Exception as e:
        logger.error(f"Failed to setup Kokoro Jessica profile: {e}")


@app.get("/health")
async def health():
    """Health check endpoint"""
    voicebox_ok = KOKORO_JESSICA_PROFILE_ID is not None
    return {
        "status": "ok" if voicebox_ok else "degraded",
        "voicebox_connected": voicebox_ok,
        "profile_id": KOKORO_JESSICA_PROFILE_ID
    }


@app.post("/synthesize")
async def synthesize(request: SynthesizeRequest):
    """
    Generate speech from text using Kokoro Jessica voice
    Returns: audio/pcm (24kHz mono 16-bit little-endian)
    """
    if not KOKORO_JESSICA_PROFILE_ID:
        raise HTTPException(status_code=503, detail="VoiceBox not initialized")

    if not request.text or len(request.text.strip()) == 0:
        raise HTTPException(status_code=400, detail="Empty text")

    logger.info(f"[TTS] Generating: {request.text[:50]}...")

    try:
        async with httpx.AsyncClient(timeout=30.0) as client:
            # Call VoiceBox /generate endpoint
            gen_request = {
                "profile_id": KOKORO_JESSICA_PROFILE_ID,
                "text": request.text,
                "engine": "kokoro",
                "normalize": True
            }

            response = await client.post(
                f"{VOICEBOX_HOST}/generate",
                json=gen_request
            )

            if response.status_code != 200:
                logger.error(f"VoiceBox generate failed: {response.status_code} {response.text}")
                raise HTTPException(status_code=500, detail="TTS generation failed")

            result = response.json()
            audio_path = result.get("audio_path")

            if not audio_path:
                raise HTTPException(status_code=500, detail="No audio generated")

            # Fetch the generated audio file
            audio_response = await client.get(f"{VOICEBOX_HOST}{audio_path}")
            if audio_response.status_code != 200:
                raise HTTPException(status_code=500, detail="Failed to fetch audio")

            audio_data = audio_response.content

            # VoiceBox returns WAV, we need to convert to raw PCM
            # WAV has 44-byte header, skip it to get raw PCM
            if audio_data[:4] == b'RIFF':
                # Find 'data' chunk
                data_pos = audio_data.find(b'data')
                if data_pos > 0:
                    # Skip 'data' marker (4 bytes) + size (4 bytes)
                    pcm_data = audio_data[data_pos + 8:]
                else:
                    # Fallback: skip standard 44-byte WAV header
                    pcm_data = audio_data[44:]
            else:
                # Already raw PCM
                pcm_data = audio_data

            logger.info(f"[TTS] Generated {len(pcm_data)} bytes PCM")

            return Response(
                content=pcm_data,
                media_type="audio/pcm",
                headers={
                    "X-Sample-Rate": "24000",
                    "X-Channels": "1",
                    "X-Bit-Depth": "16"
                }
            )

    except httpx.TimeoutException:
        logger.error("VoiceBox request timed out")
        raise HTTPException(status_code=504, detail="TTS request timed out")
    except Exception as e:
        logger.error(f"TTS error: {e}")
        raise HTTPException(status_code=500, detail=str(e))


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8891, log_level="info")
