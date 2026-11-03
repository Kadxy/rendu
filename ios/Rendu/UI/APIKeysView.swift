import SwiftUI

/// The server's API keys, for other programs: each with its access and
/// when it was last used, and what it did (its activity, a tap away). A key
/// is shown once, when created; deleting one (Edit, or on its page) revokes
/// it at once, after a confirmation.
struct APIKeysView: View {
    let services: AppServices

    @State private var failure: String?
    @State private var creating = false
    @State private var deleting: APIKey?
    /// Edit mode, kept here: the list's own deletion removes the row before
    /// the confirmation, and puts it back if cancelled.
    @State private var editing = false
    @State private var haptic = HapticEvent()

    /// The last list loaded (Settings loads it ahead), shown at once and
    /// refreshed when the page opens.
    private var keys: [APIKey]? { services.server.apiKeys }

    var body: some View {
        List {
            Section {
                Button("Create API Key…") { creating = true }
            }
            Section {
                if let keys {
                    ForEach(keys) { key in
                        HStack(spacing: 12) {
                            if editing {
                                Button {
                                    deleting = key
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .font(.title3)
                                        .symbolRenderingMode(.palette)
                                        .foregroundStyle(.white, .red)
                                }
                                .buttonStyle(.borderless)
                                .transition(.move(edge: .leading).combined(with: .opacity))
                            }
                            NavigationLink {
                                APIKeyDetailView(services: services, key: key) { removed in
                                    services.server.apiKeys?.removeAll { $0.id == removed.id }
                                }
                            } label: {
                                KeyRow(key: key)
                            }
                            .disabled(editing)
                        }
                        // From the row it's for, however it was asked.
                        .deleteKeyConfirmation(
                            Binding(
                                get: { deleting?.id == key.id ? deleting : nil },
                                set: { if $0 == nil, deleting?.id == key.id { deleting = nil } }
                            ), delete: remove
                        )
                        // Not a destructive role: the row stays until confirmed.
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button {
                                deleting = key
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            .tint(.red)
                        }
                    }
                } else if failure == nil {
                    // Loading for the first time.
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                }
            }
        }
        .overlay {
            if keys == nil, let failure {
                ContentUnavailableView {
                    Label("Unable to Connect to Server", systemImage: "exclamationmark.icloud")
                } description: {
                    Text(verbatim: failure)
                } actions: {
                    Button("Try Again") { Task { await load() } }
                }
            }
        }
        .navigationTitle("API Keys")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if keys?.isEmpty == false || editing {
                Button(editing ? "Done" : "Edit") {
                    withAnimation { editing.toggle() }
                }
                .fontWeight(editing ? .semibold : .regular)
            }
        }
        .haptic(haptic)
        .task { await load() }
        .sheet(isPresented: $creating) {
            CreateAPIKeyView(services: services) { key in
                // On the list before the sheet is gone.
                services.server.apiKeys = [key] + (services.server.apiKeys ?? [])
            }
        }
    }

    private func remove(_ key: APIKey) {
        withAnimation {
            services.server.apiKeys?.removeAll { $0.id == key.id }
            if services.server.apiKeys?.isEmpty == true { editing = false }
        }
        Task { await revoke(key) }
    }

    private func load() async {
        do {
            try await services.loadAPIKeys()
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
    }

    /// Already gone from the list; put back (by reloading) if the server
    /// refuses.
    private func revoke(_ key: APIKey) async {
        guard let base = services.settings.baseURL else { return }
        do {
            try await services.uploader.revokeAPIKey(base: base, token: services.settings.key, id: key.id)
        } catch {
            haptic.play(.error)
            await load()
        }
    }
}

extension View {
    /// "Delete “My Personal AI”?", as iOS asks before removing something
    /// that can't come back. Put it on what asks, so it comes from there
    /// (HIG, Action sheets).
    func deleteKeyConfirmation(_ key: Binding<APIKey?>, delete: @escaping (APIKey) -> Void) -> some View {
        confirmationDialog(
            Text("Delete “\(key.wrappedValue?.name ?? "")”?"),
            isPresented: Binding(get: { key.wrappedValue != nil }, set: { if !$0 { key.wrappedValue = nil } }),
            titleVisibility: .visible,
            presenting: key.wrappedValue
        ) { presented in
            Button("Delete Key", role: .destructive) { delete(presented) }
        } message: { _ in
            Text("Programs using this key will lose access immediately.")
        }
    }
}

/// The key's name over when it was last used; its access on the right,
/// where values line up.
private struct KeyRow: View {
    let key: APIKey

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: key.name)
                    .lineLimit(1)
                Group {
                    if let lastUsed = key.lastUsed {
                        Text("Last used \(lastUsed.formatted(.relative(presentation: .named)))")
                    } else {
                        Text("Never used")
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            key.scope.title
                .foregroundStyle(.secondary)
        }
    }
}

/// One key: its access and dates, what it has done (newest first, by day,
/// like the App Privacy Report), and deleting it.
struct APIKeyDetailView: View {
    let services: AppServices
    let key: APIKey
    let onDelete: (APIKey) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var activity: [APIActivity] = []
    @State private var next: String?
    @State private var loading = true
    @State private var failure: String?
    @State private var deleting: APIKey?

    var body: some View {
        let days = Dictionary(grouping: activity) { Calendar.current.startOfDay(for: $0.date ?? .distantPast) }
        List {
            Section {
                LabeledContent("Access") { key.scope.title }
                if let created = key.created {
                    LabeledContent("Created", value: created.formatted(date: .abbreviated, time: .shortened))
                }
                LabeledContent("Last Used") {
                    if let lastUsed = key.lastUsed {
                        Text(lastUsed.formatted(.relative(presentation: .named)))
                    } else {
                        Text("Never")
                    }
                }
            }
            ForEach(days.keys.sorted(by: >), id: \.self) { day in
                Section {
                    ForEach(days[day]!) { entry in
                        ActivityRow(entry: entry)
                    }
                } header: {
                    Text(verbatim: day.dayTitle)
                }
            }
            if activity.isEmpty {
                Section("Activity") {
                    if loading {
                        ProgressView()
                    } else if let failure {
                        Text(verbatim: failure).foregroundStyle(.secondary)
                    } else {
                        Text("No activity yet.").foregroundStyle(.secondary)
                    }
                }
            } else if next != nil {
                Button {
                    Task { await load(more: true) }
                } label: {
                    HStack {
                        Text("Load Earlier Activity")
                        if loading {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(loading)
            }
            Section {
                Button("Delete Key", role: .destructive) { deleting = key }
                    .deleteKeyConfirmation($deleting, delete: revoke)
            }
        }
        .navigationTitle(Text(verbatim: key.name))
        .navigationBarTitleDisplayMode(.inline)
        .task { await load(more: false) }
    }

    private func revoke(_ key: APIKey) {
        Task {
            guard let base = services.settings.baseURL else { return }
            do {
                try await services.uploader.revokeAPIKey(base: base, token: services.settings.key, id: key.id)
                onDelete(key)
                dismiss()
            } catch {
                failure = error.localizedDescription
            }
        }
    }

    private func load(more: Bool) async {
        guard let base = services.settings.baseURL else { return }
        loading = true
        defer { loading = false }
        do {
            let page = try await services.uploader.keyActivity(
                base: base, token: services.settings.key, id: key.id, before: more ? next : nil
            )
            activity = more ? activity + page.activity : page.activity
            next = page.next
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
    }
}

/// "Heart Rate — Read 1,234 samples · Nov 1 – 7", with the type's Health
/// glyph and the time.
private struct ActivityRow: View {
    let entry: APIActivity

    var body: some View {
        HStack(spacing: 12) {
            if let type = entry.type?.split(separator: ",").first {
                CategoryIcon(category: HealthCategory.of(String(type)), size: 18)
            } else {
                Image(systemName: entry.symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 25, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(verbatim: entry.title)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if let date = entry.date {
                        Text(date, format: .dateTime.hour().minute())
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Text(verbatim: entry.detail)
                    .font(.subheadline)
                    .foregroundStyle(entry.refused ? Color.orange : .secondary)
                    .lineLimit(1)
            }
        }
    }
}

extension APIKey.Scope {
    var title: Text {
        switch self {
        case .owner: Text("Owner")
        case .read: Text("Read Only")
        case .readwrite: Text("Read & Write")
        }
    }
}

/// Names a new key and picks its access; then shows the key, once.
private struct CreateAPIKeyView: View {
    let services: AppServices
    /// The new key, for the list behind the sheet.
    let onCreated: (APIKey) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var scope: APIKey.Scope = .read
    @State private var creating = false
    @State private var created: String?
    @State private var failure: String?
    @State private var toast = Toast()
    @State private var haptic = HapticEvent()

    var body: some View {
        NavigationStack {
            Form {
                if let created {
                    Section {
                        Text(verbatim: created)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                        Button {
                            UIPasteboard.general.string = created
                            toast.show("Copied")
                        } label: {
                            Label("Copy Key", systemImage: "doc.on.doc")
                        }
                    } footer: {
                        Text("This key will not be shown again. Copy it now.")
                    }
                } else {
                    Section {
                        TextField("Name", text: $name, prompt: Text("My Personal AI"))
                    }
                    Section {
                        Picker("Access", selection: $scope) {
                            APIKey.Scope.read.title.tag(APIKey.Scope.read)
                            APIKey.Scope.readwrite.title.tag(APIKey.Scope.readwrite)
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    } header: {
                        Text("Access")
                    } footer: {
                        if let failure {
                            Text(verbatim: failure).foregroundStyle(.red)
                        }
                    }
                }
            }
            .navigationTitle(created == nil ? "New API Key" : name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if created == nil {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        if creating {
                            ProgressView()
                        } else {
                            Button("Create") { Task { await create() } }
                                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                } else {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
            }
            .toast($toast)
            .haptic(haptic)
            .interactiveDismissDisabled(created != nil)
        }
    }

    private func create() async {
        guard let base = services.settings.baseURL else { return }
        creating = true
        defer { creating = false }
        do {
            let (apiKey, key) = try await services.uploader.createAPIKey(
                base: base, token: services.settings.key, name: name.trimmingCharacters(in: .whitespaces), scope: scope
            )
            onCreated(apiKey)
            withAnimation { created = key }
            haptic.play(.success)
        } catch {
            failure = error.localizedDescription
            haptic.play(.error)
        }
    }
}
