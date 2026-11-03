import SwiftUI

/// Pairs this iPhone with a server, in two steps. First the address, checked
/// once when the user goes on. Then a 6-digit code made up on the phone,
/// with its own key: the user runs `rendu-server pair CODE` on the server,
/// and the phone, asking every two seconds, hands the server its key once
/// the code is there. The key never appears anywhere.
struct PairView: View {
    let services: AppServices
    @Environment(\.dismiss) private var dismiss

    private enum Step: Equatable {
        case address
        case code(URL)
    }

    @State private var step = Step.address
    @State private var address = ""
    @State private var checking = false
    @State private var addressError: LocalizedStringKey?

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .address: addressForm
                case .code(let server):
                    CodeForm(services: services, server: server) {
                        withAnimation { step = .address }
                    } onPaired: {
                        dismiss()
                    }
                }
            }
            .navigationTitle("Pair with Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                if step == .address {
                    ToolbarItem(placement: .confirmationAction) {
                        if checking {
                            ProgressView()
                        } else {
                            Button("Next") { Task { await next() } }
                                .disabled(AppSettings.baseURL(from: address) == nil)
                        }
                    }
                }
            }
        }
        .onAppear {
            if address.isEmpty { address = services.settings.baseURL?.absoluteString ?? "" }
        }
    }

    private var addressForm: some View {
        Form {
            Section {
                TextField(text: $address, prompt: Text(verbatim: "https://rendu.example.com")) {
                    Text("Server Address")
                }
                .keyboardType(.URL)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.next)
                .onSubmit { Task { await next() } }
                .onChange(of: address) { addressError = nil }
            } header: {
                Text("Server Address")
            } footer: {
                if let addressError {
                    Text(addressError).foregroundStyle(.red)
                }
            }
        }
        .haptic(trigger: addressError) { _, new in new == nil ? nil : .error }
    }

    private func next() async {
        guard let url = AppSettings.baseURL(from: address), !checking else { return }
        checking = true
        defer { checking = false }
        switch await services.uploader.check(base: url) {
        case .ok:
            withAnimation { step = .code(url) }
        case .notRendu:
            addressError = "No Rendu server was found at this address."
        case .unreachable:
            addressError = "Unable to connect to this server. Check the address and make sure the server is running."
        }
    }
}

/// The code to run on the server, and the wait for it.
private struct CodeForm: View {
    let services: AppServices
    let server: URL
    let changeServer: () -> Void
    let onPaired: () -> Void

    @State private var code = String(format: "%06d", Int.random(in: 0 ..< 1_000_000))
    @State private var key = OwnerKey.generate()
    @State private var state: PairResult = .waiting
    @State private var failures = 0
    @State private var toast = Toast()

    private var command: String { "rendu-server pair \(code)" }

    var body: some View {
        Form {
            Section {
                LabeledContent("Server") {
                    Text(verbatim: server.host() ?? server.absoluteString)
                }
                Button("Change Server", action: changeServer)
            }

            Section {
                VStack(spacing: 6) {
                    Text("Pairing Code")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(verbatim: "\(code.prefix(3)) \(code.suffix(3))")
                        .font(.system(size: 44, weight: .semibold, design: .rounded).monospacedDigit())
                        .tracking(2)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                Button {
                    UIPasteboard.general.string = command
                    toast.show("Copied")
                } label: {
                    HStack {
                        Text(verbatim: command)
                            .font(.callout.monospaced())
                            .foregroundStyle(.primary)
                        Spacer(minLength: 8)
                        Image(systemName: "doc.on.doc")
                    }
                }
            } header: {
                Text("Run on the Server")
            } footer: {
                Text("After pairing, an iPhone previously paired with this server stops syncing.")
            }

            Section {
                status
            }
        }
        .toast($toast)
        .haptic(trigger: state) { _, new in
            switch new {
            case .paired: .success
            case .wrongCode, .unsupported: .error
            default: nil
            }
        }
        .task { await poll() }
    }

    @ViewBuilder
    private var status: some View {
        switch state {
        case .paired:
            Label("Paired", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .waiting,
            .unreachable where failures < 3:
            HStack(spacing: 10) {
                ProgressView()
                Text("Waiting for the server to confirm…")
                    .foregroundStyle(.secondary)
            }
        case .unreachable:
            HStack(spacing: 10) {
                ProgressView()
                Text("Unable to connect to the server. Retrying…")
                    .foregroundStyle(.secondary)
            }
        case .wrongCode:
            Label(
                "The code on the server doesn't match. Run the command above again.", systemImage: "exclamationmark.triangle.fill"
            )
            .foregroundStyle(.orange)
        case .unsupported:
            Label("This server doesn't support pairing. Update the server first.", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
    }

    /// Asks the server every two seconds until it has the code.
    private func poll() async {
        while !Task.isCancelled {
            let result = await services.uploader.pair(base: server, code: code, key: key)
            switch result {
            case .paired:
                withAnimation { state = .paired }
                await services.paired(server: server, key: key)
                // A moment to see it worked.
                try? await Task.sleep(for: .seconds(0.8))
                onPaired()
                return
            case .unreachable:
                failures += 1
            default:
                failures = 0
            }
            state = result
            if result == .unsupported { return }
            try? await Task.sleep(for: .seconds(2))
        }
    }
}
