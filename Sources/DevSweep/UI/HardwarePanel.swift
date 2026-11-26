import SwiftUI

struct HardwarePanel: View {
    @ObservedObject var model: GeneralModel
    var body: some View {
        if let snapshot = model.monitor {
            let hardware = snapshot.hardware
            if !model.monitoringError.isEmpty { Text(model.monitoringError).font(.caption).foregroundStyle(.orange) }
            Text(tr("hardware.title")).font(.headline)
            if model.recordingMonitor { Text(tr("hardware.recording")).font(.caption).foregroundStyle(.green) }
            Text(tr("hardware.availability")).font(.caption2).foregroundStyle(.secondary)
            if !model.cpuHistory.isEmpty {
                Canvas { context, size in
                    var path = Path()
                    for (index, value) in model.cpuHistory.enumerated() {
                        let point = CGPoint(x: Double(index) / Double(max(1, model.cpuHistory.count - 1)) * size.width, y: (1 - value) * size.height)
                        if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                    }
                    context.stroke(path, with: .color(.blue), lineWidth: 2)
                }.frame(height: 55).accessibilityLabel(tr("hardware.cpu_history"))
                Text(tr("hardware.cpu_history")).font(.caption2)
            }
            if model.sustainedCPU { Text(tr("hardware.cpu_alert")).font(.callout).foregroundStyle(.orange) }
            if let cache = snapshot.system.memCache { Text(tr("hardware.memory_cache", ["value": Fmt.memory(cache)])).font(.caption) }
            Text(tr("hardware.pressure", ["value": snapshot.system.pressureAvailable ? snapshot.system.pressure.label : tr("storage.unavailable")])).font(.caption)
            if hardware.gpus.isEmpty { Text(tr("hardware.gpu_unavailable")).font(.caption) }
            ForEach(hardware.gpus) { gpu in
                if let fraction = gpu.utilization {
                    MeterView(title: gpu.name, fraction: fraction, caption: fraction.formatted(.percent), tint: .green)
                } else { Text(gpu.name + " · " + tr("hardware.gpu_unavailable")).font(.caption) }
            }
            if let battery = hardware.battery {
                if let cycles = battery.cycles { Text(tr("hardware.cycles", ["count": cycles])).font(.caption) }
                if let ratio = battery.capacityRatio { Text(tr("hardware.capacity", ["value": ratio.formatted(.percent.precision(.fractionLength(0)))])).font(.caption) }
            }
            Text(tr("hardware.disk_io")).font(.headline)
            if model.diskRates.isEmpty { Text(tr("storage.unavailable")).font(.caption) }
            ForEach(model.diskRates) { rate in
                Text("\(rate.id) · ↓ \(Fmt.memory(Int64(clamping: UInt64(min(rate.read, 9_000_000_000_000_000_000)))))/s · ↑ \(Fmt.memory(Int64(clamping: UInt64(min(rate.written, 9_000_000_000_000_000_000)))))/s").font(.caption.monospacedDigit())
            }
            ForEach(model.smartStatus.keys.sorted(), id: \.self) { disk in
                Text("SMART · \(disk): \(model.smartStatus[disk] ?? tr("storage.unavailable"))").font(.caption)
            }
            Text(tr("hardware.sensors")).font(.headline)
            if hardware.sensors.isEmpty { Text(tr("hardware.sensor_unavailable")).font(.caption2).foregroundStyle(.secondary) }
            ForEach(hardware.sensors) { sensor in
                Text("\(sensor.name): \(sensor.value.formatted(.number.precision(.fractionLength(1)))) \(sensor.unit)").font(.caption)
            }
            Text(tr("hardware.bluetooth")).font(.headline)
            if hardware.bluetooth.isEmpty { Text(tr("storage.unavailable")).font(.caption) }
            ForEach(hardware.bluetooth) { device in Text("\(device.name): \(Int(device.value))%").font(.caption) }
            Text(tr("hardware.tunnels", ["value": hardware.tunnels.isEmpty ? tr("hardware.none") : hardware.tunnels.joined(separator: ", ")])).font(.caption)
            Text(tr("hardware.proxies", ["value": !hardware.proxiesAvailable ? tr("storage.unavailable") : hardware.proxies.isEmpty ? tr("hardware.none") : hardware.proxies.joined(separator: ", ")])).font(.caption)
            Text(tr("hardware.memory_processes")).font(.headline)
            ForEach(Array(snapshot.processes.sorted { $0.rssBytes > $1.rssBytes }.prefix(10))) { process in
                HStack { Text(process.exeName); Spacer(); Text(Fmt.memory(process.rssBytes)) }.font(.caption)
            }
            Text(tr("hardware.zombies")).font(.headline)
            if let zombies = hardware.zombies {
                if zombies.isEmpty { Text(tr("hardware.none")).font(.caption) }
                ForEach(zombies) { zombie in
                    Text("\(zombie.name) (\(zombie.id)) → \(zombie.parentName ?? "?") (\(zombie.parent))").font(.caption)
                }
            } else { Text(tr("storage.unavailable")).font(.caption) }
        }
    }
}
