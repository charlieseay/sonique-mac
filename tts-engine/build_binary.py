#!/usr/bin/env python3
"""
PyInstaller build script for Sonique TTS Engine.
Minimal Kokoro-only build based on VoiceBox approach.

Usage:
    python build_binary.py
"""
import PyInstaller.__main__
import platform
import sys
from pathlib import Path


def is_apple_silicon():
    """Check if running on Apple Silicon."""
    return platform.system() == "Darwin" and platform.machine() == "arm64"


def build_server():
    """Build minimal Kokoro TTS server as standalone binary."""
    backend_dir = Path(__file__).parent

    if not is_apple_silicon():
        print("ERROR: This build requires Apple Silicon (M1/M2/M3/M4)")
        print(f"Detected: {platform.system()} {platform.machine()}")
        sys.exit(1)

    print("Building Sonique TTS Engine for Apple Silicon...")

    args = [
        "main.py",
        "--onefile",
        "--name", "sonique-tts",

        # Kokoro + dependencies
        "--hidden-import", "kokoro",
        "--collect-all", "kokoro",
        "--collect-all", "misaki",
        "--collect-all", "language_tags",
        "--collect-all", "espeakng_loader",
        "--collect-all", "en_core_web_sm",
        "--copy-metadata", "en_core_web_sm",

        # PyTorch + transformers
        "--hidden-import", "torch",
        "--hidden-import", "transformers",
        "--copy-metadata", "transformers",
        "--copy-metadata", "huggingface-hub",
        "--copy-metadata", "tokenizers",
        "--copy-metadata", "safetensors",
        "--copy-metadata", "tqdm",

        # Audio processing
        "--hidden-import", "soundfile",
        "--hidden-import", "numpy",

        # Exclude CUDA packages (Apple Silicon only)
        "--exclude-module", "nvidia",
        "--exclude-module", "nvidia.cublas",
        "--exclude-module", "nvidia.cuda_cupti",
        "--exclude-module", "nvidia.cuda_nvrtc",
        "--exclude-module", "nvidia.cuda_runtime",
        "--exclude-module", "nvidia.cudnn",
        "--exclude-module", "nvidia.cufft",
        "--exclude-module", "nvidia.curand",
        "--exclude-module", "nvidia.cusolver",
        "--exclude-module", "nvidia.cusparse",
        "--exclude-module", "nvidia.nccl",
        "--exclude-module", "nvidia.nvjitlink",
        "--exclude-module", "nvidia.nvtx",

        # Exclude unnecessary packages
        "--exclude-module", "fastapi",
        "--exclude-module", "uvicorn",
        "--exclude-module", "sqlalchemy",
        "--exclude-module", "matplotlib",
        "--exclude-module", "PIL",

        "--distpath", str(backend_dir / "dist"),
        "--workpath", str(backend_dir / "build"),
        "--noconfirm",
        "--clean",
    ]

    PyInstaller.__main__.run(args)

    binary_path = backend_dir / "dist" / "sonique-tts"
    if binary_path.exists():
        print(f"\n✅ Binary built successfully: {binary_path}")
        print(f"   Size: {binary_path.stat().st_size / 1024 / 1024:.1f} MB")

        # Make executable
        binary_path.chmod(0o755)
        print(f"   Permissions: 755 (executable)")
    else:
        print(f"\n❌ Binary not found at: {binary_path}")
        sys.exit(1)


if __name__ == "__main__":
    try:
        import PyInstaller
    except ImportError:
        print("ERROR: PyInstaller not installed")
        print("Run: pip install pyinstaller")
        sys.exit(1)

    build_server()
