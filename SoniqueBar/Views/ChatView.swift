import SwiftUI
import AppKit

struct ChatView: View {
    @EnvironmentObject var monitor: ServerMonitor
    @StateObject private var chat = ChatManager()
    @State private var inputText = ""
    @State private var scrollID: UUID?
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 10) {
                Circle()
                    .fill(monitor.isOnline
                          ? Color(red: 0.4, green: 0.3, blue: 0.9)
                          : Color(nsColor: .tertiaryLabelColor))
                    .frame(width: 8, height: 8)
                Text(monitor.profile?.name ?? "Cael")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if chat.isStreaming {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 16, height: 16)
                }
                Button {
                    NSApp.keyWindow?.close()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            // Message list
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if chat.messages.isEmpty && !chat.isStreaming {
                            Text("Start a conversation with \(monitor.profile?.name ?? "Cael").")
                                .font(.system(size: 12))
                                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                                .frame(maxWidth: .infinity)
                                .padding(.top, 40)
                        }

                        ForEach(chat.messages.filter { $0.role != .system }) { msg in
                            MessageBubble(message: msg)
                                .id(msg.id)
                        }

                        // Live streaming bubble
                        if chat.isStreaming && !chat.streamingContent.isEmpty {
                            StreamingBubble(text: chat.streamingContent)
                                .id("streaming")
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }
                .onChange(of: chat.messages.count) { _ in
                    scrollToBottom(proxy: proxy)
                }
                .onChange(of: chat.streamingContent) { _ in
                    scrollToBottom(proxy: proxy)
                }
            }

            Divider()

            // Input bar
            HStack(spacing: 8) {
                TextField("Message Cael…", text: $inputText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .lineLimit(1...5)
                    .focused($inputFocused)
                    .onSubmit { sendIfNotEmpty() }

                if chat.isStreaming {
                    Button {
                        chat.cancelStream()
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(Color(red: 0.6, green: 0.3, blue: 0.9))
                    }
                    .buttonStyle(.plain)
                } else {
                    Button {
                        sendIfNotEmpty()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(
                                inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? Color(nsColor: .tertiaryLabelColor)
                                : Color(red: 0.4, green: 0.3, blue: 0.9)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 420, idealWidth: 500, maxWidth: 700,
               minHeight: 480, idealHeight: 560, maxHeight: 900)
        .task {
            chat.configure(
                backendURL: monitor.settings.backendURL,
                apiKey: monitor.settings.apiKey
            )
            await chat.loadHistory()
            inputFocused = true
        }
    }

    private func sendIfNotEmpty() {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        inputText = ""
        chat.send(trimmed)
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        if chat.isStreaming {
            withAnimation(.easeOut(duration: 0.15)) {
                proxy.scrollTo("streaming", anchor: .bottom)
            }
        } else if let last = chat.messages.last {
            withAnimation(.easeOut(duration: 0.15)) {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }
}

// MARK: - Bubbles

private struct MessageBubble: View {
    let message: ChatMessage

    var isUser: Bool { message.role == .user }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if isUser { Spacer(minLength: 48) }
            Text(message.content)
                .font(.system(size: 13))
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(isUser
                    ? Color(red: 0.4, green: 0.3, blue: 0.9).opacity(0.15)
                    : Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(
                            isUser
                            ? Color(red: 0.4, green: 0.3, blue: 0.9).opacity(0.3)
                            : Color.primary.opacity(0.06),
                            lineWidth: 1
                        )
                )
            if !isUser { Spacer(minLength: 48) }
        }
    }
}

private struct StreamingBubble: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text(text + "▋")
                .font(.system(size: 13))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
                )
            Spacer(minLength: 48)
        }
    }
}
