import SwiftUI

// MARK: - ScrobblingSettingsView

/// Settings view for scrobbling services.
/// Iterates all registered services from the coordinator, rendering a reusable row for each.
struct ScrobblingSettingsView: View {
    @Environment(ScrobblingCoordinator.self) private var coordinator

    var body: some View {
        Form {
            if self.coordinator.services.isEmpty {
                Section {
                    ContentUnavailableView(
                        "No Scrobbling Services",
                        systemImage: "music.note.list",
                        description: Text(String(localized: "No scrobbling services are available to configure."))
                    )
                }
            } else {
                ForEach(self.coordinator.services, id: \.serviceName) { service in
                    // ListenBrainz authenticates with a pasted user token, not a
                    // browser flow, so it gets a dedicated row.
                    if let listenBrainz = service as? ListenBrainzService {
                        ListenBrainzServiceRow(service: listenBrainz)
                    } else {
                        ScrobbleServiceRow(service: service)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 400, minHeight: 300)
        .localizedNavigationTitle("Scrobbling")
    }
}

// MARK: - ScrobbleServiceRow

/// A reusable settings row for any scrobbling service backend.
struct ScrobbleServiceRow: View {
    let service: any ScrobbleServiceProtocol
    @State private var settings = SettingsManager.shared
    @State private var isAuthenticating = false

    var body: some View {
        Section {
            Toggle(isOn: self.enabledBinding) {
                Text(self.enableScrobblingToggleLabel)
            }

            // Connection status
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "Account"))
                        .font(.headline)
                    Text(self.connectionStatusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()

                self.connectionButton
            }
            .padding(.vertical, 4)
        } header: {
            Text(self.service.serviceName)
        }
    }

    // MARK: - Bindings

    /// Localized “Enable (service) Scrobbling” using `%@` so translators can reorder the service name.
    private var enableScrobblingToggleLabel: String {
        let format = String(
            localized: String.LocalizationValue("Enable %@ Scrobbling"),
            bundle: AppLocalization.bundle
        )
        return String(
            format: format,
            locale: self.settings.contentLanguage.locale,
            self.service.serviceName as CVarArg
        )
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { self.settings.isServiceEnabled(self.service.serviceName) },
            set: { self.settings.setServiceEnabled(self.service.serviceName, $0) }
        )
    }

    // MARK: - Computed Properties

    private var connectionStatusText: String {
        switch self.service.authState {
        case .disconnected:
            String(localized: "Not connected")
        case .authenticating:
            String(localized: "Waiting for authorization…")
        case let .connected(username):
            String(localized: "Connected as \(username)")
        case let .error(message):
            String(localized: "Error: \(message)")
        }
    }

    @ViewBuilder
    private var connectionButton: some View {
        switch self.service.authState {
        case .disconnected, .error:
            Button(String(localized: "Connect")) {
                Task {
                    self.isAuthenticating = true
                    defer { self.isAuthenticating = false }
                    do {
                        try await self.service.authenticate()
                    } catch {
                        DiagnosticsLogger.scrobbling.error("Auth failed for \(self.service.serviceName): \(error.localizedDescription)")
                    }
                }
            }
            .disabled(self.isAuthenticating)

        case .authenticating:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Button(String(localized: "Cancel")) {
                    Task {
                        await self.service.disconnect()
                    }
                }
            }

        case .connected:
            Button(String(localized: "Disconnect")) {
                Task {
                    await self.service.disconnect()
                }
            }
        }
    }
}

// MARK: - ListenBrainzServiceRow

/// Settings row for ListenBrainz: a pasted user token instead of a browser flow.
struct ListenBrainzServiceRow: View {
    let service: ListenBrainzService
    @State private var settings = SettingsManager.shared
    @State private var token = ""
    @State private var isConnecting = false

    var body: some View {
        Section {
            Toggle(isOn: self.enabledBinding) {
                Text("Enable ListenBrainz Scrobbling")
            }

            switch self.service.authState {
            case let .connected(username):
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Account")
                            .font(.headline)
                        Text("Connected as \(username)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Disconnect") {
                        Task { await self.service.disconnect() }
                    }
                }
                .padding(.vertical, 4)

            default:
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        SecureField("User token", text: self.$token)
                            .textFieldStyle(.roundedBorder)
                        if self.isConnecting {
                            ProgressView().controlSize(.small)
                        }
                        Button("Connect") { self.connect() }
                            .disabled(self.token.trimmingCharacters(in: .whitespaces).isEmpty || self.isConnecting)
                    }
                    if case let .error(message) = self.service.authState {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    Link(
                        "Get your token from listenbrainz.org",
                        destination: URL(string: "https://listenbrainz.org/settings/")!
                    )
                    .font(.caption)
                }
                .padding(.vertical, 4)
            }
        } header: {
            Text("ListenBrainz")
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { self.settings.isServiceEnabled(self.service.serviceName) },
            set: { self.settings.setServiceEnabled(self.service.serviceName, $0) }
        )
    }

    private func connect() {
        Task {
            self.isConnecting = true
            defer { self.isConnecting = false }
            do {
                try await self.service.connect(token: self.token)
                self.token = ""
            } catch {
                DiagnosticsLogger.scrobbling.error("ListenBrainz connect failed: \(error.localizedDescription)")
            }
        }
    }
}
