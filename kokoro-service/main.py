#!/usr/bin/env python3
"""
Kokoro TTS FastAPI Service
Provides local TTS synthesis for SoniqueBar using pre-downloaded CoreML models

This service bridges Swift/SoniqueBar to Python/Kokoro via REST API.
Models are already downloaded at: ~/Library/Application Support/SoniqueBar/Kokoro/
"""

from fastapi import FastAPI, HTTPException
from fastapi.responses import FileResponse
from pydantic import BaseModel
import coremltools as ct
import numpy as np
import tempfile
import os
import wave
from pathlib import Path
import time

app = FastAPI(title="Kokoro TTS Service", version="1.0.0")

# Model cache
models = {}
voices_cache = {}

class SynthesizeRequest(BaseModel):
    text: str
    voice: str = "af_bella"

def get_model_dir():
    """Get Kokoro model directory"""
    model_dir = Path.home() / "Library/Application Support/SoniqueBar/Kokoro"
    if not model_dir.exists():
        raise RuntimeError(f"Kokoro models not found at {model_dir}")
    return model_dir

def load_voice(voice_id: str) -> np.ndarray:
    """Load voice embedding from .npy file"""
    if voice_id not in voices_cache:
        model_dir = get_model_dir()
        voice_path = model_dir / "voices" / f"{voice_id}.npy"

        if not voice_path.exists():
            raise FileNotFoundError(f"Voice {voice_id} not found at {voice_path}")

        voices_cache[voice_id] = np.load(voice_path)

    return voices_cache[voice_id]

def load_models():
    """Load CoreML segmented models (lazy loading, cached)"""
    if models:
        return models

    model_dir = get_model_dir()
    segmented_dir = model_dir / "CoreML_ANE/segmented"

    print(f"Loading models from {segmented_dir}...")

    # Load all 4 segmented models
    models["albert"] = ct.models.MLModel(str(segmented_dir / "albert.mlpackage"))
    models["text_encoder"] = ct.models.MLModel(str(segmented_dir / "text_encoder.mlpackage"))
    models["prosody"] = ct.models.MLModel(str(segmented_dir / "prosody.mlpackage"))
    models["decoder"] = ct.models.MLModel(str(segmented_dir / "decoder.mlpackage"))

    print("Models loaded successfully!")
    return models

def synthesize_audio(text: str, voice_embedding: np.ndarray) -> np.ndarray:
    """
    Run full Kokoro pipeline:
    text → ALBERT → text_encoder → prosody → decoder → audio
    """
    mdls = load_models()

    # Step 1: ALBERT encoding
    albert_out = mdls["albert"].predict({"text": text})

    # Step 2: Text encoding
    text_enc_out = mdls["text_encoder"].predict(albert_out)

    # Step 3: Prosody prediction with voice embedding
    prosody_input = {**text_enc_out, "voice_embedding": voice_embedding}
    prosody_out = mdls["prosody"].predict(prosody_input)

    # Step 4: Decode to audio
    decoder_input = {**text_enc_out, **prosody_out}
    audio_out = mdls["decoder"].predict(decoder_input)

    # Extract audio array (24kHz sample rate)
    audio = audio_out["audio"]  # Shape: (samples,)
    return audio

def save_wav(audio: np.ndarray, path: str, sample_rate: int = 24000):
    """Save audio as WAV file"""
    # Convert float32 to int16
    audio_int16 = (audio * 32767).astype(np.int16)

    with wave.open(path, 'wb') as wav_file:
        wav_file.setnchannels(1)  # Mono
        wav_file.setsampwidth(2)  # 16-bit
        wav_file.setframerate(sample_rate)
        wav_file.writeframes(audio_int16.tobytes())

@app.get("/health")
async def health_check():
    """Health check endpoint"""
    try:
        model_dir = get_model_dir()
        return {
            "status": "healthy",
            "model": "kokoro-82m-coreml-ane",
            "models_path": str(model_dir),
            "models_loaded": len(models) > 0
        }
    except Exception as e:
        return {"status": "unhealthy", "error": str(e)}

@app.post("/synthesize")
async def synthesize(request: SynthesizeRequest):
    """Synthesize speech from text"""
    try:
        start_time = time.time()

        # Load voice embedding
        voice_emb = load_voice(request.voice)

        # Synthesize
        audio = synthesize_audio(request.text, voice_emb)

        synthesis_time = int((time.time() - start_time) * 1000)
        print(f"[Kokoro] Synthesis completed in {synthesis_time}ms")

        # Write to temp file
        with tempfile.NamedTemporaryFile(delete=False, suffix=".wav") as f:
            save_wav(audio, f.name)
            temp_path = f.name

        # Return file
        return FileResponse(
            temp_path,
            media_type="audio/wav",
            filename="synthesis.wav",
            headers={"X-Synthesis-Time-Ms": str(synthesis_time)},
            background=lambda: os.unlink(temp_path)  # Cleanup after sending
        )

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
