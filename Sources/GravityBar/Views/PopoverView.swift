import SwiftUI
import AppKit

/// Main popover view presenting overall consumption status, provider meters, and settings access.
@MainActor
public struct PopoverView: View {
    @ObservedObject var manager: UsageManager

    public init(manager: UsageManager) {
        self.manager = manager
    }

    public init() {
        self.manager = .shared
    }

    public var body: some View {
        // Settings slides in inside the popover (as in mockup/index.html) instead of a modal sheet
        // that would overflow the transient popover.
        ZStack {
            if manager.showingSettings {
                SettingsView(manager: manager)
                    .transition(.move(edge: .trailing))
            } else {
                readoutView
                    .transition(.move(edge: .leading))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: manager.showingSettings)
        .frame(width: GravityBarTokens.popoverWidth)
        .clipped()
        .background(VisualEffectView(material: .popover, blendingMode: .behindWindow))
    }

    private var readoutView: some View {
        VStack(spacing: 0) {
            // Header
            headerView

            Divider()

            // Urgency Summary Banner
            healthSummaryBanner

            // Provider Cards Scrollable Body
            ScrollView {
                VStack(spacing: 10) {
                    if manager.activeUsages.isEmpty {
                        emptyStateView
                    } else {
                        ForEach(manager.activeUsages) { usage in
                            UsageMetricRowView(usage: usage)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
            .frame(maxHeight: 380)

            Divider()

            // Footer
            footerView
        }
    }

    // MARK: - Subviews

    private var headerView: some View {
        HStack(spacing: 10) {
            // App Brand
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(GravityBarTokens.colorAccent)
                        .frame(width: 28, height: 28)
                        .shadow(color: GravityBarTokens.colorAccent.opacity(0.35), radius: 6)

                    Image(systemName: "gauge.with.needle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.white)
                }

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text("GravityBar")
                            .font(.system(size: 14, weight: .bold))

                        Text(manager.isMockMode ? "MOCK" : "LIVE")
                            .font(.system(size: 9, weight: .black))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(
                                manager.isMockMode
                                ? Color.secondary.opacity(0.2)
                                : GravityBarTokens.colorNormal.opacity(0.2)
                            )
                            .foregroundColor(
                                manager.isMockMode
                                ? .secondary
                                : GravityBarTokens.colorNormal
                            )
                            .cornerRadius(4)
                    }

                    Text(lastUpdatedString)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            // Header Actions
            HStack(spacing: 4) {
                // Refresh Button
                Button(action: {
                    withAnimation(.linear(duration: 0.7)) {
                        manager.isSpinning = true
                    }
                    Task {
                        await manager.refreshAll()
                        try? await Task.sleep(nanoseconds: 700_000_000)
                        manager.isSpinning = false
                    }
                }) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.secondary)
                        .rotationEffect(.degrees(manager.isSpinning ? 360 : 0))
                        .frame(width: 26, height: 26)
                        .background(GravityBarTokens.buttonBackground)
                        .cornerRadius(6)
                }
                .buttonStyle(.plain)

                // Preferences Gear
                Button(action: { manager.showingSettings = true }) {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 26, height: 26)
                        .background(GravityBarTokens.buttonBackground)
                        .cornerRadius(6)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var healthSummaryBanner: some View {
        let maxPercent = manager.maxUrgencyPercent
        let statusColor = GravityBarTokens.colorFor(threshold: manager.highestUrgency)

        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("OVERALL STATUS")
                    .font(.system(size: 9, weight: .black))
                    .foregroundColor(.secondary)

                Text(manager.overallStatusText)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.primary)

                HStack(spacing: 4) {
                    Image(systemName: "clock.fill")
                        .font(.system(size: 9))
                    Text("Next reset: \(manager.nextResetCountdownText)")
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundColor(.secondary)
            }

            Spacer()

            // Circular Progress Indicator
            ZStack {
                Circle()
                    .stroke(GravityBarTokens.circularGaugeTrack, lineWidth: 4)
                    .frame(width: 42, height: 42)

                Circle()
                    .trim(from: 0, to: CGFloat(maxPercent / 100.0))
                    .stroke(
                        statusColor,
                        style: StrokeStyle(lineWidth: 4, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .frame(width: 42, height: 42)
                    .shadow(color: statusColor.opacity(0.35), radius: 3)

                Text("\(Int(round(maxPercent)))%")
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .foregroundColor(.primary)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: GravityBarTokens.cardCornerRadius)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.7))
        )
        .overlay(
            RoundedRectangle(cornerRadius: GravityBarTokens.cardCornerRadius)
                .stroke(GravityBarTokens.cardBorder, lineWidth: 1)
        )
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    private var emptyStateView: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 24))
                .foregroundColor(.secondary)
            Text("No Active Providers")
                .font(.system(size: 13, weight: .semibold))
            Text(manager.showOfflineProviders
                 ? "Enable providers in Preferences to track quotas"
                 : "No AI tools detected on this Mac. Turn on Show Offline Providers to see all.")
                .multilineTextAlignment(.center)
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            Button("Open Preferences") {
                manager.showingSettings = true
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    private var footerView: some View {
        HStack {
            // Dashboard Links
            HStack(spacing: 10) {
                linkButton(title: "Claude ↗", urlString: "https://claude.ai")
                linkButton(title: "Codex ↗", urlString: "https://platform.openai.com/usage")
                linkButton(title: "Gemini ↗", urlString: "https://aistudio.google.com")
            }

            Spacer()

            // Polling interval info
            HStack(spacing: 4) {
                Circle()
                    .fill(GravityBarTokens.colorNormal)
                    .frame(width: 6, height: 6)
                Text("\(Int(manager.pollingIntervalSeconds))s")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
            }

            // Quit (also reachable via right-click menu); ⌘Q works while the popover has focus
            Button(action: { NSApp.terminate(nil) }) {
                Image(systemName: "power")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("q", modifiers: .command)
            .help("Quit GravityBar (⌘Q)")
            .padding(.leading, 6)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func linkButton(title: String, urlString: String) -> some View {
        Button(action: {
            if let url = URL(string: urlString) {
                NSWorkspace.shared.open(url)
            }
        }) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)
        }
        .buttonStyle(.plain)
    }

    private var lastUpdatedString: String {
        guard let last = manager.lastUpdated else {
            return "Updating..."
        }
        let diff = Int(Date().timeIntervalSince(last))
        if diff < 5 {
            return "Updated just now"
        } else if diff < 60 {
            return "Updated \(diff)s ago"
        } else {
            return "Updated \(diff / 60)m ago"
        }
    }
}

/// Helper view providing vibrant native macOS backdrop blur.
public struct VisualEffectView: NSViewRepresentable {
    public let material: NSVisualEffectView.Material
    public let blendingMode: NSVisualEffectView.BlendingMode

    public init(
        material: NSVisualEffectView.Material = .popover,
        blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    ) {
        self.material = material
        self.blendingMode = blendingMode
    }

    public func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    public func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}
