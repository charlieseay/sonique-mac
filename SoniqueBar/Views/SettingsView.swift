import SwiftUI

/// SoniqueBar settings panel - configure TTS provider, LLM provider, voices
struct SettingsView: View {
    @AppStorage("tts.provider") private var ttsProvider: String = "piper"  // piper, elevenlabs
    @AppStorage("tts.elevenlabs.apiKey") private var elevenLabsKey: String = ""
    @AppStorage("tts.piper.voice") private var piperVoice: String = "en_US-lessac-medium"

    @AppStorage("llm.provider") private var llmProvider: String = "ollama"  // ollama, claude-cli, bedrock
    @AppStorage("llm.ollama.host") private var ollamaHost: String = "http://localhost:11434"
    @AppStorage("llm.ollama.model") private var ollamaModel: String = "qwen2.5:14b-instruct-q4_K_M"
    @AppStorage("llm.fallback.enabled") private var fallbackEnabled: Bool = true
    @AppStorage("llm.fallback.provider") private var fallbackProvider: String = "claude-cli"

    @State private var showingAdvanced = false

    var body: some View {
        Form {
            Section("Text-to-Speech") {
                Picker("Voice Provider", selection: $ttsProvider) {
                    Text("Piper (Local, Free)").tag("piper")
                    Text("ElevenLabs (Cloud, Premium)").tag("elevenlabs")
                }
                .pickerStyle(.segmented)

                if ttsProvider == "piper" {
                    Picker("Piper Voice", selection: $piperVoice) {
                        Text("Lessac (Female, Clear)").tag("en_US-lessac-medium")
                        Text("Ryan (Male, Deep)").tag("en_US-ryan-medium")
                        Text("Kristin (Female, Warm)").tag("en_US-kristin-medium")
                        Text("Kusal (Male, Smooth)").tag("en_US-kusal-medium")
                        Text("Amy (Female, Bright)").tag("en_US-amy-medium")
                    }

                    Text("Piper runs locally - no API costs, no internet required")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if ttsProvider == "elevenlabs" {
                    SecureField("ElevenLabs API Key", text: $elevenLabsKey)
                        .textFieldStyle(.roundedBorder)

                    Link("Get API Key →", destination: URL(string: "https://elevenlabs.io/app/settings/api-keys")!)
                        .font(.caption)
                }
            }

            Section("Language Model") {
                Picker("Primary LLM", selection: $llmProvider) {
                    Text("Ollama (Local, Free)").tag("ollama")
                    Text("Claude CLI (Cloud, Subscription)").tag("claude-cli")
                    Text("Bedrock (Cloud, Pay-per-token)").tag("bedrock")
                }
                .pickerStyle(.menu)

                if llmProvider == "ollama" {
                    TextField("Ollama Host", text: $ollamaHost)
                        .textFieldStyle(.roundedBorder)

                    TextField("Model Name", text: $ollamaModel)
                        .textFieldStyle(.roundedBorder)

                    Text("Recommended: qwen2.5:14b-instruct-q4_K_M")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Toggle("Enable fallback to Claude CLI", isOn: $fallbackEnabled)

                    if fallbackEnabled {
                        Text("Falls back to Claude CLI if Ollama is unavailable")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                if llmProvider == "claude-cli" {
                    Text("Using claude CLI (must be installed via npm/homebrew)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if llmProvider == "bedrock" {
                    Text("Requires AWS credentials in ~/.aws/credentials")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Section("Best Practices") {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Recommended Setup", systemImage: "star.fill")
                        .font(.headline)

                    Text("• TTS: Piper (free, high quality, fast)")
                    Text("• LLM: Ollama with Claude CLI fallback")
                    Text("• Upgrade to ElevenLabs only if you need premium voices")

                    Divider()

                    Text("Why Piper?")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Text("Runs on your Mac Mini - no API costs, sub-100ms latency, natural voices")

                    Text("Why Ollama?")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Text("Private, fast, free - runs qwen2.5:14b locally with tool calling")
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 600)
    }
}

#Preview {
    SettingsView()
}
