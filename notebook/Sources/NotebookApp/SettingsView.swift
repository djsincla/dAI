import NotebookKit
import SwiftUI

/// Where the fleet is, and the key to reach it.
///
/// Three fields and a test button. The test matters more than it looks: every
/// one of these can be individually correct and collectively wrong, and finding
/// that out on the first question rather than here means blaming the notebook.
struct SettingsView: View {
    @State private var baseURL = GatewaySettings.baseURL
    @State private var caPath = GatewaySettings.caPath
    @State private var model = GatewaySettings.model
    @State private var maxTokens = GatewaySettings.maxTokens
    @State private var appearance = Appearance.current
    @State private var key = Credentials.read() ?? ""
    @State private var result: String?
    @State private var testing = false

    var body: some View {
        Form {
            Section("Fleet") {
                TextField("Gateway", text: $baseURL, prompt: Text("https://host:8452"))
                HStack {
                    TextField("CA certificate", text: $caPath,
                              prompt: Text("the installer prints this path"))
                    Button("Choose…") { choose() }
                }
                TextField("Model", text: $model,
                          prompt: Text("leave empty to let the fleet choose"))
            }
            Section("Appearance") {
                // A segmented picker rather than a toggle, because there are
                // three states and "system" is not a halfway house between the
                // other two: it is a decision to keep following the machine.
                Picker("Theme", selection: $appearance) {
                    ForEach(Appearance.allCases) { option in
                        Label(option.label, systemImage: option.symbol)
                            .tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: appearance) { _, new in Appearance.current = new }
            }
            Section("Answers") {
                // A stepper rather than a text field: this is a number with a
                // sensible range and no reason to allow typing 3 into it.
                Stepper(value: $maxTokens, in: 500 ... 8000, step: 500) {
                    HStack {
                        Text("Longest answer")
                        Spacer()
                        Text("\(maxTokens) tokens")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                Text("Where an answer is cut off if the model has not finished. "
                     + "Nothing streams here, so a longer answer is a longer "
                     + "wait rather than a longer scroll, and a model that "
                     + "finishes early costs nothing extra.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Credential") {
                // Secure, and stored in the Keychain rather than in defaults: a
                // key in a plist is readable by anything running as this user
                // and turns up in backups and screen shares.
                SecureField("API key", text: $key)
                Text("Kept in the Keychain. An operator mints one with "
                     + "POST /admin/v1/auth/keys.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Button("Test Connection") { test() }
                        .disabled(testing)
                    if testing { ProgressView().controlSize(.small) }
                    if let result {
                        Text(result).font(.caption)
                            .foregroundStyle(result.hasPrefix("Reached") ? Palette.ok : Palette.danger)
                    }
                    Spacer()
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .padding()
        .onDisappear(perform: save)
    }

    private func save() {
        GatewaySettings.baseURL = baseURL
        GatewaySettings.caPath = caPath
        GatewaySettings.model = model
        GatewaySettings.maxTokens = maxTokens
        Credentials.write(key)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.message = "Choose the control plane's CA certificate"
        if panel.runModal() == .OK, let url = panel.url { caPath = url.path }
    }

    private func test() {
        save()
        testing = true
        result = nil
        Task {
            guard let url = URL(string: baseURL) else {
                result = "That is not a URL."; testing = false; return
            }
            let gateway = Gateway(
                configuration: .init(baseURL: url,
                                     caCertificatePath: caPath.isEmpty ? nil : caPath),
                credential: { Credentials.read() })
            do {
                // A real request rather than a ping, because reachability and
                // a working credential are different questions and only the
                // second one matters here.
                let answer = try await gateway.answer(
                    question: "Reply with the single word: ready.",
                    passages: [], history: [],
                    model: model.isEmpty ? nil : model, maxTokens: 16)
                result = "Reached \(answer.node ?? "the fleet")"
                    + (answer.model.map { " · \($0)" } ?? "")
            } catch {
                result = "\(error)"
            }
            testing = false
        }
    }
}
