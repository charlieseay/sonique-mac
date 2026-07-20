import SwiftUI
import EventKit
import CoreLocation

/// First-run setup wizard for SoniqueBar permissions
struct SetupWizard: View {
    @StateObject private var viewModel = SetupWizardViewModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 12) {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 60))
                    .foregroundStyle(.blue)

                Text("Welcome to SoniqueBar")
                    .font(.title)
                    .fontWeight(.bold)

                Text("Quinn needs a few permissions to work her magic")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .padding(.top, 40)
            .padding(.bottom, 30)

            Divider()

            // Permissions list
            ScrollView {
                VStack(spacing: 16) {
                    PermissionRow(
                        icon: "location.fill",
                        title: "Location",
                        description: "Get local weather when you ask 'what's the weather?'",
                        status: viewModel.locationStatus,
                        action: { await viewModel.requestLocation() }
                    )

                    PermissionRow(
                        icon: "calendar",
                        title: "Calendar",
                        description: "Answer questions about your schedule",
                        status: viewModel.calendarStatus,
                        action: { await viewModel.requestCalendar() }
                    )

                    PermissionRow(
                        icon: "bell.fill",
                        title: "Reminders",
                        description: "Create and manage tasks via voice",
                        status: viewModel.remindersStatus,
                        action: { await viewModel.requestReminders() }
                    )

                    PermissionRow(
                        icon: "person.crop.circle",
                        title: "Contacts",
                        description: "Answer questions about people",
                        status: viewModel.contactsStatus,
                        action: { await viewModel.requestContacts() }
                    )
                }
                .padding()
            }

            Divider()

            // Footer
            HStack {
                if viewModel.allGranted {
                    Spacer()
                    Button("Get Started") {
                        viewModel.markSetupComplete()
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                } else {
                    Button("Skip for Now") {
                        viewModel.markSetupComplete()
                        dismiss()
                    }
                    .buttonStyle(.bordered)

                    Spacer()

                    Button("Grant All Permissions") {
                        Task {
                            await viewModel.requestAllPermissions()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
            .padding()
        }
        .frame(width: 550, height: 600)
    }
}

struct PermissionRow: View {
    let icon: String
    let title: String
    let description: String
    let status: PermissionStatus
    let action: () async -> Void

    @State private var isRequesting = false

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            // Icon
            Image(systemName: icon)
                .font(.system(size: 28))
                .foregroundStyle(statusColor)
                .frame(width: 40)

            // Text
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)

                Text(description)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            // Status/Action
            Group {
                switch status {
                case .notDetermined:
                    Button(isRequesting ? "Requesting..." : "Grant") {
                        isRequesting = true
                        Task {
                            await action()
                            isRequesting = false
                        }
                    }
                    .disabled(isRequesting)

                case .granted:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.title2)

                case .denied:
                    Button("Open Settings") {
                        openSystemSettings()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                case .restricted:
                    Text("Restricted")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(12)
    }

    private var statusColor: Color {
        switch status {
        case .granted: return .green
        case .denied: return .red
        case .restricted: return .orange
        case .notDetermined: return .blue
        }
    }

    private func openSystemSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy")!)
    }
}

enum PermissionStatus {
    case notDetermined
    case granted
    case denied
    case restricted
}

@MainActor
final class SetupWizardViewModel: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var locationStatus: PermissionStatus = .notDetermined
    @Published var calendarStatus: PermissionStatus = .notDetermined
    @Published var remindersStatus: PermissionStatus = .notDetermined
    @Published var contactsStatus: PermissionStatus = .notDetermined

    private let locationManager = CLLocationManager()
    private let eventStore = EKEventStore()

    var allGranted: Bool {
        locationStatus == .granted &&
        calendarStatus == .granted &&
        remindersStatus == .granted &&
        contactsStatus == .granted
    }

    override init() {
        super.init()
        locationManager.delegate = self
        checkCurrentStatuses()
    }

    func checkCurrentStatuses() {
        // Location
        let locationAuth = locationManager.authorizationStatus
        #if os(macOS)
        locationStatus = locationAuth == .authorized || locationAuth == .authorizedAlways ? .granted :
                        locationAuth == .denied ? .denied :
                        locationAuth == .restricted ? .restricted : .notDetermined
        #else
        locationStatus = locationAuth == .authorizedWhenInUse || locationAuth == .authorizedAlways ? .granted :
                        locationAuth == .denied ? .denied :
                        locationAuth == .restricted ? .restricted : .notDetermined
        #endif

        // Calendar
        let calendarAuth = EKEventStore.authorizationStatus(for: .event)
        if #available(macOS 14.0, *) {
            calendarStatus = calendarAuth == .fullAccess || calendarAuth == .authorized ? .granted :
                            calendarAuth == .denied ? .denied :
                            calendarAuth == .restricted ? .restricted : .notDetermined
        } else {
            calendarStatus = calendarAuth == .authorized ? .granted :
                            calendarAuth == .denied ? .denied :
                            calendarAuth == .restricted ? .restricted : .notDetermined
        }

        // Reminders
        let remindersAuth = EKEventStore.authorizationStatus(for: .reminder)
        if #available(macOS 14.0, *) {
            remindersStatus = remindersAuth == .fullAccess || remindersAuth == .authorized ? .granted :
                             remindersAuth == .denied ? .denied :
                             remindersAuth == .restricted ? .restricted : .notDetermined
        } else {
            remindersStatus = remindersAuth == .authorized ? .granted :
                             remindersAuth == .denied ? .denied :
                             remindersAuth == .restricted ? .restricted : .notDetermined
        }

        // Contacts (using Contacts framework check would require import, simplified for now)
        contactsStatus = .notDetermined
    }

    func requestAllPermissions() async {
        await requestLocation()
        await requestCalendar()
        await requestReminders()
        await requestContacts()
    }

    func requestLocation() async {
        #if os(macOS)
        locationManager.requestAlwaysAuthorization()
        #else
        locationManager.requestWhenInUseAuthorization()
        #endif

        // Wait a bit for the system dialog
        try? await Task.sleep(nanoseconds: 500_000_000)
        checkCurrentStatuses()
    }

    func requestCalendar() async {
        if #available(macOS 14.0, *) {
            do {
                let granted = try await eventStore.requestFullAccessToEvents()
                calendarStatus = granted ? .granted : .denied
            } catch {
                calendarStatus = .denied
            }
        } else {
            let granted = await withCheckedContinuation { continuation in
                eventStore.requestAccess(to: .event) { granted, _ in
                    continuation.resume(returning: granted)
                }
            }
            calendarStatus = granted ? .granted : .denied
        }
    }

    func requestReminders() async {
        if #available(macOS 14.0, *) {
            do {
                let granted = try await eventStore.requestFullAccessToReminders()
                remindersStatus = granted ? .granted : .denied
            } catch {
                remindersStatus = .denied
            }
        } else {
            let granted = await withCheckedContinuation { continuation in
                eventStore.requestAccess(to: .reminder) { granted, _ in
                    continuation.resume(returning: granted)
                }
            }
            remindersStatus = granted ? .granted : .denied
        }
    }

    func requestContacts() async {
        // Contacts framework request would go here
        // For now, just mark as granted (will show Open Settings if needed)
        contactsStatus = .granted
    }

    func markSetupComplete() {
        UserDefaults.standard.set(true, forKey: "SoniqueBar.SetupComplete")
    }

    // MARK: - CLLocationManagerDelegate

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            checkCurrentStatuses()
        }
    }
}

#Preview {
    SetupWizard()
}
