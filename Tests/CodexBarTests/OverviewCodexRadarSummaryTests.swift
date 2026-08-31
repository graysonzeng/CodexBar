import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct OverviewCodexRadarSummaryTests {
    @Test
    func `projects official labels and Math round integers`() {
        let summary = OverviewCodexRadarSummary(snapshot: Self.snapshot(
            iq: 98.21,
            minutes: 19.82))

        #expect(summary.title == L("Software Engineering"))
        #expect(summary.rows.map(\.displayName) == [
            "Sol xhigh",
            "Sol high",
            "Sol medium",
            "DSV4 Flash max",
            "DSV4 Pro max",
        ])
        #expect(summary.rows.map(\.iq) == [98, 98, 98, 98, 98])
        #expect(summary.rows.map(\.averageMinutes) == [20, 20, 20, 20, 20])
        #expect(summary.rows.map(\.isAvailable) == [true, true, true, true, true])
    }

    @Test
    func `missing slot is unavailable without inventing zero`() {
        let summary = OverviewCodexRadarSummary(
            snapshot: CodexRadarIntelligenceSnapshot(points: [
                CodexRadarIntelligencePoint(target: .gpt56SolXhigh, iq: 100.45, averageMinutes: 24.37),
            ]))

        #expect(summary.rows[0].isAvailable)
        #expect(summary.rows[0].iq == 100)
        #expect(summary.rows[0].averageMinutes == 24)
        for row in summary.rows.dropFirst() {
            #expect(!row.isAvailable)
            #expect(row.iq == nil)
            #expect(row.averageMinutes == nil)
            #expect(row.fingerprintMetrics == "unavailable")
        }
    }

    @Test
    func `round-unrepresentable values do not trap`() {
        #expect(CodexRadarIntelligence.roundedDisplayInt(1e300) == nil)
        let summary = OverviewCodexRadarSummary(
            snapshot: CodexRadarIntelligenceSnapshot(points: [
                CodexRadarIntelligencePoint(target: .gpt56SolXhigh, iq: 1e300, averageMinutes: 24),
                CodexRadarIntelligencePoint(target: .gpt56SolHigh, iq: 98, averageMinutes: 1e300),
            ]))
        #expect(!summary.rows[0].isAvailable)
        #expect(summary.rows[0].iq == nil)
        #expect(summary.rows[0].averageMinutes == nil)
        #expect(!summary.rows[1].isAvailable)
        #expect(summary.rows[2].fingerprintMetrics == "unavailable")
    }

    @Test
    func `visible fingerprint ignores raw doubles that round the same`() {
        let roundedTwenty = OverviewCodexRadarSummary(snapshot: Self.snapshot(iq: 98.21, minutes: 19.82))
        let alsoTwenty = OverviewCodexRadarSummary(snapshot: Self.snapshot(iq: 98.21, minutes: 19.81))
        let roundsToNineteen = OverviewCodexRadarSummary(snapshot: Self.snapshot(iq: 98.21, minutes: 19.4))
        let nilSnapshot = OverviewCodexRadarSummary(snapshot: nil)

        #expect(roundedTwenty.visibleFingerprint == alsoTwenty.visibleFingerprint)
        #expect(roundedTwenty.visibleFingerprint != roundsToNineteen.visibleFingerprint)
        #expect(nilSnapshot.visibleFingerprint == "none")
        #expect(nilSnapshot.rows.isEmpty)
    }

    private static func snapshot(iq: Double, minutes: Double) -> CodexRadarIntelligenceSnapshot {
        CodexRadarIntelligenceSnapshot(
            points: CodexRadarIntelligenceTarget.allCases.map { target in
                CodexRadarIntelligencePoint(target: target, iq: iq, averageMinutes: minutes)
            })
    }
}
