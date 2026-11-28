import SwiftUI

private enum ProcessMetricMode: String, CaseIterable, Identifiable {
    case cpu
    case memory

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: tr("monitor.processes_tab_cpu")
        case .memory: tr("monitor.processes_tab_ram")
        }
    }
}

struct HardwarePanel: View {
    @ObservedObject var model: GeneralModel
    @State private var processMode: ProcessMetricMode = .cpu

    var body: some View {
        if let snapshot = model.monitor {
            let hardware = snapshot.hardware
            VStack(alignment: .leading, spacing: 14) {
                ioAndNetworkGrid(hardware: hardware)
                sensorsAndBluetoothCard(hardware: hardware)
                processesCard(snapshot: snapshot)
                zombiesCard(hardware: hardware)
            }
        }
    }

    private func ioAndNetworkGrid(hardware: HardwareSnapshot) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 12)], spacing: 12) {
            diskIOCard
            networkCard(hardware: hardware)
        }
    }

    private var diskIOCard: some View {
        TechnicalCard(cornerRadius: 11, padding: 12) {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeaderView(
                    title: tr("hardware.disk_io"),
                    systemImage: "externaldrive.connected.to.line.below",
                    tint: .indigo
                )

                if model.diskRates.isEmpty {
                    Text(tr("storage.unavailable"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 6) {
                        HStack {
                            Text(tr("hardware.device")).frame(maxWidth: .infinity, alignment: .leading)
                            Text("↓ " + tr("monitor.read_rate")).frame(width: 92, alignment: .trailing)
                            Text("↑ " + tr("monitor.write_rate")).frame(width: 92, alignment: .trailing)
                        }
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        Divider()
                        ForEach(model.diskRates) { rate in
                            let readBytes = Int64(clamping: UInt64(min(rate.read, 9_000_000_000_000_000_000)))
                            let writeBytes = Int64(clamping: UInt64(min(rate.written, 9_000_000_000_000_000_000)))
                            HStack {
                                Text(rate.id)
                                    .font(.caption.monospaced())
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text("\(Fmt.memory(readBytes))/s")
                                    .frame(width: 92, alignment: .trailing)
                                Text("\(Fmt.memory(writeBytes))/s")
                                    .frame(width: 92, alignment: .trailing)
                            }
                            .font(.caption.monospacedDigit())
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private func networkCard(hardware: HardwareSnapshot) -> some View {
        TechnicalCard(cornerRadius: 11, padding: 12) {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeaderView(
                    title: tr("monitor.network_title"),
                    subtitle: tr("general.network_notice"),
                    systemImage: "network",
                    tint: .teal
                )

                if model.network.isEmpty {
                    Text(tr("general.sampling"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 6) {
                        HStack {
                            Text(tr("general.network")).frame(maxWidth: .infinity, alignment: .leading)
                            Text("↓ " + tr("monitor.download_rate")).frame(width: 92, alignment: .trailing)
                            Text("↑ " + tr("monitor.upload_rate")).frame(width: 92, alignment: .trailing)
                        }
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        Divider()
                        ForEach(model.network) { rate in
                            HStack {
                                Text(rate.id)
                                    .font(.caption.monospaced())
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text("\(Fmt.memory(Int64(rate.received)))/s")
                                    .frame(width: 92, alignment: .trailing)
                                Text("\(Fmt.memory(Int64(rate.sent)))/s")
                                    .frame(width: 92, alignment: .trailing)
                            }
                            .font(.caption.monospacedDigit())
                        }
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 8) {
                        Text(tr("monitor.tunnels_label"))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.top, 3)
                        FlowLayout(spacing: 6) {
                            if hardware.tunnels.isEmpty {
                                StatusBadge(text: tr("hardware.none"), color: .secondary)
                            } else {
                                ForEach(hardware.tunnels, id: \.self) { tunnel in
                                    StatusBadge(text: tunnel, systemImage: "lock.shield", color: .blue)
                                }
                            }
                        }
                    }

                    HStack(alignment: .top, spacing: 8) {
                        Text(tr("monitor.proxies_label"))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.top, 3)
                        FlowLayout(spacing: 6) {
                            if !hardware.proxiesAvailable {
                                StatusBadge(text: tr("storage.unavailable"), color: .orange)
                            } else if hardware.proxies.isEmpty {
                                StatusBadge(text: tr("hardware.none"), color: .secondary)
                            } else {
                                ForEach(hardware.proxies, id: \.self) { proxy in
                                    StatusBadge(text: proxy, systemImage: "arrow.triangle.branch", color: .orange)
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private func sensorsAndBluetoothCard(hardware: HardwareSnapshot) -> some View {
        TechnicalCard(cornerRadius: 11, padding: 12) {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeaderView(
                    title: tr("hardware.sensors"),
                    subtitle: tr("hardware.availability"),
                    systemImage: "thermometer.variable.and.figure",
                    tint: .cyan
                )

                if hardware.sensors.isEmpty {
                    Text(tr("hardware.sensor_unavailable"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 165), spacing: 8)], spacing: 8) {
                        ForEach(hardware.sensors) { sensor in
                            TelemetryStatTile(
                                title: sensor.name,
                                value: "\(sensor.value.formatted(.number.precision(.fractionLength(1)))) \(sensor.unit)",
                                systemImage: "gauge.with.dots.needle.33percent",
                                tint: .cyan
                            )
                        }
                    }
                }

                Divider()

                SectionHeaderView(
                    title: tr("hardware.bluetooth"),
                    systemImage: "wave.3.right",
                    tint: .blue
                )

                if hardware.bluetooth.isEmpty {
                    Text(tr("storage.unavailable"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 165), spacing: 8)], spacing: 8) {
                        ForEach(hardware.bluetooth) { device in
                            TelemetryStatTile(
                                title: device.name,
                                value: "\(Int(device.value))%",
                                systemImage: "battery.75percent",
                                tint: device.value < 20 ? .orange : .green
                            )
                        }
                    }
                }
            }
        }
    }

    private func processesCard(snapshot: MonitorSnapshot) -> some View {
        let items: [ProcInfo] = processMode == .cpu
            ? Array(snapshot.processes.prefix(15))
            : Array(snapshot.processes.sorted { $0.rssBytes > $1.rssBytes }.prefix(15))
        let maxCPU = max(items.map(\.cpu).max() ?? 1, 1)
        let maxRSS = max(items.map(\.rssBytes).max() ?? 1, 1)

        return TechnicalCard(cornerRadius: 11, padding: 12) {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeaderView(
                    title: processMode == .cpu ? tr("general.top_processes") : tr("hardware.memory_processes"),
                    systemImage: "list.bullet.rectangle",
                    tint: .accentColor
                ) {
                    Picker("", selection: $processMode) {
                        ForEach(ProcessMetricMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 210)
                }

                if items.isEmpty {
                    Text(tr("storage.unavailable"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 6) {
                        ForEach(items) { process in
                            let barFraction = processMode == .cpu
                                ? min(max(process.cpu / maxCPU, 0), 1)
                                : Double(process.rssBytes) / Double(maxRSS)
                            HStack(spacing: 10) {
                                Text(process.exeName)
                                    .font(.caption.weight(.medium))
                                    .lineLimit(1)
                                    .frame(width: 170, alignment: .leading)
                                ProportionalBar(
                                    fraction: barFraction,
                                    tint: processMode == .cpu ? .blue : .purple,
                                    height: 4
                                )
                                Text(String(format: "%.1f%%", process.cpu))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(processMode == .cpu ? Color.primary : Color.secondary)
                                    .frame(width: 56, alignment: .trailing)
                                Text(Fmt.memory(process.rssBytes))
                                    .font(.caption.monospacedDigit().weight(.medium))
                                    .foregroundStyle(processMode == .memory ? Color.primary : Color.secondary)
                                    .frame(width: 78, alignment: .trailing)
                            }
                        }
                    }
                }
            }
        }
    }

    private func zombiesCard(hardware: HardwareSnapshot) -> some View {
        let countText: String
        let badgeColor: Color
        if let zombies = hardware.zombies {
            countText = "\(zombies.count)"
            badgeColor = zombies.isEmpty ? .green : .orange
        } else {
            countText = tr("storage.unavailable")
            badgeColor = .secondary
        }

        return TechnicalCard(cornerRadius: 11, padding: 12) {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeaderView(
                    title: tr("hardware.zombies"),
                    systemImage: "exclamationmark.bubble",
                    tint: (hardware.zombies?.isEmpty == false) ? .orange : .secondary
                ) {
                    StatusBadge(text: countText, color: badgeColor)
                }

                if let zombies = hardware.zombies {
                    if zombies.isEmpty {
                        Text(tr("hardware.none"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(zombies) { zombie in
                            HStack {
                                Text("\(zombie.name) (\(zombie.id))")
                                    .font(.caption.monospaced().weight(.medium))
                                Image(systemName: "arrow.right")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Text("\(zombie.parentName ?? "?") (\(zombie.parent))")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                        }
                    }
                } else {
                    Text(tr("storage.unavailable"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
