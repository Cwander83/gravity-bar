import SwiftUI

/// Component displaying a single provider card with 5-hour and weekly quota meters.
public struct UsageMetricRowView: View {
    public let usage: ProviderUsage

    public init(usage: ProviderUsage) {
        self.usage = usage
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Provider Header
            HStack(spacing: 8) {
                providerIcon
                Text(usage.provider.displayName)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.primary)
                if let badge = usage.planBadge {
                    Text(badge.uppercased())
                        .font(.system(size: 8, weight: .black))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.white.opacity(0.08))
                        .foregroundColor(.secondary)
                        .cornerRadius(4)
                }
                Spacer()
                if let status = usage.connectionState.label() {
                    connectionStatusView(status)
                }
            }

            if usage.groups.isEmpty {
                // 5-Hour Window Meter
                if let fiveHour = usage.fiveHourMetric {
                    windowMeterView(metric: fiveHour)
                }

                // Weekly Window Meter
                if let weekly = usage.weeklyMetric {
                    windowMeterView(metric: weekly)
                }
            } else {
                // Per-group meters (e.g. Gemini Models, Gemini 4 Argon, Claude and GPT models)
                ForEach(usage.groups) { group in
                    groupSectionView(group: group)
                }
            }

            if !usage.models.isEmpty {
                modelsView(usage.models)
            }

            if let cli = usage.cliTokenUsage {
                cliTokenUsageView(cli)
            }

            if usage.allMetrics.isEmpty, usage.models.isEmpty, usage.cliTokenUsage == nil {
                Text(usage.connectionState.isDetected ? "No usage reported yet" : "No local data found on this Mac")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
        .opacity(usage.connectionState.isDetected ? 1 : 0.6)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: GravityBarTokens.cardCornerRadius)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: GravityBarTokens.cardCornerRadius)
                .stroke(Color.white.opacity(0.09), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var providerIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(iconBackground)
                .frame(width: 22, height: 22)

            switch usage.provider {
            case .claude:
                Text("C")
                    .font(.system(size: 11, weight: .black))
                    .foregroundColor(.white)
            case .codex:
                Image(systemName: "bolt.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white)
            case .gemini:
                Image(systemName: "sparkles")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white)
            case .ollama:
                Image(systemName: "cpu")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white)
            }
        }
    }

    private var iconBackground: AnyShapeStyle {
        switch usage.provider {
        case .claude:
            return AnyShapeStyle(Color(red: 0.85, green: 0.47, blue: 0.02))
        case .codex:
            return AnyShapeStyle(LinearGradient(
                colors: [Color(red: 0.06, green: 0.64, blue: 0.50), Color(red: 0.02, green: 0.59, blue: 0.41)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ))
        case .gemini:
            return AnyShapeStyle(LinearGradient(
                colors: [Color.blue, Color.purple],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ))
        case .ollama:
            return AnyShapeStyle(Color(white: 0.35))
        }
    }

    private func connectionStatusView(_ status: String) -> some View {
        let isError: Bool
        if case .error = usage.connectionState { isError = true } else { isError = false }

        return HStack(spacing: 4) {
            Circle()
                .fill(isError ? GravityBarTokens.colorCritical : Color.secondary)
                .frame(width: 5, height: 5)
            Text(status)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
    }

    private func modelsView(_ models: [ActiveModel]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("MODELS")
                .font(.system(size: 9, weight: .black))
                .foregroundColor(.secondary)

            ForEach(models) { model in
                HStack(spacing: 6) {
                    Circle()
                        .fill(model.isRunning ? GravityBarTokens.colorNormal : Color.secondary.opacity(0.5))
                        .frame(width: 6, height: 6)
                    Text(model.name)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    Spacer()
                    if let detail = model.detail {
                        Text(detail)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    private func cliTokenUsageView(_ cli: CLITokenUsage) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(usage.provider == .codex ? "CODEX CLI" : "CLAUDE CODE CLI")
                .font(.system(size: 9, weight: .black))
                .foregroundColor(.secondary)

            tokenRow(label: "Last 5h", usage: cli.last5h)
            tokenRow(label: "Last 7d", usage: cli.last7d)
        }
    }

    private func tokenRow(label: String, usage: TokenUsage) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
            Spacer()
            Text(usage.summary)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(.primary)
        }
    }

    private func groupSectionView(group: QuotaGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(group.name.uppercased())
                .font(.system(size: 9, weight: .black))
                .foregroundColor(.secondary)

            ForEach(group.metrics) { metric in
                windowMeterView(metric: metric)
            }
        }
    }

    private func windowMeterView(metric: UsageMetric) -> some View {
        let statusColor = GravityBarTokens.colorFor(threshold: metric.threshold)

        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(metric.windowType.rawValue)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                Spacer()
                Text(metric.usageSummary)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(statusColor)
            }

            // Linear Progress Track
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.08))
                        .frame(height: GravityBarTokens.progressBarHeight)

                    Capsule()
                        .fill(statusColor)
                        .frame(
                            width: metric.usedPercent <= 0 ? 0 : max(4, geometry.size.width * CGFloat(metric.usedPercent / 100.0)),
                            height: GravityBarTokens.progressBarHeight
                        )
                        .shadow(color: statusColor.opacity(0.35), radius: 4, x: 0, y: 0)
                }
            }
            .frame(height: GravityBarTokens.progressBarHeight)

            // Reset Countdown Footer
            HStack(spacing: 4) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 9))
                Text(metric.formattedReset())
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundColor(.secondary)
        }
    }
}
