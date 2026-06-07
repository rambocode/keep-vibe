import Foundation
import Darwin
import IOKit.ps

// nonisolated(unsafe) 用于保存跨调用的 CPU tick 快照（Swift 6 全局变量需显式声明并发安全性）
private nonisolated(unsafe) var previousCPUTicks: [processor_cpu_load_info_data_t] = []

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
        var cpuInfoArray: processor_info_array_t? = nil
        var cpuInfoCount: mach_msg_type_number_t = 0
        var processorCount: natural_t = 0

        let kr = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &processorCount,
            &cpuInfoArray,
            &cpuInfoCount
        )

        guard kr == KERN_SUCCESS, let infoPtr = cpuInfoArray else { return 0 }

        defer {
            // 释放 Mach 分配的内存
            let size = vm_size_t(cpuInfoCount) * vm_size_t(MemoryLayout<integer_t>.size)
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: infoPtr), size)
        }

        // 将原始指针转换为结构体数组
        let stride = Int(CPU_STATE_MAX)   // 每核 4 个状态：user/system/idle/nice
        let count  = Int(processorCount)

        var current = [processor_cpu_load_info_data_t](repeating: processor_cpu_load_info_data_t(), count: count)
        for i in 0 ..< count {
            current[i].cpu_ticks.0 = UInt32(infoPtr[i * stride + Int(CPU_STATE_USER)])
            current[i].cpu_ticks.1 = UInt32(infoPtr[i * stride + Int(CPU_STATE_SYSTEM)])
            current[i].cpu_ticks.2 = UInt32(infoPtr[i * stride + Int(CPU_STATE_IDLE)])
            current[i].cpu_ticks.3 = UInt32(infoPtr[i * stride + Int(CPU_STATE_NICE)])
        }

        let prev = previousCPUTicks
        previousCPUTicks = current

        // 首次调用：无历史快照，用当前瞬时数据近似（user+system / total）
        guard prev.count == count else {
            var user: Double = 0; var total: Double = 0
            for c in current {
                let u = Double(c.cpu_ticks.0)
                let s = Double(c.cpu_ticks.1)
                let i = Double(c.cpu_ticks.2)
                let n = Double(c.cpu_ticks.3)
                user  += u + s + n
                total += u + s + i + n
            }
            return total > 0 ? (user / total) * 100 : 0
        }

        // 正常：计算两次快照之间的差值
        var deltaUser: Double = 0; var deltaTotal: Double = 0
        for i in 0 ..< count {
            let cu = Double(current[i].cpu_ticks.0)
            let cs = Double(current[i].cpu_ticks.1)
            let ci = Double(current[i].cpu_ticks.2)
            let cn = Double(current[i].cpu_ticks.3)

            let pu = Double(prev[i].cpu_ticks.0)
            let ps = Double(prev[i].cpu_ticks.1)
            let pi = Double(prev[i].cpu_ticks.2)
            let pn = Double(prev[i].cpu_ticks.3)

            let du = (cu - pu) + (cs - ps) + (cn - pn)  // 活跃 tick 差
            let dt = du + (ci - pi)                       // 总 tick 差

            deltaUser  += du
            deltaTotal += dt
        }

        return deltaTotal > 0 ? max(0, min(100, (deltaUser / deltaTotal) * 100)) : 0
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
