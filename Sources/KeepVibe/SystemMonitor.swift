import Foundation
import Darwin
import IOKit.ps

// nonisolated(unsafe) 用于保存跨调用的 CPU tick 快照（Swift 6 全局变量需显式声明并发安全性）
private struct CPUSnapshot {
    let user: UInt64
    let system: UInt64
    let idle: UInt64
    let nice: UInt64
}

private nonisolated(unsafe) var previousCPUTicks: CPUSnapshot?

enum SystemMonitor {

    // MARK: - Public API

    static func sample() -> SystemStats {
        var stats = SystemStats()
        stats.uptimeSeconds = sampleUptime()
        stats.cpuPercent    = sampleCPU()
        (stats.memUsedBytes, stats.memTotalBytes) = sampleMemory()
        (stats.batteryPercent, stats.batteryCharging) = sampleBattery()
        return stats
    }

    // MARK: - Uptime

    private static func sampleUptime() -> TimeInterval {
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        var boottime = timeval()
        var size = MemoryLayout<timeval>.size
        let ret = sysctl(&mib, 2, &boottime, &size, nil, 0)
        guard ret == 0 else { return 0 }
        let bootDate = Date(timeIntervalSince1970: Double(boottime.tv_sec) + Double(boottime.tv_usec) / 1_000_000)
        return Date().timeIntervalSince(bootDate)
    }

    // MARK: - CPU

    private static func sampleCPU() -> Double {
        var cpuLoad = host_cpu_load_info_data_t()
        var loadCount = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size
        )

        let kr: kern_return_t = withUnsafeMutablePointer(to: &cpuLoad) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(loadCount)) { reboundPtr in
                host_statistics(
                    mach_host_self(),
                    HOST_CPU_LOAD_INFO,
                    reboundPtr,
                    &loadCount
                )
            }
        }

        guard kr == KERN_SUCCESS else { return 0 }

        let current = CPUSnapshot(
            user: UInt64(cpuLoad.cpu_ticks.0),
            system: UInt64(cpuLoad.cpu_ticks.1),
            idle: UInt64(cpuLoad.cpu_ticks.2),
            nice: UInt64(cpuLoad.cpu_ticks.3)
        )

        let prev = previousCPUTicks
        previousCPUTicks = current

        // 首次调用：无历史快照，用当前瞬时数据近似（user+system / total）
        guard let p = prev else {
            let active = Double(current.user) + Double(current.system) + Double(current.nice)
            let total = Double(current.user) + Double(current.system) + Double(current.idle) + Double(current.nice)
            if total == 0 { return 0.0 }
            return (active / total) * 100
        }

        let currentActive = Double(current.user) + Double(current.system) + Double(current.nice)
        let prevActive = Double(p.user) + Double(p.system) + Double(p.nice)
        let currentTotal =
            Double(current.user) + Double(current.system) + Double(current.idle) + Double(current.nice)
        let prevTotal =
            Double(p.user) + Double(p.system) + Double(p.idle) + Double(p.nice)

        let deltaActive = currentActive - prevActive
        let deltaTotal = currentTotal - prevTotal
        if deltaTotal <= 0 { return 0.0 }
        let value = (deltaActive / deltaTotal) * 100
        return max(0.0, min(100.0, value))
    }

    // MARK: - Memory

    private static func sampleMemory() -> (used: UInt64, total: UInt64) {
        let total = ProcessInfo.processInfo.physicalMemory

        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        let pageSize = UInt64(getpagesize())

        let kr: kern_return_t = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPtr in
                host_statistics64(
                    mach_host_self(),
                    HOST_VM_INFO64,
                    reboundPtr,
                    &count
                )
            }
        }

        guard kr == KERN_SUCCESS else { return (0, total) }

        let active     = UInt64(stats.active_count)
        let wired      = UInt64(stats.wire_count)
        let compressed = UInt64(stats.compressor_page_count)
        let used = (active + wired + compressed) * pageSize

        return (used, total)
    }

    // MARK: - Battery

    private static func sampleBattery() -> (percent: Int?, charging: Bool) {
        let psInfo = IOPSCopyPowerSourcesInfo()
        defer { psInfo?.release() }

        guard let info = psInfo else { return (nil, false) }

        let psList = IOPSCopyPowerSourcesList(info.takeUnretainedValue())
        defer { psList?.release() }

        guard let list = psList else { return (nil, false) }
        let cfArray = list.takeUnretainedValue()
        let count = CFArrayGetCount(cfArray)
        guard count > 0 else { return (nil, false) }
        // 通过 CFArrayGetValueAtIndex 逐元素获取，避免 CFArray→[CFTypeRef] 的条件转换警告
        let cfSources = (0 ..< count).compactMap { CFArrayGetValueAtIndex(cfArray, $0) }
            .map { Unmanaged<CFTypeRef>.fromOpaque($0).takeUnretainedValue() }

        for source in cfSources {
            guard
                let desc = IOPSGetPowerSourceDescription(info.takeUnretainedValue(), source)?.takeUnretainedValue() as? [String: AnyObject]
            else { continue }

            // 过滤非内置电池（台式机外接 UPS 等）
            if let type = desc[kIOPSTypeKey as String] as? String,
               type != kIOPSInternalBatteryType { continue }

            let current = desc[kIOPSCurrentCapacityKey as String] as? Int ?? 0
            let max     = desc[kIOPSMaxCapacityKey as String] as? Int ?? 100
            let percent = max > 0 ? Int(Double(current) / Double(max) * 100) : current

            // 判断充电状态：优先 isCharging key，其次 PowerSourceState == "AC Power"
            var charging = false
            if let isCharging = desc[kIOPSIsChargingKey as String] as? Bool {
                charging = isCharging
            } else if let state = desc[kIOPSPowerSourceStateKey as String] as? String {
                charging = (state == kIOPSACPowerValue)
            }

            return (percent, charging)
        }

        // 遍历完没有找到内置电池（台式机）
        return (nil, false)
    }
}
