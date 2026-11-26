import Foundation
import IOKit
import Metal
import SystemConfiguration

struct GPUReading: Codable, Identifiable, Sendable {
    var id: String; var name: String; var utilization: Double?
}
struct SensorReading: Codable, Identifiable, Sendable {
    var id: String; var name: String; var value: Double; var unit: String
}
struct DiskIOCounter: Codable, Sendable { var read: UInt64; var written: UInt64; var source: String? = nil }
struct DiskIORate: Codable, Identifiable, Sendable { var id: String; var read: Double; var written: Double }
struct BatteryDetails: Codable, Sendable {
    var cycles: Int?; var designCapacity: Int?; var fullCapacity: Int?; var capacityRatio: Double?
}
struct ZombieReading: Codable, Identifiable, Sendable {
    var id: Int32; var parent: Int32; var name: String; var parentName: String?
}
struct HardwareSnapshot: Codable, Sendable {
    var gpus: [GPUReading] = []
    var disks: [String: DiskIOCounter] = [:]
    var battery: BatteryDetails?
    var sensors: [SensorReading] = []
    var bluetooth: [SensorReading] = []
    var proxies: [String] = []
    var proxiesAvailable = false
    var zombies: [ZombieReading]?
    var tunnels: [String] = []
}

enum HardwareMonitor {
    private static let devices = MTLCopyAllDevices()

    static func registry(_ className: String) -> [[String: Any]] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var result: [[String: Any]] = []
        for _ in 0..<256 {
            let entry = IOIteratorNext(iterator)
            if entry == 0 { break }
            defer { IOObjectRelease(entry) }
            var properties: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(entry, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  var values = properties?.takeRetainedValue() as? [String: Any] else { continue }
            var id: UInt64 = 0
            if IORegistryEntryGetRegistryEntryID(entry, &id) == KERN_SUCCESS { values["registryID"] = String(id) }
            if className == "IOBlockStorageDriver", let bsd = IORegistryEntrySearchCFProperty(entry, kIOServicePlane, "BSD Name" as CFString, kCFAllocatorDefault, IOOptionBits(kIORegistryIterateRecursively)) as? String { values["diskName"] = bsd }
            result.append(values)
        }
        return result
    }

    static func capture() -> HardwareSnapshot {
        var snapshot = HardwareSnapshot()
        let accelerators = registry("IOAccelerator")
        snapshot.gpus = devices.map { device in
            let entry = accelerators.first { ($0["registryID"] as? String) == String(device.registryID) }
                ?? (devices.count == 1 && accelerators.count == 1 ? accelerators.first : nil)
            return GPUReading(id: String(device.registryID), name: device.name, utilization: gpuUtilization(entry ?? [:]))
        }
        for driver in registry("IOBlockStorageDriver") {
            guard let id = driver["registryID"] as? String, var counter = diskCounter(driver) else { continue }
            counter.source = id
            snapshot.disks[driver["diskName"] as? String ?? id] = counter
        }
        snapshot.battery = registry("AppleSmartBattery").first.flatMap(batteryDetails)
        snapshot.sensors = registry("IOHWSensor").compactMap(sensor)
        snapshot.bluetooth = registry("AppleDeviceManagementHIDEventService").compactMap { item in
            guard let battery = (item["BatteryPercent"] as? NSNumber)?.doubleValue, (0...100).contains(battery),
                  let id = item["registryID"] as? String else { return nil }
            return SensorReading(id: id, name: item["Product"] as? String ?? tr("hardware.device"), value: battery, unit: "%")
        }
        if let proxies = SCDynamicStoreCopyProxies(nil) as? [String: Any] {
            snapshot.proxiesAvailable = true
            snapshot.proxies = ["HTTP", "HTTPS", "SOCKS", "ProxyAutoConfig"].filter { (proxies[$0 + "Enable"] as? NSNumber)?.boolValue == true }
        }
        snapshot.zombies = zombies(Shell.run("/bin/ps", ["-ax", "-o", "pid=,ppid=,stat=,comm="], timeout: 5))
        return snapshot
    }

    static func gpuUtilization(_ entry: [String: Any]) -> Double? {
        guard let stats = entry["PerformanceStatistics"] as? [String: Any],
              let percent = (stats["Device Utilization %"] as? NSNumber)?.doubleValue, (0...100).contains(percent) else { return nil }
        return percent / 100
    }
    static func diskCounter(_ entry: [String: Any]) -> DiskIOCounter? {
        guard let stats = entry["Statistics"] as? [String: Any],
              let read = stats["Bytes (Read)"] as? NSNumber, let written = stats["Bytes (Write)"] as? NSNumber,
              read.doubleValue >= 0, written.doubleValue >= 0 else { return nil }
        return DiskIOCounter(read: read.uint64Value, written: written.uint64Value)
    }
    static func batteryDetails(_ entry: [String: Any]) -> BatteryDetails? {
        let cycles = (entry["CycleCount"] as? NSNumber)?.intValue
        let design = (entry["DesignCapacity"] as? NSNumber)?.intValue
        let full = (entry["AppleRawMaxCapacity"] as? NSNumber)?.intValue ?? (entry["NominalChargeCapacity"] as? NSNumber)?.intValue
        guard cycles != nil || design != nil || full != nil else { return nil }
        return BatteryDetails(cycles: cycles.flatMap { $0 >= 0 ? $0 : nil }, designCapacity: design, fullCapacity: full,
                              capacityRatio: design.flatMap { d in full.flatMap { f in d > 0 && f > 0 ? Double(f) / Double(d) : nil } })
    }
    static func sensor(_ entry: [String: Any]) -> SensorReading? {
        guard let type = entry["type"] as? String, let raw = (entry["current-value"] as? NSNumber)?.doubleValue,
              let id = entry["registryID"] as? String else { return nil }
        let unit: String, value: Double
        switch type {
        case "temperature": unit = "°C"; value = raw / 65536
        case "fanspeed": unit = "RPM"; value = raw / 65536
        case "power": unit = "W"; value = raw / 65536
        default: return nil
        }
        guard value.isFinite, value >= 0, value <= (unit == "°C" ? 150 : 100000) else { return nil }
        return SensorReading(id: id, name: entry["location"] as? String ?? type, value: value, unit: unit)
    }
    static func rates(previous: HardwareSnapshot?, current: HardwareSnapshot, seconds: TimeInterval) -> [DiskIORate] {
        guard let previous, seconds.isFinite, seconds > 0 else { return [] }
        return current.disks.keys.sorted().compactMap { id in
            guard let a = previous.disks[id], let b = current.disks[id], a.source == b.source, b.read >= a.read, b.written >= a.written else { return nil }
            return DiskIORate(id: id, read: Double(b.read - a.read) / seconds, written: Double(b.written - a.written) / seconds)
        }
    }

    static func smart(runner: (String, [String]) -> ShellResult = { Shell.run($0, $1, timeout: 5) }) -> [String: String] {
        var output: [String: String] = [:]
        let media = registry("IOMedia").filter { ($0["Whole"] as? NSNumber)?.boolValue == true }
        for item in media.prefix(8) {
            guard let name = item["BSD Name"] as? String, name.range(of: #"^disk[0-9]+$"#, options: .regularExpression) != nil else { continue }
            let response = runner("/usr/sbin/diskutil", ["info", "-plist", name])
            output[name] = smartStatus(response) ?? tr("storage.unavailable")
        }
        return output
    }
    static func smartStatus(_ response: ShellResult) -> String? {
        guard response.status == 0, let data = response.stdout.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return plist["SMARTStatus"] as? String
    }
    static func zombies(_ response: ShellResult) -> [ZombieReading]? {
        guard response.status == 0 else { return nil }
        let rows = response.stdout.split(separator: "\n").compactMap { line -> (Int32, Int32, String, String)? in
            let fields = line.split(maxSplits: 3, whereSeparator: \.isWhitespace)
            guard fields.count == 4, let pid = Int32(fields[0]), let parent = Int32(fields[1]) else { return nil }
            return (pid, parent, String(fields[2]), (String(fields[3]) as NSString).lastPathComponent)
        }
        guard rows.count == response.stdout.split(separator: "\n").count else { return nil }
        let names = Dictionary(rows.map { ($0.0, $0.3) }, uniquingKeysWith: { first, _ in first })
        return rows.filter { $0.2.hasPrefix("Z") }.map { ZombieReading(id: $0.0, parent: $0.1, name: $0.3, parentName: names[$0.1]) }
    }
}
