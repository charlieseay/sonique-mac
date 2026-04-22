import SwiftUI

@main
struct SoniqueBarApp: App {
    @StateObject private var monitor = ServerMonitor()

    var body: some Scene {
        MenuBarExtra {
            if monitor.settings.isConfigured {
                StatusPopover()
                    .environmentObject(monitor)
            } else {
                OnboardingView()
                    .environmentObject(monitor)
            }
        } label: {
            BarLabel(monitor: monitor)
        }
        .menuBarExtraStyle(.window)
    }
}

private struct BarLabel: View {
    @ObservedObject var monitor: ServerMonitor

    var body: some View {
        if let img = monitor.avatarImage {
            Image(nsImage: circularImage(img, size: 18))
                .resizable()
                .frame(width: 18, height: 18)
        } else {
            Image(systemName: "waveform")
        }
    }

    private func circularImage(_ source: NSImage, size: CGFloat) -> NSImage {
        let result = NSImage(size: NSSize(width: size, height: size))
        result.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        let path = NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: size, height: size))
        path.addClip()
        source.draw(in: NSRect(x: 0, y: 0, width: size, height: size),
                    from: .zero, operation: .sourceOver, fraction: 1)
        result.unlockFocus()
        return result
    }
}
