import SwiftUI
import ServiceManagement
import StatusBarCore

struct SettingsView: View {
    let appState: AppState
    @Bindable var settings: SettingsStore

    var body: some View {
        TabView {
            GeneralTab(appState: appState, settings: settings)
                .tabItem { Label("General", systemImage: "gearshape") }
            ThresholdsTab(settings: settings)
                .tabItem { Label("Thresholds", systemImage: "gauge") }
            AccountsTab(appState: appState, settings: settings)
                .tabItem { Label("Accounts", systemImage: "person.2") }
            ClaudeCodeTab()
                .tabItem { Label("Claude Code", systemImage: "terminal") }
        }
        .frame(width: 440)
        .padding(.bottom, 8)
    }
}

private struct GeneralTab: View {
    let appState: AppState
    @Bindable var settings: SettingsStore
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, enabled in
                    do {
                        if enabled { try SMAppService.mainApp.register() }
                        else { try SMAppService.mainApp.unregister() }
                    } catch {
                        // Fails under `swift run` — SMAppService needs an installed bundle.
                        loginError = error.localizedDescription
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }
            Toggle("Show usage on menu bar", isOn: $settings.showUsageOnBar)
            Picker("Display style", selection: $settings.displayStyle) {
                Text("Icon only").tag(DisplayStyle.iconOnly)
                Text("Icon + %").tag(DisplayStyle.percent)
                Text("Full").tag(DisplayStyle.full)
            }
            Picker("Message style", selection: $settings.messageStyleId) {
                ForEach(MessageStyles.all) { style in
                    Text(style.name).tag(style.id)
                }
            }
            .onChange(of: settings.messageStyleId) {
                // Instant feedback: a bar currently in .thinking re-renders
                // now; tool/waiting text re-themes on the next TimelineView
                // tick (≤1 s).
                appState.rerollThinkingPhrase()
            }
            Picker("Usage poll interval", selection: $settings.pollMinutes) {
                Text("1 min").tag(1)
                Text("5 min").tag(5)
                Text("15 min").tag(15)
            }
        }
        .padding(20)
        .alert("Launch at login failed", isPresented: .constant(loginError != nil)) {
            Button("OK") { loginError = nil }
        } message: {
            Text(loginError ?? "")
        }
    }
}

private struct ThresholdsTab: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        Form {
            Slider(value: $settings.yellowAt, in: 10...90, step: 5) {
                Text("Yellow from \(Int(settings.yellowAt))%")
            }
            Slider(value: $settings.redAt, in: 20...100, step: 5) {
                Text("Red from \(Int(settings.redAt))%")
            }
            if settings.redAt <= settings.yellowAt {
                Text("Red threshold should be above yellow")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(20)
    }
}

private struct AccountsTab: View {
    let appState: AppState
    @Bindable var settings: SettingsStore

    var body: some View {
        Form {
            if appState.accounts.isEmpty {
                Text("No Claude account found").foregroundStyle(.secondary)
            }
            ForEach(appState.accounts) { account in
                Toggle(title(for: account), isOn: binding(for: account.id))
            }
        }
        .padding(20)
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(
            get: { !settings.hiddenAccounts.contains(id) },
            set: { visible in
                if visible {
                    settings.hiddenAccounts.removeAll { $0 == id }
                } else if !settings.hiddenAccounts.contains(id) {
                    settings.hiddenAccounts.append(id)
                }
            })
    }

    private func title(for account: Account) -> String {
        switch (account.alias, account.email) {
        case let (alias?, email?): return "\(alias) — \(email)"
        case let (alias?, nil): return alias
        case let (nil, email?): return email
        default: return account.id
        }
    }
}

private struct ClaudeCodeTab: View {
    @State private var installed: Bool?
    @State private var errorMessage: String?

    private var installer: HookInstaller {
        HookInstaller(settingsFile: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json"))
    }
    private var binary: URL? { defaultHookBinary(appExecutable: Bundle.main.executableURL) }

    var body: some View {
        Form {
            LabeledContent("Hook status") {
                switch installed {
                case true: Text("Installed").foregroundStyle(.green)
                case false: Text("Not installed").foregroundStyle(.secondary)
                default: Text("Unknown").foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("Install") { mutate { try $0.install(binaryPath: $1) } }
                    .disabled(installed == true)
                Button("Remove") { mutate { installer, _ in try installer.uninstall() } }
                    .disabled(installed != true)
            }
            Text("Adds claude-status-hook entries to ~/.claude/settings.json "
                 + "(a timestamped backup is written first).")
                .font(.caption).foregroundStyle(.secondary)
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(20)
        .onAppear(perform: refresh)
    }

    private func refresh() {
        guard let binary else { installed = nil; return }
        installed = try? installer.status(binaryPath: binary.path)
    }

    private func mutate(_ action: (HookInstaller, String) throws -> Void) {
        guard let binary else {
            errorMessage = "Hook binary not found next to the app executable."
            return
        }
        do {
            try action(installer, binary.path)
            errorMessage = nil
        } catch {
            errorMessage = "Could not update settings.json: \(error.localizedDescription)"
        }
        refresh()
    }
}
