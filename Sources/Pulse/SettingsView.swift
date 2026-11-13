import PulseCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppStore.self) private var store
    @State private var keyDraft = ""
    @State private var keySaved = false

    var body: some View {
        @Bindable var store = store
        Form {
            Section("CLIProxyAPI") {
                TextField("Address", text: $store.cliproxyURL, prompt: Text("https://host:8317"))
                    .textContentType(.URL)
                    .onSubmit { Task { await store.refreshQuota() } }
                HStack {
                    SecureField(
                        "Management key",
                        text: $keyDraft,
                        prompt: Text(store.hasCLIProxyKey ? "Saved in Keychain" : "Paste the management key")
                    )
                    Button(keySaved ? "Saved" : "Save") {
                        store.saveCLIProxyKey(keyDraft)
                        keyDraft = ""
                        keySaved = true
                    }
                    .disabled(keyDraft.isEmpty)
                }
                statusRow(store.quotaStatus, okText: "Connected")
            }

            Section {
                ForEach(store.t3Servers) { T3ServerRow(server: $0) }
                AddT3ServerRow()
            } header: {
                Text("T3 Code")
            } footer: {
                Text("Add other machines running T3 Code, like a VPS on your tailnet. Each one signs in separately with read-only access.")
                    .foregroundStyle(.secondary)
            }

            Section("Forecast") {
                Picker("Burn rate from the last", selection: $store.burnWindowHours) {
                    ForEach([1, 3, 6, 24], id: \.self) { Text("\($0) hour\($0 == 1 ? "" : "s")").tag($0) }
                }
            }

            Section("Notifications") {
                Toggle("A thread is waiting for you", isOn: $store.notifyWaiting)
                Toggle("A thread finishes", isOn: $store.notifyFinished)
                Toggle("The quota pool runs low", isOn: $store.notifyLowPool)
                LabeledContent("Low below") {
                    HStack {
                        Slider(value: $store.lowThreshold, in: 0.05...0.5, step: 0.05)
                        Text("\(Int((store.lowThreshold * 100).rounded()))% of the pool")
                            .monospacedDigit().foregroundStyle(.secondary).frame(width: 110, alignment: .trailing)
                    }
                }
            }

            Section {
                Toggle("Open at login", isOn: $store.launchAtLogin)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: keyDraft) { keySaved = false }
    }

    @ViewBuilder private func statusRow(_ status: SourceStatus, okText: String) -> some View {
        switch status {
        case .ok: Label(okText, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .loading: Label("Connecting…", systemImage: "circle.dotted").foregroundStyle(.secondary)
        case .notConfigured: Label("Not set up", systemImage: "circle").foregroundStyle(.secondary)
        case .expired: Label("Sign-in expired", systemImage: "exclamationmark.circle.fill").foregroundStyle(.orange)
        case .error(let message): Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }
}

private struct T3ServerRow: View {
    @Environment(AppStore.self) private var store
    let server: T3ServerConfig
    @State private var name = ""

    var body: some View {
        let status = store.status(of: server)
        HStack(spacing: 10) {
            Image(systemName: server.isThisMac ? "laptopcomputer" : "server.rack")
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                if server.isThisMac {
                    Text("This Mac")
                } else {
                    TextField("Name", text: $name)
                        .textFieldStyle(.plain)
                        .onSubmit { store.renameT3Server(server.id, to: name) }
                        .onDisappear { store.renameT3Server(server.id, to: name) }
                }
                Text(server.origin.absoluteString).font(.caption).foregroundStyle(.tertiary)
                statusLabel(status).font(.caption)
            }
            Spacer()
            if status == .ok || status == .loading {
                Button("Disconnect") { store.disconnectT3(server.id) }
            } else {
                Button(store.t3ConnectingId == server.id ? "Waiting…" : status == .expired ? "Sign In Again" : "Connect…") {
                    store.connectT3(server.id)
                }
                .disabled(store.t3Connecting)
            }
            if !server.isThisMac {
                Button {
                    store.removeT3Server(server.id)
                } label: {
                    Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
                .help("Remove \(server.name)")
            }
        }
        .onAppear { name = server.name }
    }

    @ViewBuilder private func statusLabel(_ status: SourceStatus) -> some View {
        switch status {
        case .ok: Label("Connected, read-only", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .loading: Label("Connecting…", systemImage: "circle.dotted").foregroundStyle(.secondary)
        case .notConfigured: Label("Not connected", systemImage: "circle").foregroundStyle(.secondary)
        case .expired: Label("Sign-in expired", systemImage: "exclamationmark.circle.fill").foregroundStyle(.orange)
        case .error(let message): Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }
}

private struct AddT3ServerRow: View {
    @Environment(AppStore.self) private var store
    @State private var address = ""
    @State private var adding = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                TextField("Add a server", text: $address, prompt: Text("100.64.0.1 or https://host"))
                    .onSubmit(add)
                Button(adding ? "Adding…" : "Add", action: add)
                    .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty || adding || store.t3Connecting)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
        }
        .onChange(of: address) { error = nil }
    }

    private func add() {
        guard !adding else { return }
        adding = true
        Task {
            defer { adding = false }
            do {
                try await store.addT3Server(address: address)
                address = ""
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
