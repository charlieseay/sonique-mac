import SwiftUI

/// SoniqueBar settings panel
struct SettingsView: View {
    // Assistant
    @AppStorage("assistant.name") private var assistantName: String = "Quinn"

    // Voice (TTS)
    @AppStorage("tts.kokoro.speed") private var kokoroSpeed: Double = 1.02
    @AppStorage("tts.kokoro.voice") private var kokoroVoice: String = "af_jessica"

    // Permissions
    @State private var users: [UserPermission] = []
    @State private var selectedUser: UserPermission?
    @State private var showingAddUser = false

    var body: some View {
        TabView {
            assistantTab
                .tabItem {
                    Label("Assistant", systemImage: "mic.fill")
                }

            permissionsTab
                .tabItem {
                    Label("Permissions", systemImage: "shield.fill")
                }

            voiceTab
                .tabItem {
                    Label("Voice", systemImage: "speaker.wave.2.fill")
                }
        }
        .frame(width: 600, height: 500)
        .onAppear {
            loadUsers()
        }
    }

    // MARK: - Assistant Tab

    private var assistantTab: some View {
        Form {
            Section("Identity") {
                TextField("Name", text: $assistantName)

                Text("This is your voice assistant's name")
                    .font(.caption)
                    .foregroundColor(.secondary)
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
    }

    // MARK: - Permissions Tab

    private var permissionsTab: some View {
        HSplitView {
            // User list
            VStack(alignment: .leading, spacing: 0) {
                List(users, selection: $selectedUser) { user in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(user.name)
                            .font(.headline)
                        Text(user.accessLevel.displayName)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                    .tag(user)
                }

                Divider()

                HStack {
                    Button(action: { showingAddUser = true }) {
                        Label("Add User", systemImage: "plus")
                    }
                    .buttonStyle(.borderless)

                    Spacer()

                    if selectedUser != nil {
                        Button(role: .destructive, action: deleteSelectedUser) {
                            Label("Delete", systemImage: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .padding(8)
            }
            .frame(minWidth: 200, idealWidth: 250)

            // User details
            if let user = selectedUser {
                userDetailView(for: user)
            } else {
                VStack {
                    Text("Select a user to edit permissions")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .sheet(isPresented: $showingAddUser) {
            AddUserSheet(onAdd: { newUser in
                PermissionManager.shared.addUser(newUser)
                loadUsers()
                selectedUser = newUser
            })
        }
    }

    private func userDetailView(for user: UserPermission) -> some View {
        Form {
            Section("User Info") {
                TextField("Name", text: binding(for: user, \.name))

                TextEditor(text: binding(for: user, \.notes))
                    .frame(height: 60)
                    .font(.caption)
            }

            Section("Access Level") {
                Picker("Level", selection: binding(for: user, \.accessLevel)) {
                    ForEach(AccessLevel.allCases) { level in
                        VStack(alignment: .leading) {
                            Text(level.displayName)
                            Text(level.description)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .tag(level)
                    }
                }
                .pickerStyle(.inline)
            }

            if user.accessLevel.canWriteGlobal {
                Section("Confirmations Required") {
                    Toggle("External Communications (Slack, email)",
                           isOn: binding(for: user, \.requireConfirmation.externalComms))

                    Toggle("Spending Money (paid APIs)",
                           isOn: binding(for: user, \.requireConfirmation.spending))

                    Toggle("Destructive Operations (delete, force-push)",
                           isOn: binding(for: user, \.requireConfirmation.destructive))
                }
            }

            Section("Security") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Bearer Token")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    HStack {
                        Text(user.bearerToken.prefix(16) + "...")
                            .font(.system(.caption, design: .monospaced))

                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(user.bearerToken, forType: .string)
                        }
                        .controlSize(.small)

                        Button("Regenerate") {
                            regenerateToken(for: user)
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Voice Tab

    private var voiceTab: some View {
        Form {
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
        }
        .formStyle(.grouped)
    }

    // MARK: - Helpers

    private func loadUsers() {
        users = PermissionManager.shared.allUsers()
        if selectedUser == nil {
            selectedUser = users.first
        }
    }

    private func binding<T>(for user: UserPermission, _ keyPath: WritableKeyPath<UserPermission, T>) -> Binding<T> {
        Binding(
            get: { user[keyPath: keyPath] },
            set: { newValue in
                if let index = users.firstIndex(where: { $0.id == user.id }) {
                    users[index][keyPath: keyPath] = newValue
                    selectedUser = users[index]
                    PermissionManager.shared.updateUser(users[index])
                }
            }
        )
    }

    private func deleteSelectedUser() {
        guard let user = selectedUser else { return }
        PermissionManager.shared.deleteUser(user)
        loadUsers()
        selectedUser = users.first
    }

    private func regenerateToken(for user: UserPermission) {
        let newToken = UUID().uuidString
        if let index = users.firstIndex(where: { $0.id == user.id }) {
            users[index].bearerToken = newToken
            selectedUser = users[index]
            PermissionManager.shared.updateUser(users[index])
        }
    }
}

// MARK: - Add User Sheet

struct AddUserSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var accessLevel: AccessLevel = .readOnlyGlobal
    @State private var notes = ""

    let onAdd: (UserPermission) -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Add New User")
                .font(.headline)

            Form {
                TextField("Name", text: $name)

                Picker("Access Level", selection: $accessLevel) {
                    ForEach(AccessLevel.allCases) { level in
                        Text(level.displayName).tag(level)
                    }
                }

                TextField("Notes (optional)", text: $notes)
            }

            HStack {
                Button("Cancel") {
                    dismiss()
                }

                Button("Add User") {
                    let newUser = UserPermission(
                        name: name,
                        bearerToken: UUID().uuidString,
                        accessLevel: accessLevel,
                        notes: notes
                    )
                    onAdd(newUser)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.isEmpty)
            }
        }
        .padding()
        .frame(width: 400, height: 300)
    }
}

#Preview {
    SettingsView()
}
