#!/usr/bin/env python3
"""
Minimal Kokoro TTS server for SoniqueBar.
Reads JSON from stdin, writes audio bytes to stdout.

Protocol:
- Input: JSON lines on stdin, e.g.: {"text":"Hello","voice":"af_bella"}
- Output: 4-byte length (big-endian) + audio bytes (numpy float32 array)
"""
import sys
import json
import struct
import numpy as np
import logging
from pathlib import Path

# Configure logging to stderr (stdout is reserved for audio data)
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    stream=sys.stderr
)
logger = logging.getLogger(__name__)


class KokoroTTSEngine:
    """Minimal Kokoro TTS wrapper for SoniqueBar."""

    def __init__(self):
        self.model = None
        self.pipelines = {}
        self._loaded = False

    def load_model(self):
        """Load Kokoro model on first use."""
        if self._loaded:
            return

        try:
            from kokoro import KModel
            logger.info("Loading Kokoro-82M model...")

            # Load model to CPU (MLX variant will be added in Phase 2)
            self.model = KModel(repo_id="hexgrad/Kokoro-82M").eval()
            self._loaded = True

            logger.info("Kokoro-82M loaded successfully")
        except Exception as e:
            logger.error(f"Failed to load Kokoro model: {e}")
            raise

    def get_pipeline(self, lang_code="a"):
        """Get or create pipeline for language."""
        if lang_code not in self.pipelines:
            from kokoro import KPipeline
            self.pipelines[lang_code] = KPipeline(
                lang_code=lang_code,
                repo_id="hexgrad/Kokoro-82M",
                model=self.model
            )
        return self.pipelines[lang_code]

    def synthesize(self, text: str, voice: str = "af_bella") -> np.ndarray:
        """
        Synthesize text to audio.

        Returns:
            numpy array of float32 audio samples (24kHz)
        """
        self.load_model()

        pipeline = self.get_pipeline("a")  # English

        # Generate audio chunks
        audio_chunks = []
        for result in pipeline(text, voice=voice, speed=1.0):
            if result.audio is not None:
                chunk = result.audio
                # Convert torch tensor to numpy if needed
                if hasattr(chunk, 'detach'):
                    chunk = chunk.detach().cpu().numpy()
                audio_chunks.append(chunk.squeeze())

        if not audio_chunks:
            # Return silence if generation failed
            logger.warning("No audio generated, returning silence")
            return np.zeros(24000, dtype=np.float32)  # 1 second of silence

        audio = np.concatenate(audio_chunks)
        return audio.astype(np.float32)


def main():
    """Main loop: read JSON from stdin, write audio to stdout."""
    logger.info("Sonique TTS Engine starting...")

    try:
        engine = KokoroTTSEngine()
        logger.info("Engine initialized, ready for requests")

        # Signal ready by writing a ready marker to stderr
        sys.stderr.write("READY\n")
        sys.stderr.flush()

        # Process requests from stdin
        for line in sys.stdin:
            try:
                req = json.loads(line.strip())
                text = req.get("text", "")
                voice = req.get("voice", "af_bella")

                if not text:
                    logger.warning("Empty text received, skipping")
                    continue

                logger.info(f"Synthesizing: '{text[:50]}...' with voice={voice}")

                # Generate audio
                audio = engine.synthesize(text, voice)

                # Convert to bytes
                audio_bytes = audio.tobytes()

                # Write length prefix (4 bytes, big-endian)
                length = len(audio_bytes)
                sys.stdout.buffer.write(struct.pack('>I', length))

                # Write audio data
                sys.stdout.buffer.write(audio_bytes)
                sys.stdout.buffer.flush()

                logger.info(f"Sent {length} bytes")

            except json.JSONDecodeError as e:
                logger.error(f"Invalid JSON: {e}")
            except Exception as e:
                logger.error(f"Error processing request: {e}", exc_info=True)

    except KeyboardInterrupt:
        logger.info("Shutting down...")
    except Exception as e:
        logger.error(f"Fatal error: {e}", exc_info=True)
        sys.exit(1)


if __name__ == "__main__":
    main()
