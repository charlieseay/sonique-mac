#!/usr/bin/env bash
#
# build-sidecar.sh — produce Sidecar/bootstrap/python-runtime.tar.gz
#
# Bundles the Sonique voice pipeline — STT, TTS, and agent — as a
# self-contained sidecar. Ollama is NOT bundled; the user provides their own
# Ollama installation and model. Local LLM features require Ollama running
# at 127.0.0.1:11434 with at least one model loaded.
#
# Bundled components:
#   - Python 3.12 standalone (python-build-standalone, macOS arm64)
#   - caal-stt (faster-whisper small.en)
#   - caal-tts (Piper with en_US-ryan-high voice)
#   - caal-agent (voice_agent.py + livekit-agents)
#
# Runs idempotently. Downloads are cached in --cache-dir (default:
# ~/.cache/sonique-sidecar-build/). Final tarball ~400-500 MB.
#
# Usage:
#   scripts/build-sidecar.sh [--cache-dir PATH] [--cael-repo PATH] [--out PATH]
#
# Phase 2 packaging — Sonique. See Projects/Lab/Apps/Sonique/Packaging Plan.md.

set -euo pipefail

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

# Python 3.12 is required on macOS: piper-phonemize 1.1.x ships its macOS arm64
# wheel only for 3.12 (the Linux caal-tts container uses 3.11 because that's
# where the Linux wheels exist — wheel availability is platform-dependent).
PYTHON_VERSION="3.12.8"
PYTHON_BUILD_TAG="20241219"  # python-build-standalone release tag
PYTHON_URL="https://github.com/astral-sh/python-build-standalone/releases/download/${PYTHON_BUILD_TAG}/cpython-${PYTHON_VERSION}+${PYTHON_BUILD_TAG}-aarch64-apple-darwin-install_only.tar.gz"

# Piper TTS — ship the standalone binary (piper-tts Python package has no
# macOS arm64 wheels because piper-phonemize doesn't publish them).
PIPER_VERSION="2023.11.14-2"
PIPER_URL="https://github.com/rhasspy/piper/releases/download/${PIPER_VERSION}/piper_macos_aarch64.tar.gz"

PIPER_VOICE="en_US-ryan-high"
PIPER_VOICE_ONNX_URL="https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/ryan/high/en_US-ryan-high.onnx"
PIPER_VOICE_JSON_URL="https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/ryan/high/en_US-ryan-high.onnx.json"

WHISPER_MODEL="small.en"
WHISPER_REPO="Systran/faster-whisper-small.en"

# ---------------------------------------------------------------------------
# Arg parsing
# ---------------------------------------------------------------------------

CACHE_DIR="${HOME}/.cache/sonique-sidecar-build"
OUT="$(cd "$(dirname "$0")/.." && pwd)/Sidecar/bootstrap/python-runtime.tar.gz"
CAEL_REPO="${HOME}/Projects/cael"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cache-dir) CACHE_DIR="$2"; shift 2;;
    --out)       OUT="$2"; shift 2;;
    --cael-repo) CAEL_REPO="$2"; shift 2;;
    -h|--help)
      sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
      exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

mkdir -p "$CACHE_DIR" "$(dirname "$OUT")"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log() { printf '\033[1;34m[build-sidecar]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[build-sidecar] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

fetch() {  # fetch URL DEST
  local url="$1" dest="$2"
  if [[ -f "$dest" ]]; then
    log "cached: $(basename "$dest")"
    return 0
  fi
  log "downloading: $(basename "$dest")"
  curl -fsSL --retry 3 -o "$dest.partial" "$url"
  mv "$dest.partial" "$dest"
}

require() {  # require CMD MSG
  command -v "$1" >/dev/null 2>&1 || die "$2 (need \`$1\` on PATH)"
}

# ---------------------------------------------------------------------------
# Sanity checks
# ---------------------------------------------------------------------------

require curl "install curl"
require tar  "install tar"
require shasum "install shasum (comes with macOS)"

[[ "$(uname -sm)" == "Darwin arm64" ]] || die "this script only supports Apple Silicon (arm64). got $(uname -sm)"
[[ -d "$CAEL_REPO/services/caal-stt" ]] || die "cael repo missing or has no slim services at $CAEL_REPO/services/"
[[ -f "$CAEL_REPO/voice_agent.py" ]] || die "cael repo missing voice_agent.py at $CAEL_REPO/"

# ---------------------------------------------------------------------------
# Staging area
# ---------------------------------------------------------------------------

STAGE="$(mktemp -d /tmp/sonique-sidecar.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT

log "staging in $STAGE"
mkdir -p "$STAGE/python" "$STAGE/services/caal-stt" "$STAGE/services/caal-tts" "$STAGE/services/caal-agent" "$STAGE/models/piper" "$STAGE/models/whisper" "$STAGE/piper"

# ---------------------------------------------------------------------------
# 1. Python standalone runtime
# ---------------------------------------------------------------------------

PY_TAR="$CACHE_DIR/python-${PYTHON_VERSION}-arm64.tar.gz"
fetch "$PYTHON_URL" "$PY_TAR"

log "extracting Python ${PYTHON_VERSION} runtime"
tar -xzf "$PY_TAR" -C "$STAGE/python" --strip-components=1

PYBIN="$STAGE/python/bin/python3"
[[ -x "$PYBIN" ]] || die "Python extraction failed: $PYBIN missing"
"$PYBIN" --version

# ---------------------------------------------------------------------------
# 2. Install all deps directly into the standalone Python (no venv)
#
# A venv stores its activation symlinks as absolute paths, which break when
# the tarball is unpacked at a different prefix on the end-user's machine.
# Installing into the standalone Python's own site-packages produces only
# regular files — no path-dependent symlinks.
# ---------------------------------------------------------------------------

log "installing service deps into standalone Python (no venv)"
"$PYBIN" -m pip install --quiet --upgrade pip

# caal-stt deps
"$PYBIN" -m pip install --quiet \
  fastapi==0.115.6 \
  "uvicorn[standard]==0.34.0" \
  faster-whisper==1.1.1 \
  requests==2.32.3 \
  python-multipart==0.0.20

# caal-tts deps — no piper-tts package on macOS arm64 (no piper-phonemize
# wheel). Binary-backed tts_server.py from sonique-mac/Sidecar/ replaces
# the Linux caal-tts server.py. Only needs fastapi + uvicorn + pydantic.

# caal-agent deps (livekit.agents + plugins)
"$PYBIN" -m pip install --quiet \
  "livekit-agents[openai,silero,groq]==1.3.3" \
  anthropic==0.42.0 \
  httpx==0.27.2

# ---------------------------------------------------------------------------
# 3. Copy cael services + agent sources
# ---------------------------------------------------------------------------

log "copying caal-stt / caal-tts / caal-agent sources from $CAEL_REPO"

cp -R "$CAEL_REPO/services/caal-stt/." "$STAGE/services/caal-stt/"
# caal-tts: use the macOS binary-backed variant shipped in sonique-mac, not
# the cael repo's Python-package-backed one. Same HTTP contract.
SIDECAR_SRC="$(cd "$(dirname "$0")/.." && pwd)/Sidecar"
cp "$SIDECAR_SRC/tts_server.py" "$STAGE/services/caal-tts/server.py"

# caal-agent: voice_agent.py + src/caal/ package + prompt/
cp "$CAEL_REPO/voice_agent.py" "$STAGE/services/caal-agent/"
cp -R "$CAEL_REPO/src" "$STAGE/services/caal-agent/src"
[[ -d "$CAEL_REPO/prompt" ]] && cp -R "$CAEL_REPO/prompt" "$STAGE/services/caal-agent/prompt"

# ---------------------------------------------------------------------------
# 4. Piper voice (Ryan default)
# ---------------------------------------------------------------------------

log "staging Piper binary (macOS arm64)"
PIPER_TAR="$CACHE_DIR/piper_macos_aarch64.tar.gz"
fetch "$PIPER_URL" "$PIPER_TAR"
tar -xzf "$PIPER_TAR" -C "$STAGE/piper" --strip-components=1
chmod +x "$STAGE/piper/piper"

log "staging Piper voice: $PIPER_VOICE"
fetch "$PIPER_VOICE_ONNX_URL" "$CACHE_DIR/${PIPER_VOICE}.onnx"
fetch "$PIPER_VOICE_JSON_URL" "$CACHE_DIR/${PIPER_VOICE}.onnx.json"
cp "$CACHE_DIR/${PIPER_VOICE}.onnx"      "$STAGE/models/piper/"
cp "$CACHE_DIR/${PIPER_VOICE}.onnx.json" "$STAGE/models/piper/"

# ---------------------------------------------------------------------------
# 5. faster-whisper model (small.en)
# ---------------------------------------------------------------------------

log "staging faster-whisper model: $WHISPER_MODEL"
"$PYBIN" -m pip install --quiet "huggingface-hub[cli]==0.27.0"
HF_HOME="$CACHE_DIR/hf" "$STAGE/python/bin/huggingface-cli" download "$WHISPER_REPO" \
  --local-dir "$STAGE/models/whisper/$WHISPER_MODEL" \
  --local-dir-use-symlinks False \
  >/dev/null

# ---------------------------------------------------------------------------
# 6. Launcher script (what SidecarManager executes)
# ---------------------------------------------------------------------------

log "writing launcher.sh"
cat > "$STAGE/launcher.sh" <<'LAUNCHER'
#!/usr/bin/env bash
# launcher.sh — start all four sidecar processes bound to 127.0.0.1
# Invoked by SoniqueBar's SidecarManager. First argument is the sidecar root.
set -euo pipefail

ROOT="${1:?launcher requires sidecar root as first arg}"
SERVICE="${2:?launcher requires service name as second arg}"

export PATH="$ROOT/python/bin:$PATH"
export PYTHONUNBUFFERED=1

case "$SERVICE" in
  stt)
    export HOST=127.0.0.1 PORT=8081
    export STT_MODEL=small.en STT_DEVICE=cpu STT_COMPUTE=int8
    export HF_HOME="$ROOT/models/whisper"
    cd "$ROOT/services/caal-stt"
    exec python -m uvicorn server:app --host 127.0.0.1 --port 8081 --log-level warning
    ;;
  tts)
    export HOST=127.0.0.1 PORT=8082
    export TTS_VOICE=en_US-ryan-high
    export TTS_VOICE_DIR="$ROOT/models/piper"
    export PIPER_BIN="$ROOT/piper/piper"
    cd "$ROOT/services/caal-tts"
    exec python -m uvicorn server:app --host 127.0.0.1 --port 8082 --log-level warning
    ;;
  agent)
    export LIVEKIT_URL="${LIVEKIT_URL:-ws://127.0.0.1:7880}"
    export LIVEKIT_API_KEY="${LIVEKIT_API_KEY:-devkey}"
    export LIVEKIT_API_SECRET="${LIVEKIT_API_SECRET:-secret}"
    export SPEACHES_URL=http://127.0.0.1:8081
    export PIPER_URL=http://127.0.0.1:8082
    export TTS_PROVIDER=piper
    export TTS_MODEL=piper
    export WHISPER_MODEL=small.en
    export OLLAMA_HOST=http://127.0.0.1:11434
    export OLLAMA_MODEL=qwen2.5:3b
    cd "$ROOT/services/caal-agent"
    exec python voice_agent.py start
    ;;
  *)
    echo "unknown service: $SERVICE" >&2
    exit 2
    ;;
esac
LAUNCHER
chmod +x "$STAGE/launcher.sh"

# ---------------------------------------------------------------------------
# 7. Manifest
# ---------------------------------------------------------------------------

cat > "$STAGE/manifest.json" <<MANIFEST
{
  "schema": 1,
  "built_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "python_version": "${PYTHON_VERSION}",
  "piper_voice": "${PIPER_VOICE}",
  "whisper_model": "${WHISPER_MODEL}",
  "ollama_required": true,
  "ollama_note": "Not bundled. User must install Ollama and load a model. Probed at 127.0.0.1:11434.",
  "services": [
    { "name": "stt",   "port": 8081, "health": "http://127.0.0.1:8081/health" },
    { "name": "tts",   "port": 8082, "health": "http://127.0.0.1:8082/health" },
    { "name": "agent", "port": null, "health": null }
  ]
}
MANIFEST

# ---------------------------------------------------------------------------
# 8. Pack
# ---------------------------------------------------------------------------

log "packing tarball → $OUT"
rm -f "$OUT"
tar -czf "$OUT" -C "$STAGE" .

SIZE_MB=$(( $(stat -f%z "$OUT") / 1024 / 1024 ))
SHA=$(shasum -a 256 "$OUT" | awk '{print $1}')

cat > "${OUT}.sha256" <<EOF
$SHA  $(basename "$OUT")
EOF

log "done"
log "  tarball: $OUT"
log "  size:    ${SIZE_MB} MB"
log "  sha256:  $SHA"
