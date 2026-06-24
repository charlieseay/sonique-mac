import SwiftUI

struct SettingsView: View {
    @StateObject private var registry = ConnectorRegistry.shared
    @State private var selectedTab: SettingsTab = .connectors

    enum SettingsTab: String, CaseIterable {
        case connectors = "Connectors"
        case llm = "LLM Providers"
        case voice = "Voice"
        case general = "General"

        var icon: String {
            switch self {
            case .connectors: return "puzzlepiece.extension"
            case .llm: return "brain"
            case .voice: return "waveform"
            case .general: return "gearshape"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(SettingsTab.allCases, id: \.self, selection: $selectedTab) { tab in
                Label(tab.rawValue, systemImage: tab.icon)
            }
            .navigationTitle("Settings")
            .frame(minWidth: 200)
        } detail: {
            Group {
                switch selectedTab {
                case .connectors:
                    ConnectorsSettingsView()
                case .llm:
                    LLMProvidersSettingsView()
                case .voice:
                    VoiceSettingsView()
                case .general:
                    GeneralSettingsView()
                }
            }
            .frame(minWidth: 500, minHeight: 400)
        }
    }
}

// MARK: - Connectors Settings

struct ConnectorsSettingsView: View {
    @StateObject private var registry = ConnectorRegistry.shared

    var body: some View {
        Form {
            Section("Available Connectors") {
                ForEach(ConnectorCategory.allCases, id: \.self) { category in
                    if !connectorsForCategory(category).isEmpty {
                        Section(category.displayName) {
                            ForEach(connectorsForCategory(category), id: \.id) { connector in
                                ConnectorRow(connector: connector)
                            }
                        }
                    }
                }
            }

            Section("Help") {
                Text("Enable connectors to allow Quinn to perform actions on your behalf.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Connectors")
    }

    private func connectorsForCategory(_ category: ConnectorCategory) -> [any ActionConnector] {
        registry.connectors.filter { $0.category == category }
    }
}

struct ConnectorRow: View {
    let connector: any ActionConnector
    @StateObject private var registry = ConnectorRegistry.shared
    @State private var isEnabled: Bool

    init(connector: any ActionConnector) {
        self.connector = connector
        _isEnabled = State(initialValue: connector.isEnabled)
    }

    var body: some View {
        HStack {
            Image(systemName: connector.category.icon)
                .foregroundColor(.blue)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text(connector.name)
                    .font(.headline)
                Text(connector.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Toggle("", isOn: $isEnabled)
                .labelsHidden()
                .onChange(of: isEnabled) { newValue in
                    registry.setEnabled(id: connector.id, enabled: newValue)
                }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - LLM Providers Settings

struct LLMProvidersSettingsView: View {
    @AppStorage("llm_provider") private var provider: String = "claude"
    @AppStorage("claude_model") private var claudeModel: String = "haiku"
    @AppStorage("openai_api_key") private var openaiKey: String = ""
    @AppStorage("anthropic_api_key") private var anthropicKey: String = ""

    var body: some View {
        Form {
            Section("Default Provider") {
                Picker("Provider", selection: $provider) {
                    Text("Claude (ask_claude)").tag("claude")
                    Text("OpenAI").tag("openai")
                    Text("Gemini (ask_gemini)").tag("gemini")
                    Text("NVIDIA NIM").tag("nvidia")
                }
                .pickerStyle(.segmented)
            }

            if provider == "claude" {
                Section("Claude Configuration") {
                    Picker("Default Model", selection: $claudeModel) {
                        Text("Haiku (Fast)").tag("haiku")
                        Text("Sonnet (Balanced)").tag("sonnet")
                        Text("Opus (Best)").tag("opus")
                    }

                    SecureField("API Key (optional - uses ask_claude by default)", text: $anthropicKey)
                }
            }

            if provider == "openai" {
                Section("OpenAI Configuration") {
                    SecureField("API Key", text: $openaiKey)

                    Text("OpenAI GPT-4 will be used for conversations")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Section("Help") {
                Text("Quinn uses subscriptions (ask_claude, ask_gemini) by default. API keys are only needed if you want to override the default providers.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("LLM Providers")
    }
}

// MARK: - Voice Settings

struct VoiceSettingsView: View {
    @AppStorage("tts_provider") private var ttsProvider: String = "elevenlabs"
    @AppStorage("elevenlabs_voice_id") private var voiceID: String = ""
    @AppStorage("wake_word_enabled") private var wakeWordEnabled: Bool = false

    var body: some View {
        Form {
            Section("Text-to-Speech") {
                Picker("Provider", selection: $ttsProvider) {
                    Text("ElevenLabs").tag("elevenlabs")
                    Text("OpenAI TTS").tag("openai")
                    Text("macOS System Voice").tag("system")
                }

                if ttsProvider == "elevenlabs" {
                    TextField("Voice ID", text: $voiceID)
                        .help("ElevenLabs voice ID for Quinn's voice")
                }
            }

            Section("Wake Word") {
                Toggle("Enable Wake Word Detection", isOn: $wakeWordEnabled)

                if wakeWordEnabled {
                    Text("⚠️ Wake word detection coming in Week 4")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }

            Section("Help") {
                Text("Quinn currently uses ElevenLabs for natural voice output. Wake word detection will allow hands-free activation.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Voice Settings")
    }
}

// MARK: - General Settings

struct GeneralSettingsView: View {
    @AppStorage("quinn_name") private var quinnName: String = "Quinn"
    @AppStorage("auto_start") private var autoStart: Bool = true
    @AppStorage("show_menu_bar_icon") private var showMenuBar: Bool = true

    var body: some View {
        Form {
            Section("Identity") {
                TextField("Assistant Name", text: $quinnName)
                    .help("What Quinn calls herself")
            }

            Section("Startup") {
                Toggle("Launch at Login", isOn: $autoStart)
                Toggle("Show Menu Bar Icon", isOn: $showMenuBar)
            }

            Section("About") {
                HStack {
                    Text("Version")
                    Spacer()
                    Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                        .foregroundColor(.secondary)
                }

                HStack {
                    Text("Build")
                    Spacer()
                    Text(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown")
                        .foregroundColor(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("General")
    }
}

// MARK: - Category Extensions

extension ConnectorCategory {
    var displayName: String {
        switch self {
        case .taskManagement: return "Task Management"
        case .homeAutomation: return "Home Automation"
        case .communication: return "Communication"
        case .development: return "Development"
        case .knowledge: return "Knowledge"
        case .system: return "System"
        case .custom: return "Custom"
        }
    }
}

#Preview {
    SettingsView()
        .frame(width: 800, height: 600)
}
