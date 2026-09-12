import CodexBarCore
import SwiftUI

struct OverviewCodexRadarSummary: Equatable {
    struct Row: Equatable, Identifiable {
        let target: CodexRadarIntelligenceTarget
        let displayName: String
        let iq: Int?
        let averageMinutes: Int?

        var id: CodexRadarIntelligenceTarget {
            self.target
        }

        var isAvailable: Bool {
            self.iq != nil && self.averageMinutes != nil
        }

        var fingerprintMetrics: String {
            if let iq = self.iq, let averageMinutes = self.averageMinutes {
                return "\(iq):\(averageMinutes)"
            }
            return "unavailable"
        }
    }

    let title: String?
    let rows: [Row]
    let visibleFingerprint: String

    init(snapshot: CodexRadarIntelligenceSnapshot?) {
        guard let snapshot else {
            self.title = nil
            self.rows = []
            self.visibleFingerprint = "none"
            return
        }

        let title = Self.updatedTitle(from: snapshot.sourceUpdatedAt)
        self.title = title

        let rows = CodexRadarIntelligenceTarget.allCases.map { target in
            let point = snapshot.point(for: target)
            let iq = point.iq.flatMap(CodexRadarIntelligence.roundedDisplayInt)
            let averageMinutes = point.averageMinutes.flatMap(CodexRadarIntelligence.roundedDisplayInt)
            let isAvailable = iq != nil && averageMinutes != nil
            return Row(
                target: target,
                displayName: Self.officialLabel(for: target),
                iq: isAvailable ? iq : nil,
                averageMinutes: isAvailable ? averageMinutes : nil)
        }
        self.rows = rows
        self.visibleFingerprint = ([title ?? "none"] + rows.map { "\($0.displayName):\($0.fingerprintMetrics)" })
            .joined(separator: "|")
    }

    private static func updatedTitle(from sourceUpdatedAt: Date?) -> String? {
        guard let sourceUpdatedAt else { return nil }
        let formatter = DateFormatter()
        formatter.locale = codexBarLocalizedLocale()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return L("Updated absolute %@", formatter.string(from: sourceUpdatedAt))
    }

    static func officialLabel(for target: CodexRadarIntelligenceTarget) -> String {
        switch target {
        case .gpt56SolXhigh: "Sol xhigh"
        case .gpt56SolHigh: "Sol high"
        case .gpt56SolMedium: "Sol medium"
        case .deepseekV4FlashMax: "DSV4 Flash max"
        case .deepseekV4ProMax: "DSV4 Pro max"
        }
    }
}

struct OverviewCodexRadarCardView: View {
    let summary: OverviewCodexRadarSummary
    let width: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let title = self.summary.title {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(self.summary.rows) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(row.displayName)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        if row.isAvailable, let iq = row.iq, let averageMinutes = row.averageMinutes {
                            Text("\(iq) \(L("IQ"))")
                                .monospacedDigit()
                            Text(L("%d min", averageMinutes))
                                .monospacedDigit()
                        } else {
                            Text(L("Unavailable"))
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, UsageMenuCardLayout.horizontalPadding)
        .padding(.vertical, 10)
        .frame(width: self.width, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.accentColor.opacity(0.08))
                .padding(.horizontal, 6)
        }
    }
}
