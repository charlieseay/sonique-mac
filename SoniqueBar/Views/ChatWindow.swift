import SwiftUI
import AppKit

/// Persistent chat window for text conversations with Quinn.
/// Shares the same conversation history as voice interactions.
/// Auto-invokes LLM routing and MCP tools just like voice mode.
struct ChatWindow: View {
    @StateObject private var viewModel = ChatViewModel()
    @State private var messageText = ""
    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Circle()
                    .fill(Color.green)
                    .frame(width: 8, height: 8)

                Text("Chat with Quinn")
                    .font(.headline)

                Spacer()

                Text("\(viewModel.messages.count) messages")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            // Messages
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(viewModel.messages) { message in
                            MessageBubble(message: message)
                                .id(message.id)
                        }

                        if viewModel.isProcessing {
                            TypingIndicator()
                                .padding(.leading)
                        }
                    }
                    .padding()
                }
                .onChange(of: viewModel.messages.count) { _ in
                    if let lastMessage = viewModel.messages.last {
                        withAnimation {
                            proxy.scrollTo(lastMessage.id, anchor: .bottom)
                        }
                    }
                }
            }

            Divider()

            // Input
            HStack(spacing: 8) {
                TextField("Message Quinn...", text: $messageText)
                    .textFieldStyle(.plain)
                    .focused($isInputFocused)
                    .onSubmit {
                        sendMessage()
                    }

                Button(action: sendMessage) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 24))
                        .foregroundColor(messageText.isEmpty ? .gray : .blue)
                }
                .buttonStyle(.plain)
                .disabled(messageText.isEmpty || viewModel.isProcessing)
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
        }
        .frame(width: 600, height: 700)
        .onAppear {
            viewModel.loadConversation()
            isInputFocused = true
        }
    }

    private func sendMessage() {
        guard !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let text = messageText
        messageText = ""

        Task {
            await viewModel.sendMessage(text)
        }
    }
}

struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if message.isUser {
                Spacer()
            }

            VStack(alignment: message.isUser ? .trailing : .leading, spacing: 4) {
                Text(message.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(message.isUser ? Color.blue : Color(NSColor.controlBackgroundColor))
                    .foregroundColor(message.isUser ? .white : .primary)
                    .cornerRadius(16)

                Text(message.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: 450, alignment: message.isUser ? .trailing : .leading)

            if !message.isUser {
                Spacer()
            }
        }
    }
}

struct ChatMessage: Identifiable, Codable {
    let id: UUID
    let text: String
    let isUser: Bool
    let timestamp: Date

    init(text: String, isUser: Bool) {
        self.id = UUID()
        self.text = text
        self.isUser = isUser
        self.timestamp = Date()
    }
}

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var isProcessing = false

    private let maxSizeBytes: Int = 500 * 1024 * 1024  // 500 MB cap
    private let conversationFile: URL

    init() {
        // Store in iCloud shared container
        let containerID = "iCloud.com.seayniclabs.sonique"
        let fm = FileManager.default

        if let iCloudURL = fm.url(forUbiquityContainerIdentifier: containerID)?
            .appendingPathComponent("Documents/SoniqueProfiles/shared") {
            conversationFile = iCloudURL.appendingPathComponent("conversation.jsonl")
        } else {
            // Fallback to local
            let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            conversationFile = appSupport
                .appendingPathComponent("SoniqueBar/conversation.jsonl")
        }

        // Ensure directory exists
        try? fm.createDirectory(at: conversationFile.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
    }

    func loadConversation() {
        guard FileManager.default.fileExists(atPath: conversationFile.path) else { return }

        do {
            let content = try String(contentsOf: conversationFile, encoding: .utf8)
            let lines = content.split(separator: "\n")

            messages = lines.compactMap { line in
                guard let data = line.data(using: .utf8),
                      let message = try? JSONDecoder().decode(ChatMessage.self, from: data) else {
                    return nil
                }
                return message
            }

            print("[ChatWindow] Loaded \(messages.count) messages from iCloud")
        } catch {
            print("[ChatWindow] Failed to load conversation: \(error)")
        }
    }

    func sendMessage(_ text: String) async {
        let userMessage = ChatMessage(text: text, isUser: true)
        messages.append(userMessage)
        appendToFile(userMessage)

        isProcessing = true
        defer { isProcessing = false }

        // Try native intent first (time, calendar, battery, etc.)
        if let nativeResponse = await IntentRouter.shared.route(text) {
            let assistantMessage = ChatMessage(text: nativeResponse, isUser: false)
            messages.append(assistantMessage)
            appendToFile(assistantMessage)
            SoniqueBrain.shared.recordExchange(user: text, assistant: nativeResponse)
            print("[ChatWindow] ✓ Handled by native intent router")
            return
        }

        // Route through ModelRouter for LLM response
        do {
            let router = ModelRouter.shared
            let response = try await router.route(prompt: text, context: nil)

            let assistantMessage = ChatMessage(text: response.text, isUser: false)
            messages.append(assistantMessage)
            appendToFile(assistantMessage)

            // Record in brain's conversation history
            SoniqueBrain.shared.recordExchange(user: text, assistant: response.text)

            print("[ChatWindow] ✓ Response from \(response.provider) in \(String(format: "%.2f", response.latency))s")

        } catch {
            let errorMessage = ChatMessage(text: "I encountered an error: \(error.localizedDescription)", isUser: false)
            messages.append(errorMessage)
            appendToFile(errorMessage)

            print("[ChatWindow] ✗ Error: \(error)")
        }

        // Enforce size cap
        enforceQuota()
    }

    private func appendToFile(_ message: ChatMessage) {
        do {
            let data = try JSONEncoder().encode(message)
            guard let line = String(data: data, encoding: .utf8) else { return }

            let handle = try FileHandle(forWritingTo: conversationFile)
            handle.seekToEndOfFile()
            handle.write((line + "\n").data(using: .utf8)!)
            try handle.close()
        } catch {
            // File doesn't exist yet, create it
            let data = try? JSONEncoder().encode(message)
            if let line = data.flatMap({ String(data: $0, encoding: .utf8) }) {
                try? (line + "\n").write(to: conversationFile, atomically: true, encoding: .utf8)
            }
        }
    }

    private func enforceQuota() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: conversationFile.path),
              let size = attrs[.size] as? Int,
              size > maxSizeBytes else { return }

        // Keep most recent 70% of messages
        let keepCount = Int(Double(messages.count) * 0.7)
        messages = Array(messages.suffix(keepCount))

        // Rewrite file
        do {
            let lines = messages.compactMap { message -> String? in
                guard let data = try? JSONEncoder().encode(message),
                      let line = String(data: data, encoding: .utf8) else { return nil }
                return line
            }
            try lines.joined(separator: "\n").write(to: conversationFile, atomically: true, encoding: .utf8)

            print("[ChatWindow] Quota enforced: trimmed to \(keepCount) messages")
        } catch {
            print("[ChatWindow] Failed to enforce quota: \(error)")
        }
    }
}

/// Animated typing indicator (three bouncing dots)
struct TypingIndicator: View {
    @State private var animationOffset: [CGFloat] = [0, 0, 0]

    private let timer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(Color.secondary)
                        .frame(width: 8, height: 8)
                        .offset(y: animationOffset[index])
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(16)

            Spacer()
        }
        .onReceive(timer) { _ in
            withAnimation(.easeInOut(duration: 0.4)) {
                // Animate dots in sequence
                for i in 0..<3 {
                    animationOffset[i] = animationOffset[i] == 0 ? -6 : 0
                }
            }
        }
        .onAppear {
            // Start with staggered animation
            for i in 0..<3 {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.15) {
                    withAnimation(.easeInOut(duration: 0.4).repeatForever(autoreverses: true)) {
                        animationOffset[i] = -6
                    }
                }
            }
        }
    }
}

#Preview {
    ChatWindow()
}
