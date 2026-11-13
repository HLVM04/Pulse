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

            Section("T3 Code") {
                LabeledContent("Server", value: T3Server.localOrigin().absoluteString)
                HStack {
                    statusRow(store.t3Status, okText: "Connected, read-only")
                    Spacer()
                    if store.t3Status == .ok || store.t3Status == .loading {
                        Button("Disconnect") { store.disconnectT3() }
                    } else {
                        Button(store.t3Connecting ? "Waiting…" : "Connect…") { store.connectT3() }
                            .disabled(store.t3Connecting)
                    }
                }
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
