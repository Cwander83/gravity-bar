import SwiftUI

/// Preferences and configuration view for GravityBar.
@MainActor
public struct SettingsView: View {
    @ObservedObject var manager: UsageManager

    public init(manager: UsageManager) {
        self.manager = manager
    }

    public init() {
        self.manager = .shared
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Button(action: { dismiss() }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                Text("Preferences & Providers")
                    .font(.system(size: 14, weight: .bold))
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                        .font(.system(size: 16))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.8))

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    // 1. Polling Interval
                    VStack(alignment: .leading, spacing: 8) {
                        Text("BACKGROUND POLLING INTERVAL")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.secondary)

                        Picker("", selection: $manager.pollingIntervalSeconds) {
                            Text("30s").tag(TimeInterval(30))
                            Text("1m").tag(TimeInterval(60))
                            Text("5m").tag(TimeInterval(300))
                        }
                        .pickerStyle(.segmented)
                    }

                    // 2. Active Providers
                    VStack(alignment: .leading, spacing: 8) {
                        Text("ACTIVE PROVIDERS (MACHINE PROFILE)")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.secondary)

                        VStack(spacing: 6) {
                            providerToggleRow(
                                title: "Claude",
                                subtitle: "5-hour and weekly usage",
                                isEnabled: manager.enabledProviders.contains(.claude)
                            ) {
                                manager.toggleProvider(.claude)
                            }

                            providerToggleRow(
                                title: "Codex / ChatGPT",
                                subtitle: "Codex CLI rate limits, tokens, ChatGPT app",
                                isEnabled: manager.enabledProviders.contains(.codex)
                            ) {
                                manager.toggleProvider(.codex)
                            }

                            providerToggleRow(
                                title: "Antigravity / Gemini",
                                subtitle: "Session RPM and quota limits",
                                isEnabled: manager.enabledProviders.contains(.gemini)
                            ) {
                                manager.toggleProvider(.gemini)
                            }

                            providerToggleRow(
                                title: "Ollama / Llama",
                                subtitle: "Local and cloud models via Ollama",
                                isEnabled: manager.enabledProviders.contains(.ollama)
                            ) {
                                manager.toggleProvider(.ollama)
                            }
                        }
                    }

                    // 3. File Paths
                    VStack(alignment: .leading, spacing: 8) {
                        Text("LOCAL STATE & CACHE PATHS")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.secondary)

                        VStack(spacing: 8) {
                            pathInputField(label: "Claude Plan Usage History", text: $manager.claudePath, defaultPath: ProviderPaths.claudeDefault)
                            pathInputField(label: "Codex Sessions", text: $manager.codexPath, defaultPath: ProviderPaths.codexDefault)
                            pathInputField(label: "Gemini Cache", text: $manager.geminiPath, defaultPath: ProviderPaths.geminiDefault)
                        }
                    }

                    // 4. Feature Toggles
                    VStack(alignment: .leading, spacing: 8) {
                        Text("BEHAVIOR")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.secondary)

                        VStack(spacing: 8) {
                            Toggle(isOn: $manager.isMockMode) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Mock Provider Mode")
                                        .font(.system(size: 12, weight: .medium))
                                    Text("Simulates quotas without live account credentials")
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                }
                            }
                            .toggleStyle(.switch)

                            Toggle(isOn: $manager.showOfflineProviders) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Show Offline Providers")
                                        .font(.system(size: 12, weight: .medium))
                                    Text("Also list providers that are not installed or not running")
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                }
                            }
                            .toggleStyle(.switch)

                            Toggle(isOn: $manager.hoverToOpen) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Hover to Open Popover")
                                        .font(.system(size: 12, weight: .medium))
                                    Text("Automatically reveals popover when mouse hovers menu bar item")
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                }
                            }
                            .toggleStyle(.switch)
                        }
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                        )
                    }

                    // Apply Button
                    Button(action: {
                        dismiss(forceRefresh: true)
                    }) {
                        Text("Apply & Close")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(GravityBarTokens.colorAccent)
                            .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 6)

                    Button(action: { NSApp.terminate(nil) }) {
                        Label("Quit GravityBar", systemImage: "power")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut("q", modifiers: .command)
                }
                .padding(16)
            }
        }
        .frame(width: GravityBarTokens.popoverWidth, height: 460)
    }

    /// Returns to the readout inside the popover.
    public func dismiss(forceRefresh: Bool = false) {
        manager.dismissSettings(forceRefresh: forceRefresh)
    }

    private func providerToggleRow(title: String, subtitle: String, isEnabled: Bool, onToggle: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { isEnabled },
                set: { _ in onToggle() }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        )
    }

    private func pathInputField(label: String, text: Binding<String>, defaultPath: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                Spacer()
                if text.wrappedValue != defaultPath {
                    Button("Reset to Default") { text.wrappedValue = defaultPath }
                        .buttonStyle(.plain)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(GravityBarTokens.colorAccent)
                }
            }
            // An empty field falls back to the default path when providers read it
            TextField(defaultPath, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
        }
    }
}
