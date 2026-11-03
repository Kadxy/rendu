import SwiftUI

/// The paired server: whether it's up, what it holds, and maintenance.
/// (Its API keys are the row under it in Settings.)
struct ServerView: View {
    let services: AppServices

    @State private var pairing = false
    @State private var confirmReimport = false
    @State private var confirmWipe = false
    @State private var confirmForget = false
    @State private var wiping = false
    @State private var wipeError: String?
    @State private var haptic = HapticEvent()
    @Environment(\.dismiss) private var dismiss

    private var settings: AppSettings { services.settings }

    var body: some View {
        let server = services.server
        Form {
            Section {
                LabeledContent("Host") {
                    Text(verbatim: settings.baseURL?.host() ?? settings.endpoint)
                }
                LabeledContent("Status") {
                    ServerStatusLine(server: server)
                }
            } footer: {
                switch server.reachability {
                case .offline(let reason): Text(verbatim: reason)
                case .keyRejected:
                    Text(
                        "This iPhone is no longer paired because another iPhone was paired with the server. Pair again to continue syncing."
                    )
                default: EmptyView()
                }
            }

            // Only when the server no longer accepts this iPhone; switching
            // servers is Forget This Server, then pairing.
            if server.reachability == .keyRejected {
                Section {
                    Button("Pair Again…") { pairing = true }
                }
            }

            if let status = server.status {
                Section {
                    LabeledContent("Samples") {
                        Text(status.samples, format: .number)
                    }
                    if let types = status.types {
                        LabeledContent("Types") {
                            Text(types, format: .number)
                        }
                    }
                    LabeledContent("Pending Entries") {
                        Text(status.pendingWrites, format: .number)
                    }
                    if let lastIngest = status.lastIngest {
                        LabeledContent("Last Upload") {
                            Text(verbatim: lastIngest.listStamp)
                        }
                    }
                    if let version = status.version {
                        LabeledContent("Server Version") {
                            Text(verbatim: version).monospaced()
                        }
                    }
                }
            }

            Section {
                Toggle(
                    String(localized: "Require \(ServerLock.methodName)"),
                    isOn: Binding(
                        get: { services.lock.enabled },
                        set: { value in Task { await services.lock.setEnabled(value) } }
                    ))
            } footer: {
                Text("Requires \(ServerLock.methodName) to open the server and its API keys, or to pair.")
            }

            Section {
                Button("Re-import All History", role: .destructive) {
                    confirmReimport = true
                }
                .confirmationDialog("Re-import all history?", isPresented: $confirmReimport, titleVisibility: .visible) {
                    Button("Re-import", role: .destructive) {
                        Task { await services.reimportAll() }
                    }
                } message: {
                    Text("All of this iPhone's Apple Health history will be uploaded again. The server ignores duplicates.")
                }
                Button("Clear Server Data", role: .destructive) {
                    confirmWipe = true
                }
                .disabled(wiping)
                .confirmationDialog("Clear all data on the server?", isPresented: $confirmWipe, titleVisibility: .visible) {
                    Button("Clear Server Data", role: .destructive) { wipe() }
                } message: {
                    Text(
                        "All samples, statistics and write requests on the server will be deleted, and this iPhone's Apple Health history will be uploaded again. Keys are kept. Apple Health on this iPhone is not affected."
                    )
                }
            } footer: {
                if let wipeError {
                    Text(verbatim: wipeError).foregroundStyle(.red)
                }
            }

            Section {
                Button("Forget This Server", role: .destructive) {
                    confirmForget = true
                }
                .confirmationDialog("Forget this server?", isPresented: $confirmForget, titleVisibility: .visible) {
                    Button("Forget This Server", role: .destructive) {
                        Task {
                            await services.forgetServer()
                            dismiss()
                        }
                    }
                } message: {
                    Text(
                        "This iPhone will delete its key and stop syncing. Data on the server is kept. Pair again to resume syncing."
                    )
                }
            }
        }
        .haptic(haptic)
        .navigationTitle("Server")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await services.refreshServerStatus()
        }
        .sheet(isPresented: $pairing) {
            PairView(services: services)
        }
    }

    private func wipe() {
        guard !wiping else { return }
        wiping = true
        Task {
            defer { wiping = false }
            do {
                try await services.wipeServer()
                wipeError = nil
                haptic.play(.success)
            } catch {
                wipeError = error.localizedDescription
                haptic.play(.error)
            }
        }
    }
}
