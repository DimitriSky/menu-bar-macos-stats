import Foundation

enum MenuBarDisplayMode: String, CaseIterable, Identifiable {
    case percent
    case graph

    var id: String { rawValue }

    var title: String {
        switch self {
        case .percent: return "Percent"
        case .graph: return "Graph"
        }
    }

    var statusItemWidth: CGFloat {
        switch self {
        case .percent: return 76
        case .graph: return 74
        }
    }
}

enum UpdateIntervalOption: Double, CaseIterable, Identifiable {
    case oneSecond = 1
    case twoSeconds = 2
    case threeSeconds = 3
    case fiveSeconds = 5
    case tenSeconds = 10

    var id: Double { rawValue }

    var label: String {
        "\(Int(rawValue))s"
    }
}

struct ProcessMetric: Identifiable, Equatable {
    let pid: Int32
    let name: String
    let percent: Double

    var id: Int32 { pid }
}

struct TimedSample: Equatable {
    let time: TimeInterval
    let value: Double
}

struct DiskUsage: Equatable {
    let volumeName: String
    let totalBytes: Int64
    let availableBytes: Int64
    let immediateFreeBytes: Int64

    static let empty = DiskUsage(volumeName: "Disk", totalBytes: 0, availableBytes: 0, immediateFreeBytes: 0)

    var usedBytes: Int64 {
        max(0, totalBytes - availableBytes)
    }

    var purgeableBytes: Int64 {
        max(0, availableBytes - immediateFreeBytes)
    }

    var usedFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(max(Double(usedBytes) / Double(totalBytes), 0), 1)
    }

    var usedPercent: Double {
        usedFraction * 100.0
    }

    static func formatGigabytes(_ bytes: Int64) -> String {
        let gb = Double(max(0, bytes)) / 1_000_000_000.0
        if gb >= 100 {
            return String(format: "%.0f GB", gb)
        }
        return String(format: "%.1f GB", gb)
    }
}

struct CPUCoreTicks: Equatable {
    let user: UInt64
    let system: UInt64
    let idle: UInt64
    let nice: UInt64

    var active: UInt64 { user &+ system &+ nice }
    var total: UInt64 { active &+ idle }
}

/// Maintains a rolling time-window history (default 10s) for processes that enter the Top 5.
struct ProcessHistoryTracker {
    let windowSeconds: TimeInterval
    private(set) var series: [Int32: [TimedSample]] = [:]
    private var lastInTopAt: [Int32: TimeInterval] = [:]

    init(windowSeconds: TimeInterval = 10.0) {
        self.windowSeconds = windowSeconds
    }

    mutating func record(
        topProcesses: [ProcessMetric],
        allCurrentValues: [Int32: Double],
        at now: TimeInterval
    ) {
        // Keep a small extra buffer past windowSeconds so points slide smoothly past the left edge.
        let pruneCutoff = now - windowSeconds - 3.0
        var activePIDs = Set(series.keys)

        for proc in topProcesses {
            lastInTopAt[proc.pid] = now
            activePIDs.insert(proc.pid)
        }

        for pid in activePIDs {
            // Drop processes that haven't been in Top 5 within the rolling window.
            if let lastSeen = lastInTopAt[pid], now - lastSeen > windowSeconds + 3.0 {
                series.removeValue(forKey: pid)
                lastInTopAt.removeValue(forKey: pid)
                continue
            }

            let val = max(0, allCurrentValues[pid] ?? topProcesses.first(where: { $0.pid == pid })?.percent ?? 0)
            var samples = series[pid] ?? []
            samples.append(TimedSample(time: now, value: val))
            if let firstToKeep = samples.firstIndex(where: { $0.time >= pruneCutoff }), firstToKeep > 1 {
                samples.removeFirst(firstToKeep - 1)
            }
            series[pid] = samples
        }
    }

    mutating func clear() {
        series.removeAll()
        lastInTopAt.removeAll()
    }
}

enum MetricsMath {
    static func cpuPercent(previous: CPUCoreTicks, current: CPUCoreTicks) -> Double {
        let deltaTotal = current.total &- previous.total
        guard deltaTotal > 0 else { return 0 }
        let deltaActive = current.active &- previous.active
        let pct = (Double(deltaActive) / Double(deltaTotal)) * 100.0
        return min(max(pct, 0), 100)
    }

    static func topProcesses(from samples: [ProcessMetric], limit: Int = 5) -> [ProcessMetric] {
        samples
            .filter { $0.percent >= 0.05 }
            .sorted { lhs, rhs in
                if lhs.percent != rhs.percent { return lhs.percent > rhs.percent }
                if lhs.name != rhs.name { return lhs.name < rhs.name }
                return lhs.pid < rhs.pid
            }
            .prefix(limit)
            .map { $0 }
    }

    static func parseIOUserClientCreator(_ creator: String) -> (pid: Int32, name: String)? {
        // Expected format: "pid 447, WindowServer"
        guard creator.hasPrefix("pid ") else { return nil }
        let rest = creator.dropFirst(4)
        guard let commaIndex = rest.firstIndex(of: ",") else { return nil }
        let pidSlice = rest[..<commaIndex].trimmingCharacters(in: .whitespaces)
        guard let pid = Int32(pidSlice) else { return nil }
        let name = rest[rest.index(after: commaIndex)...].trimmingCharacters(in: .whitespaces)
        return (pid, name.isEmpty ? "PID \(pid)" : name)
    }

    static func parsePSLine(_ line: String) -> (pid: Int32, cpuTimeSeconds: Double, instantCPU: Double, name: String)? {
        // Expected format from: ps -axo pid=,%cpu=,cputime=,comm=
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(maxSplits: 3, omittingEmptySubsequences: true, whereSeparator: { $0.isWhitespace })
        guard parts.count == 4,
              let pid = Int32(parts[0]),
              let instantCPU = Double(parts[1]),
              let cpuTime = parseCPUTime(String(parts[2])) else {
            return nil
        }
        let rawCommand = String(parts[3]).trimmingCharacters(in: .whitespaces)
        let basename = URL(fileURLWithPath: rawCommand).lastPathComponent
        let cleanName = basename.isEmpty ? rawCommand : basename
        return (pid, cpuTime, instantCPU, cleanName)
    }

    static func parseCPUTime(_ raw: String) -> Double? {
        let components = raw.split(separator: ":")
        if components.count == 2,
           let minutes = Double(components[0]),
           let seconds = Double(components[1]) {
            return minutes * 60.0 + seconds
        }
        if components.count == 3,
           let hours = Double(components[0]),
           let minutes = Double(components[1]),
           let seconds = Double(components[2]) {
            return hours * 3600.0 + minutes * 60.0 + seconds
        }
        return nil
    }

    static func gpuAllDeltas(
        previous: [Int32: (name: String, ns: UInt64)],
        current: [Int32: (name: String, ns: UInt64)],
        elapsedSeconds: Double
    ) -> [ProcessMetric] {
        guard elapsedSeconds > 0.05 else { return [] }
        let denom = elapsedSeconds * 1_000_000_000.0
        var results: [ProcessMetric] = []
        results.reserveCapacity(current.count)
        for (pid, cur) in current {
            guard let prev = previous[pid], cur.ns >= prev.ns else { continue }
            let deltaNs = cur.ns - prev.ns
            guard deltaNs > 0 else { continue }
            let pct = (Double(deltaNs) / denom) * 100.0
            results.append(ProcessMetric(pid: pid, name: cur.name, percent: pct))
        }
        return results
    }

    static func gpuDeltas(
        previous: [Int32: (name: String, ns: UInt64)],
        current: [Int32: (name: String, ns: UInt64)],
        elapsedSeconds: Double
    ) -> [ProcessMetric] {
        topProcesses(from: gpuAllDeltas(previous: previous, current: current, elapsedSeconds: elapsedSeconds), limit: 5)
    }

    /// Updates displayed Top 5 rows: reorders/replaces membership only when `shouldReorder` is true
    /// (or list is currently empty); otherwise preserves existing row order while refreshing live
    /// percentages and filling any empty slots (< 5) if new active processes appear.
    static func mergeDisplayedOrder(
        currentOrder: [ProcessMetric],
        latestTop: [ProcessMetric],
        allCurrentValues: [Int32: Double],
        shouldReorder: Bool,
        limit: Int = 5
    ) -> [ProcessMetric] {
        if shouldReorder || currentOrder.isEmpty {
            return Array(latestTop.prefix(limit))
        }
        var result = currentOrder.map { existing in
            let livePercent = max(0, allCurrentValues[existing.pid] ?? 0)
            return ProcessMetric(pid: existing.pid, name: existing.name, percent: livePercent)
        }
        if result.count < limit {
            let existingPIDs = Set(result.map(\.pid))
            for candidate in latestTop where !existingPIDs.contains(candidate.pid) {
                result.append(candidate)
                if result.count >= limit { break }
            }
        }
        return result
    }
}

struct MetricHistory {
    private(set) var values: [Double]
    let capacity: Int

    init(capacity: Int = 30) {
        self.capacity = max(2, capacity)
        self.values = Array(repeating: 0, count: self.capacity)
    }

    mutating func append(_ value: Double) {
        let clamped = min(max(value, 0), 100)
        if values.count >= capacity {
            values.removeFirst(values.count - capacity + 1)
        }
        values.append(clamped)
    }
}
