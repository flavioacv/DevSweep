import Darwin
import Foundation
import IOKit.ps

struct VolumeSnapshot: Identifiable, Sendable {
    let path: String
    let total: Int64
    let free: Int64
    let readOnly: Bool
    var id: String { path }
}

struct NetworkCounters: Sendable { var received: UInt64; var sent: UInt64 }
struct NetworkRate: Identifiable, Sendable {
    let id: String
    let received: Double
    let sent: Double
}

struct MonitorSnapshot: Sendable {
    var date = Date()
    var system: SystemSnapshot
    var cpuTicks: [[UInt64]]
    var network: [String: NetworkCounters]
    var volumes: [VolumeSnapshot]
    var processes: [ProcInfo]
    var swap: UInt64?
    var battery: Double?
    var charging: Bool?
    var uptime: TimeInterval
    var load: [Double]
    var thermal: String
    var hardware = HardwareSnapshot()
}

enum SystemMonitor {
    static func capture() -> MonitorSnapshot {
        var swap = xsw_usage()
        var count = MemoryLayout<xsw_usage>.size
        let swapOK = sysctlbyname("vm.swapusage", &swap, &count, nil, 0) == 0
        var averages = [Double](repeating: 0, count: 3)
        let loadOK = getloadavg(&averages, 3) == 3
        let ps = Shell.run("/bin/ps", ["-axww", "-o", "pid=,ppid=,uid=,rss=,%cpu=,etime=,command="], timeout: 10)
        let processes = ps.status == 0 ? ProcessScanner.parse(ps.stdout) : []
        let battery = batteryState()
        let thermal: String
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermal = tr("pressure.normal")
        case .fair: thermal = tr("pressure.warning")
        case .serious, .critical: thermal = tr("pressure.critical")
        @unknown default: thermal = tr("storage.unavailable")
        }
        let network = networkCounters()
        var hardware = HardwareMonitor.capture()
        hardware.tunnels = network.keys.filter { $0.hasPrefix("utun") || $0.hasPrefix("ppp") || $0.hasPrefix("ipsec") }.sorted()
        return MonitorSnapshot(system: SystemStats.snapshot(), cpuTicks: cpuTicks(), network: network,
            volumes: volumes(), processes: processes.sorted { $0.cpu > $1.cpu }, swap: swapOK ? swap.xsu_used : nil,
            battery: battery.0, charging: battery.1, uptime: ProcessInfo.processInfo.systemUptime,
            load: loadOK ? averages : [], thermal: thermal, hardware: hardware)
    }

    static func cpuFractions(previous: [[UInt64]], current: [[UInt64]]) -> [Double]? {
        guard !current.isEmpty, previous.count == current.count else { return nil }
        var result: [Double] = []
        for (old, new) in zip(previous, current) {
            guard old.count == 4, new.count == 4, zip(old, new).allSatisfy({ $0 <= $1 }) else { return nil }
            let delta = zip(old, new).map { $1 - $0 }
            let total = delta.reduce(0.0) { $0 + Double($1) }
            guard total > 0 else { return nil }
            result.append(max(0, min(1, 1 - Double(delta[2]) / total)))
        }
        return result
    }

    static func networkRates(previous: MonitorSnapshot?, current: MonitorSnapshot) -> [NetworkRate] {
        guard let previous, current.date > previous.date else { return [] }
        let seconds = current.date.timeIntervalSince(previous.date)
        return current.network.keys.sorted().compactMap { name in
            guard let old = previous.network[name], let new = current.network[name],
                  new.received >= old.received, new.sent >= old.sent else { return nil }
            return NetworkRate(id: name, received: Double(new.received - old.received) / seconds,
                               sent: Double(new.sent - old.sent) / seconds)
        }
    }

    static func volumes() -> [VolumeSnapshot] {
        var pointer: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&pointer, MNT_NOWAIT)
        guard count > 0, let pointer else { return [] }
        return UnsafeBufferPointer(start: pointer, count: Int(count)).compactMap { original in
            var mount = original
            let path = withUnsafePointer(to: &mount.f_mntonname) { value in
                value.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            guard mount.f_flags & UInt32(MNT_LOCAL) != 0,
                  path == "/" || path == "/System/Volumes/Data" || (path as NSString).deletingLastPathComponent == "/Volumes" else { return nil }
            let block = UInt64(mount.f_bsize)
            let total = UInt64(mount.f_blocks).multipliedReportingOverflow(by: block)
            let free = UInt64(mount.f_bavail).multipliedReportingOverflow(by: block)
            guard !total.overflow, !free.overflow, total.partialValue <= Int64.max, free.partialValue <= Int64.max else { return nil }
            return VolumeSnapshot(path: path, total: Int64(total.partialValue), free: Int64(free.partialValue),
                                  readOnly: mount.f_flags & UInt32(MNT_RDONLY) != 0)
        }.sorted { $0.path < $1.path }
    }

    private static func cpuTicks() -> [[UInt64]] {
        var cores: natural_t = 0
        var info: processor_info_array_t?
        var count: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cores, &info, &count) == KERN_SUCCESS,
              let info else { return [] }
        defer { vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)), vm_size_t(count) * vm_size_t(MemoryLayout<integer_t>.size)) }
        let values = Array(UnsafeBufferPointer(start: info, count: Int(count))).map { UInt64(UInt32(bitPattern: $0)) }
        return stride(from: 0, to: min(values.count, Int(cores) * 4), by: 4).map { Array(values[$0..<$0 + 4]) }
    }

    private static func networkCounters() -> [String: NetworkCounters] {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0 else { return [:] }
        defer { freeifaddrs(interfaces) }
        var result: [String: NetworkCounters] = [:]
        var cursor = interfaces
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            let item = current.pointee
            guard item.ifa_addr?.pointee.sa_family == UInt8(AF_LINK), item.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                  let raw = item.ifa_data else { continue }
            let data = raw.assumingMemoryBound(to: if_data.self).pointee
            result[String(cString: item.ifa_name)] = NetworkCounters(received: UInt64(data.ifi_ibytes), sent: UInt64(data.ifi_obytes))
        }
        return result
    }

    private static func batteryState() -> (Double?, Bool?) {
        guard let raw = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(raw)?.takeRetainedValue() as? [CFTypeRef] else { return (nil, nil) }
        for source in sources {
            guard let dictionary = IOPSGetPowerSourceDescription(raw, source)?.takeUnretainedValue() as? [String: Any],
                  let current = dictionary["Current Capacity"] as? NSNumber,
                  let maximum = dictionary["Max Capacity"] as? NSNumber, maximum.doubleValue > 0 else { continue }
            return (current.doubleValue / maximum.doubleValue, dictionary["Is Charging"] as? Bool)
        }
        return (nil, nil)
    }
}
