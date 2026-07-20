import SwiftUI

/// SoniqueBar settings panel - simplified working version
struct SettingsView: View {
    // Assistant
    @AppStorage("assistant.name") private var assistantName: String = "Quinn"

    // Voice (TTS)
    @AppStorage("tts.kokoro.speed") private var kokoroSpeed: Double = 1.02
    @AppStorage("tts.kokoro.voice") private var kokoroVoice: String = "af_jessica"

    var body: some View {
        Form {
            Section("Assistant") {
                TextField("Name", text: $assistantName)

                Text("This is your voice assistant's name")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Voice Settings") {
                Picker("Kokoro Voice", selection: $kokoroVoice) {
                    Text("Jessica (Warm)").tag("af_jessica")
                    Text("Bella (Soft)").tag("af_bella")
                    Text("Sarah (Clear)").tag("af_sarah")
                    Text("Nicole (British)").tag("af_nicole")
                    Text("Sky (Bright)").tag("af_sky")
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Speech Rate")
                        Spacer()
                        Text("\(Int(kokoroSpeed * 100))%")
                            .foregroundColor(.secondary)
                    }

                    Slider(value: $kokoroSpeed, in: 0.5...2.0, step: 0.01)

                    HStack {
                        Button("Slower") { kokoroSpeed = max(0.5, kokoroSpeed - 0.05) }
                            .controlSize(.small)
                        Button("Reset") { kokoroSpeed = 1.0 }
                            .controlSize(.small)
                        Button("Faster") { kokoroSpeed = min(2.0, kokoroSpeed + 0.05) }
                            .controlSize(.small)
                    }
                    .buttonStyle(.bordered)
                }
            }

            Section("Current Setup") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Voice: Kokoro (on-device)")
                    Text("LLM: Claude CLI with adaptive routing")
                    Text("• Conversational: Haiku")
                    Text("• Thinking: Sonnet")
                    Text("• Tools: Opus")
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 500)
    }
}

#Preview {
    SettingsView()
}
