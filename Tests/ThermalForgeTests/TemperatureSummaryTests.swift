import Testing

@testable import ThermalForgeCore

@Suite("Temperature summary")
struct TemperatureSummaryTests {
    @Test("Classifies sensor families and selects their peaks")
    func classifiesFamilies() {
        let summary = TemperatureSummary([
            "TC0P": 61,
            "Tp01": 64,
            "TG0B": 58,
            "Tg05": 60,
            "TRDX": 45,
            "Tm02": 47,
            "TH0x": 42,
            "TAOL": 31,
            "TB0T": 36,
        ])

        #expect(summary.cpu == 64)
        #expect(summary.gpu == 60)
        #expect(summary.ram == 47)
        #expect(summary.ssd == 42)
        #expect(summary.ambient == 31)
        #expect(summary.controlPeak == 64)
    }

    @Test("Missing sensor families remain absent")
    func missingFamilies() {
        let summary = TemperatureSummary(["TAOL": 30])

        #expect(summary.cpu == nil)
        #expect(summary.gpu == nil)
        #expect(summary.controlPeak == nil)
    }
}
