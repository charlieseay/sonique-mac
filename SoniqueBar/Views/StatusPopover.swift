import SwiftUI
import AppKit

struct StatusPopover: View {
    @EnvironmentObject var monitor: ServerMonitor
    @State private var showOnboarding = false

    var body: some View {
        VStack(spacing: 0) {
            // Identity header
            VStack(spacing: 10) {
                avatarView
                    .frame(width: 64, height: 64)

                Text(monitor.profile?.name ?? "Sonique")
                    .font(.system(size: 15, weight: .semibold))

                HStack(spacing: 5) {
                    Circle()
                        .fill(monitor.isOnline ? Color.green : Color.red)
                        .frame(width: 7, height: 7)
                    Text(monitor.isOnline ? "Online" : "Offline")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 18)
            .padding(.bottom, 14)

            Divider()

            VStack(spacing: 1) {
                popoverButton("Open Dashboard", icon: "square.grid.2x2") {
                    if let url = URL(string: monitor.settings.normalizedURL) {
                        NSWorkspace.shared.open(url)
                    }
                }
                popoverButton("Refresh", icon: "arrow.clockwise") {
                    Task { await monitor.refresh() }
                }
                Divider().padding(.horizontal, 8).padding(.vertical, 2)
                popoverButton("Settings", icon: "gearshape") {
                    showOnboarding = true
                }
                Divider().padding(.horizontal, 8).padding(.vertical, 2)
                popoverButton("Quit Sonique", icon: "power") {
                    NSApplication.shared.terminate(nil)
                }
            }
            .padding(.vertical, 6)
        }
        .frame(width: 240)
        .sheet(isPresented: $showOnboarding) {
            OnboardingView().environmentObject(monitor)
        }
    }

    @ViewBuilder
    private var avatarView: some View {
        Group {
            if let img = monitor.avatarImage {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFill()
                    .clipShape(Circle())
                    .overlay(Circle().strokeBorder(.white.opacity(0.15), lineWidth: 1))
            } else {
                Circle()
                    .fill(LinearGradient(colors: [Color(red: 0.4, green: 0.3, blue: 0.9),
                                                  Color(red: 0.6, green: 0.3, blue: 0.9)],
                                        startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay(Image(systemName: "waveform")
                        .font(.title2)
                        .foregroundStyle(.white))
            }
        }
    }

    private func popoverButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .frame(width: 16)
                    .foregroundStyle(.secondary)
                Text(title)
                    .foregroundStyle(.primary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Color.primary.opacity(0.001))
        .hoverEffect()
    }
}

private extension View {
    func hoverEffect() -> some View {
        self.onHover { hovering in _ = hovering }
    }
}
