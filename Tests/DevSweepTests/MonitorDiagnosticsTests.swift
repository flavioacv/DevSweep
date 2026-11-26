import XCTest
@testable import DevSweep

final class MonitorDiagnosticsTests: XCTestCase {
    private func sample() -> MonitorSnapshot {
        MonitorSnapshot(system: SystemSnapshot(memUsed: 900, memTotal: 1000, pressure: .normal, diskFree: 500, diskTotal: 1000),
            cpuTicks: [], network: [:], volumes: [VolumeSnapshot(path: "/", total: 1000, free: 500, readOnly: false)],
            processes: [], swap: 0, battery: nil, charging: nil, uptime: 100, load: [], thermal: "", thermalLevel: 0)
    }
    func testMissingOptionalReadingsDoNotClaimHardwareFailure() {
        let report = MonitorDiagnostics.evaluate(sample(), cpu: [0.2], sustainedCPU: false, smart: [:])
        XCTAssertEqual(report.status, .noAlerts)
        XCTAssertTrue(report.findings.isEmpty)
        XCTAssertEqual(report.unavailable, ["gpu", "sensors", "smart"])
        XCTAssertFalse(report.unavailable.contains("battery")) // Desktop without a battery.
    }
    func testUnavailableCoreDataProducesIncompleteNotNormalOrStaleCPUAlert() {
        var snapshot = sample()
        snapshot.system.memoryAvailable = false; snapshot.system.pressureAvailable = false
        snapshot.system.pressure = .critical; snapshot.thermalLevel = nil; snapshot.volumes = []
        for cpu: [Double]? in [nil, [], [Double.nan], [1.1]] {
            let report = MonitorDiagnostics.evaluate(snapshot, cpu: cpu, sustainedCPU: true, smart: [:])
            XCTAssertEqual(report.status, .incomplete); XCTAssertTrue(report.findings.isEmpty)
            for key in ["cpu", "memory", "memory_pressure", "thermal", "volumes"] { XCTAssertTrue(report.unavailable.contains(key)) }
        }
    }
    func testCriticalEvidenceComesFirstAndPreservesSubjects() throws {
        var snapshot = sample()
        snapshot.system.pressure = .critical; snapshot.thermalLevel = 3
        snapshot.volumes = [VolumeSnapshot(path: "/", total: 1000, free: 50, readOnly: false)]
        snapshot.battery = 0.9; snapshot.hardware.battery = BatteryDetails(cycles: 700, capacityRatio: 0.79)
        let report = MonitorDiagnostics.evaluate(snapshot, cpu: [0.95], sustainedCPU: true, smart: ["disk0": "Failing"])
        XCTAssertEqual(report.status, .attention); XCTAssertEqual(report.findings.count, 6)
        XCTAssertEqual(report.findings.prefix(4).map(\.severity), Array(repeating: .critical, count: 4))
        XCTAssertEqual(report.findings.first { $0.kind == .disk }?.value, 0.05)
        XCTAssertEqual(report.findings.first { $0.kind == .smart }?.subject, "disk0")
        TestSupport.useEnglish()
        for finding in report.findings { XCTAssertFalse(finding.message.contains("diagnostics.")) }
        XCTAssertFalse(report.title.contains("diagnostics."))
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any]
        XCTAssertEqual(json?["status"] as? String, "attention")
        let findings = try XCTUnwrap(json?["findings"] as? [[String: Any]])
        XCTAssertEqual(findings.first?["severity"] as? String, "critical")
    }
    func testThresholdBoundariesAndReadOnlyVolumes() {
        var snapshot = sample(); snapshot.system.pressure = .warning; snapshot.thermalLevel = 2
        snapshot.volumes = [VolumeSnapshot(path: "/", total: 1000, free: 100, readOnly: false),
                            VolumeSnapshot(path: "/Volumes/Media", total: 1000, free: 0, readOnly: true)]
        snapshot.battery = 0.5; snapshot.hardware.battery = BatteryDetails(capacityRatio: 0.8)
        let report = MonitorDiagnostics.evaluate(snapshot, cpu: [0.99], sustainedCPU: false, smart: ["disk0": "Verified"])
        XCTAssertEqual(Set(report.findings.map(\.kind)), [.memory, .thermal, .disk])
        XCTAssertTrue(report.findings.allSatisfy { $0.severity == .warning })
        snapshot.volumes = [VolumeSnapshot(path: "/", total: 1000, free: 101, readOnly: false)]
        snapshot.system.pressure = .normal; snapshot.thermalLevel = 1
        XCTAssertTrue(MonitorDiagnostics.evaluate(snapshot, cpu: [0.99], sustainedCPU: false, smart: [:]).findings.isEmpty)
    }
    func testInvalidVolumeAndUnavailableBatteryDoNotBecomeLowSpaceOrDegradedBattery() {
        var snapshot = sample(); snapshot.battery = 0.5
        snapshot.volumes = [VolumeSnapshot(path: "/", total: 0, free: -1, readOnly: false)]
        snapshot.hardware.battery = BatteryDetails(capacityRatio: .nan)
        let report = MonitorDiagnostics.evaluate(snapshot, cpu: [0.3], sustainedCPU: false, smart: ["disk0": "Not Supported"])
        XCTAssertTrue(report.findings.isEmpty); XCTAssertEqual(report.status, .incomplete)
        XCTAssertTrue(report.unavailable.contains("battery")); XCTAssertTrue(report.unavailable.contains("smart"))
        TestSupport.useEnglish()
        for key in report.unavailable + ["cpu", "memory", "memory_pressure", "thermal", "gpu", "sensors"] {
            XCTAssertFalse(MonitorDiagnostics.label(key).contains("diagnostics."))
        }
    }
    func testCPUAlertRequiresContinuousValidSamplesAndKeepsBoundedHistory() {
        let start = Date(timeIntervalSince1970: 1000)
        var tracker = CPULoadHistory()
        for second in stride(from: 0, through: 55, by: 5) { tracker.update([0.95], at: start.addingTimeInterval(Double(second))) }
        XCTAssertFalse(tracker.sustained)
        tracker.update([0.95], at: start.addingTimeInterval(60)); XCTAssertTrue(tracker.sustained)
        tracker.update(nil, at: start.addingTimeInterval(65)); XCTAssertFalse(tracker.sustained)
        tracker.update([0.95], at: start.addingTimeInterval(70)); XCTAssertFalse(tracker.sustained)
        tracker.update([0.95], at: start.addingTimeInterval(100)); XCTAssertEqual(tracker.values.count, 1)
        tracker.update([0.9], at: start.addingTimeInterval(105)); XCTAssertFalse(tracker.sustained)
        for second in stride(from: 110, through: 1000, by: 5) { tracker.update([0.95], at: start.addingTimeInterval(Double(second))) }
        XCTAssertTrue(tracker.sustained); XCTAssertEqual(tracker.values.count, 120)
        tracker.update([.nan], at: start.addingTimeInterval(1005)); XCTAssertFalse(tracker.sustained)
        tracker.update([0.95], at: start); XCTAssertEqual(tracker.values.count, 1)
    }

}
