#!/usr/bin/env python3
"""
Test script for Sonique TTS Engine.
Validates the stdio protocol before building the binary.
"""
import subprocess
import json
import struct
import numpy as np
import sys
from pathlib import Path


def test_stdio_protocol():
    """Test the stdin/stdout protocol."""
    print("🧪 Testing TTS Engine stdio protocol...\n")

    # Start the engine
    print("Starting engine subprocess...")
    proc = subprocess.Popen(
        [sys.executable, "main.py"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=False  # Binary mode for stdout
    )

    try:
        # Wait for READY signal on stderr
        import select
        import time

        ready = False
        start_time = time.time()
        while time.time() - start_time < 30:  # 30 second timeout
            # Check if stderr has data
            if select.select([proc.stderr], [], [], 0.1)[0]:
                line = proc.stderr.readline().decode('utf-8')
                print(f"[stderr] {line.rstrip()}")
                if "READY" in line:
                    ready = True
                    break

        if not ready:
            print("❌ Engine did not signal READY within 30 seconds")
            return False

        print("✅ Engine ready\n")

        # Send test request
        test_text = "Hello from Sonique!"
        request = {"text": test_text, "voice": "af_bella"}
        request_json = json.dumps(request) + "\n"

        print(f"Sending request: {request}")
        proc.stdin.write(request_json.encode('utf-8'))
        proc.stdin.flush()

        # Read response: 4-byte length + audio data
        print("Reading response...")
        length_bytes = proc.stdout.read(4)
        if len(length_bytes) != 4:
            print(f"❌ Failed to read length prefix (got {len(length_bytes)} bytes)")
            return False

        length = struct.unpack('>I', length_bytes)[0]
        print(f"Response length: {length} bytes ({length / 1024:.1f} KB)")

        # Read audio data
        audio_bytes = proc.stdout.read(length)
        if len(audio_bytes) != length:
            print(f"❌ Failed to read audio data (expected {length}, got {len(audio_bytes)})")
            return False

        # Convert to numpy array
        audio = np.frombuffer(audio_bytes, dtype=np.float32)
        duration = len(audio) / 24000  # 24kHz sample rate
        print(f"✅ Received {len(audio)} samples ({duration:.2f} seconds)")

        # Validate audio
        if len(audio) == 0:
            print("❌ Audio is empty")
            return False

        if np.all(audio == 0):
            print("⚠️  Warning: Audio is all zeros (silence)")
        else:
            print(f"✅ Audio contains non-zero samples (min: {audio.min():.3f}, max: {audio.max():.3f})")

        # Optional: Save to file
        output_file = Path("test_output.wav")
        try:
            import soundfile as sf
            sf.write(str(output_file), audio, 24000)
            print(f"✅ Audio saved to {output_file}")
        except ImportError:
            print("⚠️  soundfile not available, skipping WAV export")

        return True

    except Exception as e:
        print(f"❌ Error: {e}")
        import traceback
        traceback.print_exc()
        return False

    finally:
        # Cleanup
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()


if __name__ == "__main__":
    success = test_stdio_protocol()
    print("\n" + "="*50)
    if success:
        print("✅ All tests passed!")
        sys.exit(0)
    else:
        print("❌ Tests failed")
        sys.exit(1)
