# SoniqueBar Resources

## Phi-3 Model Download

The bundled Phi-3 model is required for offline LLM inference but is too large (2.2GB) to commit to git.

**Download the model:**

```bash
cd SoniqueBar/Resources
curl -L -o phi-3-mini-4k-instruct.Q4_K_M.gguf \
  "https://huggingface.co/microsoft/Phi-3-mini-4k-instruct-gguf/resolve/main/Phi-3-mini-4k-instruct-q4.gguf"
```

**Verify download:**
```bash
ls -lh phi-3-mini-4k-instruct.Q4_K_M.gguf
# Expected: ~2.2GB
```

The model is already added to the Xcode project as a resource. After downloading, build and run SoniqueBar.

## LLM Routing

SoniqueBar uses a three-tier LLM provider strategy:

1. **System Ollama** (100-300ms) - Detects localhost:11434, uses existing models if available
2. **Bundled Phi-3** (150ms) - Uses this model for offline/guaranteed inference
3. **Network APIs** (1-2s) - Fallback to ask_llm/ask_helmsman

The bundled model ensures SoniqueBar always works, even offline and without system Ollama.
