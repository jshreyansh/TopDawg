import Foundation
import Darwin
import Combine

final class SystemMonitorManager: ObservableObject {
    @Published private(set) var cpuPct:     Double = 0
    @Published private(set) var ramPct:     Double = 0
    @Published private(set) var ramUsedGB:  Double = 0
    @Published private(set) var ramTotalGB: Double = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
    @Published private(set) var cpuHistory: [Double] = Array(repeating: 0, count: 30)
    @Published private(set) var ramHistory: [Double] = Array(repeating: 0, count: 30)

    private var sink: AnyCancellable?
    private var prevTicks: [(u: Double, s: Double, n: Double, i: Double)] = []

    // MARK: - Lifecycle

    func start() {
        guard sink == nil else { return }
        update()
        sink = Timer.publish(every: 2, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.update() }
    }

    func stop() {
        sink?.cancel(); sink = nil
    }

    // MARK: - Private

    private func update() {
        let cpu = getCPU()
        let (used, total) = getRAM()
        cpuPct    = cpu
        ramUsedGB = used
        ramTotalGB = total
        ramPct    = total > 0 ? (used / total) * 100 : 0
        cpuHistory = Array(cpuHistory.dropFirst()) + [cpu]
        ramHistory = Array(ramHistory.dropFirst()) + [ramPct]
    }

    private func getCPU() -> Double {
        var numCPUs: natural_t = 0
        var cpuInfo: processor_info_array_t?
        var numCPUInfo: mach_msg_type_number_t = 0

        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                   &numCPUs, &cpuInfo, &numCPUInfo) == KERN_SUCCESS,
              let cpuInfo else { return cpuPct }

        defer {
            vm_deallocate(mach_task_self_,
                          vm_address_t(UInt(bitPattern: cpuInfo)),
                          vm_size_t(numCPUInfo) * vm_size_t(MemoryLayout<integer_t>.stride))
        }

        let n = Int(numCPUs)
        var newTicks: [(Double, Double, Double, Double)] = []
        var usedDelta = 0.0, allDelta = 0.0

        for i in 0..<n {
            let base = Int(CPU_STATE_MAX) * i
            let u    = Double(cpuInfo[base + Int(CPU_STATE_USER)])
            let s    = Double(cpuInfo[base + Int(CPU_STATE_SYSTEM)])
            let nc   = Double(cpuInfo[base + Int(CPU_STATE_NICE)])
            let idle = Double(cpuInfo[base + Int(CPU_STATE_IDLE)])
            newTicks.append((u, s, nc, idle))

            if i < prevTicks.count {
                let p = prevTicks[i]
                let used = (u - p.u) + (s - p.s) + (nc - p.n)
                let all  = used + (idle - p.i)
                usedDelta += used
                allDelta  += all
            }
        }
        prevTicks = newTicks
        return allDelta > 0 ? max(0, min(100, usedDelta / allDelta * 100)) : 0
    }

    private func getRAM() -> (Double, Double) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)

        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return (ramUsedGB, ramTotalGB) }

        let pgSize = Double(vm_page_size)
        let used   = Double(stats.active_count + stats.wire_count) * pgSize / 1_073_741_824
        let total  = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        return (used, total)
    }
}
