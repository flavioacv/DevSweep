import Foundation

struct MonitorFinding: Codable, Identifiable, Sendable {
    enum Severity: String, Codable, Sendable { case warning, critical }
    enum Kind: String, Codable, Sendable { case cpu, memory, thermal, disk, smart, battery }
    let id: String
    let kind: Kind
    let severity: Severity
    let subject: String?
    let value: Double?

    var message: String {
        switch kind {
        case .cpu: tr("diagnostics.cpu")
        case .memory: tr("diagnostics.memory")
        case .thermal: tr("diagnostics.thermal")
        case .disk: tr("diagnostics.disk", ["path": subject ?? "", "percent": Int((value ?? 0) * 100)])
        case .smart: tr("diagnostics.smart", ["disk": subject ?? ""])
        case .battery: tr("diagnostics.battery", ["percent": Int((value ?? 0) * 100)])
        }
    }
}

struct MonitorDiagnostics: Codable, Sendable {
    enum Status: String, Codable, Sendable { case attention, incomplete, noAlerts }
    var status: Status
    var findings: [MonitorFinding]
    var unavailable: [String]

    var title: String {
        switch status {
        case .attention: tr("diagnostics.attention")
        case .incomplete: tr("diagnostics.incomplete")
        case .noAlerts: tr("diagnostics.no_alerts")
        }
    }

    /// Thresholds describe observations, not a hardware health score or a repair recommendation.
    static func evaluate(_ snapshot: MonitorSnapshot, cpu: [Double]?, sustainedCPU: Bool, smart: [String: String]) -> Self {
        var findings: [MonitorFinding] = []
        var unavailable: [String] = []
        func add(_ kind: MonitorFinding.Kind, _ severity: MonitorFinding.Severity, subject: String? = nil, value: Double? = nil) {
            findings.append(MonitorFinding(id: kind.rawValue + ":" + (subject ?? ""), kind: kind, severity: severity, subject: subject, value: value))
        }
        let cpuOK = cpu.map { !$0.isEmpty && $0.allSatisfy { $0.isFinite && (0...1).contains($0) } } ?? false
        if !cpuOK { unavailable.append("cpu") }
        if cpuOK && sustainedCPU { add(.cpu, .warning) }
        if !snapshot.system.memoryAvailable || snapshot.system.memTotal <= 0 { unavailable.append("memory") }
        if !snapshot.system.pressureAvailable { unavailable.append("memory_pressure") }
        else if snapshot.system.pressure != .normal {
            add(.memory, snapshot.system.pressure == .critical ? .critical : .warning)
        }
        if let level = snapshot.thermalLevel, (0...3).contains(level) {
            if level >= 2 { add(.thermal, level == 3 ? .critical : .warning) }
        } else { unavailable.append("thermal") }
        if snapshot.volumes.isEmpty { unavailable.append("volumes") }
        for volume in snapshot.volumes where !volume.readOnly {
            guard volume.total > 0, volume.free >= 0, volume.free <= volume.total else { unavailable.append("volumes"); continue }
            let fraction = Double(volume.free) / Double(volume.total)
            if fraction <= 0.10 { add(.disk, fraction <= 0.05 ? .critical : .warning, subject: volume.path, value: fraction) }
        }
        for disk in smart.keys.sorted() where smart[disk]?.lowercased() == "failing" { add(.smart, .critical, subject: disk) }
        if smart.isEmpty || smart.values.contains(where: { !["verified", "failing"].contains($0.lowercased()) }) { unavailable.append("smart") }
        if snapshot.battery != nil {
            if let ratio = snapshot.hardware.battery?.capacityRatio, ratio.isFinite, ratio > 0 {
                if ratio < 0.8 { add(.battery, .warning, value: ratio) }
            } else { unavailable.append("battery") }
        }
        if snapshot.hardware.gpus.isEmpty || snapshot.hardware.gpus.contains(where: { $0.utilization == nil }) { unavailable.append("gpu") }
        if snapshot.hardware.sensors.isEmpty { unavailable.append("sensors") }
        let coreMissing = unavailable.contains { ["cpu", "memory", "memory_pressure", "thermal", "volumes"].contains($0) }
        return Self(status: !findings.isEmpty ? .attention : (coreMissing ? .incomplete : .noAlerts),
                    findings: findings.sorted { $0.severity != $1.severity ? $0.severity == .critical : $0.id < $1.id },
                    unavailable: Array(Set(unavailable)).sorted())
    }

    static func label(_ metric: String) -> String {
        switch metric {
        case "cpu": "CPU"
        case "memory": tr("general.memory")
        case "memory_pressure": tr("diagnostics.pressure_label")
        case "thermal": tr("diagnostics.thermal_label")
        case "volumes": tr("general.volumes")
        case "smart": "SMART"
        case "battery": tr("general.battery")
        case "gpu": "GPU"
        default: tr("hardware.sensors")
        }
    }
}

/// Session continuity is based on successful samples, never on a stale last reading.
struct CPULoadHistory {
    private(set) var values: [Double] = []
    private(set) var sustained = false
    private var highSince: Date?
    private var lastDate: Date?

    mutating func update(_ fractions: [Double]?, at date: Date) {
        if let lastDate, date <= lastDate || date.timeIntervalSince(lastDate) > 15 {
            highSince = nil; sustained = false; values = []
        }
        lastDate = date
        guard let fractions, !fractions.isEmpty, fractions.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
            highSince = nil; sustained = false; return
        }
        let mean = fractions.reduce(0, +) / Double(fractions.count)
        values = Array((values + [mean]).suffix(120))
        if mean > 0.9 { highSince = highSince ?? date } else { highSince = nil }
        sustained = highSince.map { date.timeIntervalSince($0) >= 60 } ?? false
    }
}
