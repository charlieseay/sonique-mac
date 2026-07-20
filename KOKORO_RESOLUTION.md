# Kokoro TTS Integration - Resolution Paths

## Problem
KokoroCLI built with `swift build` fails at runtime:
```
MLX error: Failed to load the default metallib. library not found
```

**Root Cause:** SwiftPM (command line) cannot build Metal shaders. MLX-Swift requires Xcode to compile the Metal shader library (.metallib).

---

## Solution Options

### Option 1: Build with Xcode (RECOMMENDED)
**Status:** Currently testing

Build KokoroCLI using xcodebuild instead of swift build:

```bash
cd ~/Projects/sonique-mac/Kokoro
xcodebuild -scheme KokoroCLI -destination 'platform=macOS' -configuration Release build
```

This compiles the Metal shaders and embeds them in the binary.

**Pros:**
- Native Swift, no external dependencies
- Uses Apple Neural Engine via MLX
- Fast synthesis (3-11× realtime)

**Cons:**
- Requires Xcode build (can't use swift build)
- Larger binary (~50MB vs ~5MB)

---

### Option 2: Use CoreML Backend
**Status:** Not yet implemented

Download CoreML weights instead of MLX:

```bash
# Download segmented CoreML models from HuggingFace
curl -L https://huggingface.co/mweinbach/Kokoro-82M-Swift/resolve/main/CoreML_ANE/segmented/albert.mlpackage.zip -o albert.mlpackage.zip
# ... download other 3 segments
```

Then modify KokoroTTS.swift to use CoreML backend:

```swift
let model = try SegmentedCoreMLModel(
    segmentedDir: URL(fileURLWithPath: "CoreML_ANE/segmented"),
    configURL: configURL
)
let pipeline = KPipeline(coreMLSegmentedModel: model, voices: voices)
```

**Pros:**
- No Metal shader compilation needed
- Optimized for Apple Neural Engine
- Lower power consumption

**Cons:**
- Requires downloading different weights (~400MB total)
- More complex model loading (4 segments)

---

### Option 3: Python VoiceBox Service (FALLBACK)
**Status:** Previously tested, working

Run the original VoiceBox Python backend as a local service:

```bash
cd ~/Projects/voicebox  # or wherever VoiceBox is installed
python -m voicebox.server --host 127.0.0.1 --port 8891
```

SoniqueBar calls HTTP endpoint instead of CLI subprocess.

**Pros:**
- Already proven to work
- No Swift/Metal issues
- Easy to debug

**Cons:**
- Requires Python runtime
- Not App Store compatible (Python dependency)
- Extra process to manage

---

## Current Status

- ✅ Weights downloaded (MLX format)
- ✅ KokoroTTS.swift implemented (subprocess approach)
- ✅ /synthesize/kokoro endpoint added
- ⏳ xcodebuild in progress (compiling Metal shaders)
- ⏸️ CoreML option available if xcodebuild fails
- ⏸️ Python fallback available as last resort

---

## Recommendation

**Try in order:**
1. xcodebuild (currently running)
2. CoreML backend if xcodebuild output is too large
3. Python service only if both native options fail

The xcodebuild approach is best for App Store distribution and native performance.
