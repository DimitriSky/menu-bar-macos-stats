import AppKit
import Combine
import Darwin
import Foundation
import IOKit
import ServiceManagement

struct PopoverSnapshot {
    var cpuPercent: Double = 0
    var gpuPercent: Double = 0
    var diskUsage: DiskUsage = .empty
    var disks: [DiskUsage] = []
    var cpuHistory = MetricHistory(capacity: 30)
    var gpuHistory = MetricHistory(capacity: 30)
    var topCPU: [ProcessMetric] = []
    var topGPU: [ProcessMetric] = []
    var cpuProcessHistory: [Int32: [TimedSample]] = [:]
    var gpuProcessHistory: [Int32: [TimedSample]] = [:]
    var processIcons: [Int32: NSImage] = [:]
    var latestSampleTime: TimeInterval = ProcessInfo.processInfo.systemUptime
    var isSamplingDetails: Bool = false
    /// Disabled on the initial open hydration frame so charts don't animate across stale closed-panel time gaps.
    var allowScrollAnimation: Bool = false
}

struct PopoverLayoutSignature: Equatable {
    let displayMode: MenuBarDisplayMode
    let topCPUCount: Int
    let topGPUCount: Int
    let disksCount: Int
    let isSamplingDetails: Bool
}

final class SystemMonitor: ObservableObject {
    static let processGraphWindowSeconds: TimeInterval = 10.0

    // Single batched SwiftUI snapshot — only mutated while the popup is open (or on open hydration).
    @Published private(set) var popoverState = PopoverSnapshot()
    @Published private(set) var isPopoverOpen = false

    // Non-published live backing state updated on every tick for the pure-AppKit menu bar canvas
    // and for instant hydration when the popup opens (zero SwiftUI work while popup is closed).
    private(set) var liveCPUPercent: Double = 0
    private(set) var liveGPUPercent: Double = 0
    private(set) var liveDiskUsage: DiskUsage = .empty
    private(set) var liveDisks: [DiskUsage] = []
    private(set) var liveCPUHistory = MetricHistory(capacity: 30)
    private(set) var liveGPUHistory = MetricHistory(capacity: 30)
    private var liveTopCPU: [ProcessMetric] = []
    private var liveTopGPU: [ProcessMetric] = []
    private var liveCPUProcessHistory: [Int32: [TimedSample]] = [:]
    private var liveGPUProcessHistory: [Int32: [TimedSample]] = [:]
    private var liveLatestSampleTime: TimeInterval = ProcessInfo.processInfo.systemUptime
    private var liveIsSamplingDetails: Bool = false

    @Published var displayMode: MenuBarDisplayMode {
        didSet {
            UserDefaults.standard.set(displayMode.rawValue, forKey: Keys.displayMode)
            onMenuBarNeedsUpdate?()
            if isPopoverOpen {
                notifyPopoverLayoutIfNeeded()
            }
            if displayMode == .graph {
                // Start recording Top 5 process 10s history immediately.
                sampleNow(includeDetails: true)
            } else if !isPopoverOpen {
                clearDetailBaselines()
            }
        }
    }

    @Published var updateInterval: UpdateIntervalOption {
        didSet {
            UserDefaults.standard.set(updateInterval.rawValue, forKey: Keys.updateInterval)
            rescheduleTimer()
        }
    }

    @Published var orderUpdateInterval: UpdateIntervalOption {
        didSet {
            UserDefaults.standard.set(orderUpdateInterval.rawValue, forKey: Keys.orderUpdateInterval)
            samplingQueue.async { [weak self] in
                self?.lastOrderUpdateTimestamp = nil
            }
        }
    }

    @Published var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled

    var onMenuBarNeedsUpdate: (() -> Void)?
    var onPopoverLayoutChanged: (() -> Void)?

    private struct ResolvedProcessMetadata {
        let rawName: String
        let displayName: String
        let icon: NSImage?
    }

    // Accessed only on main thread; caches localizedName & NSImage for displayed Top-5 PIDs only.
    private var metadataCache: [Int32: ResolvedProcessMetadata] = [:]
    private var lastPopoverLayoutSignature: PopoverLayoutSignature?

    private enum Keys {
        static let displayMode = "menuBarDisplayMode"
        static let updateInterval = "updateIntervalSeconds"
        static let orderUpdateInterval = "orderUpdateIntervalSeconds"
    }

    private let samplingQueue = DispatchQueue(label: "com.local.MenuBarStats.sampling", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var quickPopoverTimer: DispatchWorkItem?
    private var workspaceObservers: [NSObjectProtocol] = []

    // Accessed only on samplingQueue
    private var previousCPUTicks: CPUCoreTicks?
    private var previousProcessCPUTimes: [Int32: (name: String, cpuTime: Double)] = [:]
    private var previousProcessCPUTimestamp: TimeInterval?
    private var previousProcessGPUTimes: [Int32: (name: String, ns: UInt64)] = [:]
    private var previousProcessGPUTimestamp: TimeInterval?
    private var lastOrderUpdateTimestamp: TimeInterval?
    private var lastDiskSampleTimestamp: TimeInterval?
    private var displayedTopCPU: [ProcessMetric] = []
    private var displayedTopGPU: [ProcessMetric] = []
    private var cpuHistoryTracker = ProcessHistoryTracker(windowSeconds: SystemMonitor.processGraphWindowSeconds)
    private var gpuHistoryTracker = ProcessHistoryTracker(windowSeconds: SystemMonitor.processGraphWindowSeconds)

    init() {
        let savedMode = UserDefaults.standard.string(forKey: Keys.displayMode).flatMap(MenuBarDisplayMode.init(rawValue:)) ?? .percent
        let savedInterval = UpdateIntervalOption(rawValue: UserDefaults.standard.double(forKey: Keys.updateInterval)) ?? .twoSeconds
        let savedOrderInterval = UpdateIntervalOption(rawValue: UserDefaults.standard.double(forKey: Keys.orderUpdateInterval)) ?? .threeSeconds
        self.displayMode = savedMode
        self.updateInterval = savedInterval
        self.orderUpdateInterval = savedOrderInterval
    }

    func start() {
        let recordDetailsInBackground = (displayMode == .graph)
        samplingQueue.async { [weak self] in
            self?.previousCPUTicks = Self.readSystemCPUTicks()
            if recordDetailsInBackground {
                self?.performSample(includeDetails: true)
            }
        }
        observeVolumeChanges()
        rescheduleTimer()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            guard let self else { return }
            self.sampleNow(includeDetails: self.shouldTrackProcessDetails)
        }
    }

    func stop() {
        timer?.cancel()
        timer = nil
        quickPopoverTimer?.cancel()
        quickPopoverTimer = nil
        for token in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        workspaceObservers.removeAll()
    }

    private func observeVolumeChanges() {
        guard workspaceObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.samplingQueue.async {
                    self.lastDiskSampleTimestamp = nil
                    self.performSample(includeDetails: DispatchQueue.main.sync { self.shouldTrackProcessDetails })
                }
            }
            workspaceObservers.append(token)
        }
    }

    private var shouldTrackProcessDetails: Bool {
        isPopoverOpen || displayMode == .graph
    }

    func setPopoverOpen(_ open: Bool) {
        isPopoverOpen = open
        quickPopoverTimer?.cancel()
        quickPopoverTimer = nil

        if open {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            liveIsSamplingDetails = liveTopCPU.isEmpty
            // Hydrate SwiftUI snapshot immediately before the panel measures fittingSize and appears,
            // with scroll animations disabled for this hydration frame so charts don't slide across stale gaps.
            publishPopoverState(allowScrollAnimation: false)
            lastPopoverLayoutSignature = currentPopoverLayoutSignature()

            // In Graph mode we already collect continuous Top-5 samples on the main timer;
            // only kick off an extra bootstrap burst when opening fresh from Percent mode.
            if displayMode != .graph || liveTopCPU.isEmpty {
                sampleNow(includeDetails: true)
                let work = DispatchWorkItem { [weak self] in
                    guard let self, self.isPopoverOpen else { return }
                    self.sampleNow(includeDetails: true)
                }
                quickPopoverTimer = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.75, execute: work)
            }
        } else {
            liveIsSamplingDetails = false
            lastPopoverLayoutSignature = nil
            if displayMode != .graph {
                clearDetailBaselines()
            }
        }
    }

    private func currentPopoverLayoutSignature() -> PopoverLayoutSignature {
        PopoverLayoutSignature(
            displayMode: displayMode,
            topCPUCount: popoverState.topCPU.count,
            topGPUCount: popoverState.topGPU.count,
            disksCount: popoverState.disks.count,
            isSamplingDetails: popoverState.isSamplingDetails
        )
    }

    private func notifyPopoverLayoutIfNeeded() {
        let sig = currentPopoverLayoutSignature()
        if sig != lastPopoverLayoutSignature {
            lastPopoverLayoutSignature = sig
            onPopoverLayoutChanged?()
        }
    }

    private func publishPopoverState(allowScrollAnimation: Bool) {
        var icons: [Int32: NSImage] = [:]
        icons.reserveCapacity(liveTopCPU.count + liveTopGPU.count)

        let resolvedCPU = resolveDisplayProcesses(liveTopCPU, into: &icons)
        let resolvedGPU = resolveDisplayProcesses(liveTopGPU, into: &icons)

        if metadataCache.count > 64 {
            var activePIDs = Set<Int32>()
            for p in resolvedCPU { activePIDs.insert(p.pid) }
            for p in resolvedGPU { activePIDs.insert(p.pid) }
            metadataCache = metadataCache.filter { activePIDs.contains($0.key) }
        }

        popoverState = PopoverSnapshot(
            cpuPercent: liveCPUPercent,
            gpuPercent: liveGPUPercent,
            diskUsage: liveDiskUsage,
            disks: liveDisks,
            cpuHistory: liveCPUHistory,
            gpuHistory: liveGPUHistory,
            topCPU: resolvedCPU,
            topGPU: resolvedGPU,
            cpuProcessHistory: liveCPUProcessHistory,
            gpuProcessHistory: liveGPUProcessHistory,
            processIcons: icons,
            latestSampleTime: liveLatestSampleTime,
            isSamplingDetails: liveIsSamplingDetails,
            allowScrollAnimation: allowScrollAnimation
        )
    }

    private func resolveDisplayProcesses(
        _ raw: [ProcessMetric],
        into icons: inout [Int32: NSImage]
    ) -> [ProcessMetric] {
        raw.map { proc in
            let meta: ResolvedProcessMetadata
            if let cached = metadataCache[proc.pid], cached.rawName == proc.name {
                meta = cached
            } else {
                let app = NSRunningApplication(processIdentifier: proc.pid)
                let created = ResolvedProcessMetadata(
                    rawName: proc.name,
                    displayName: app?.localizedName ?? proc.name,
                    icon: app?.icon
                )
                metadataCache[proc.pid] = created
                meta = created
            }
            if let icon = meta.icon {
                icons[proc.pid] = icon
            }
            return ProcessMetric(pid: proc.pid, name: meta.displayName, percent: proc.percent)
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Keep UI aligned with actual registration status
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func clearDetailBaselines() {
        samplingQueue.async { [weak self] in
            self?.previousProcessCPUTimes.removeAll()
            self?.previousProcessCPUTimestamp = nil
            self?.previousProcessGPUTimes.removeAll()
            self?.previousProcessGPUTimestamp = nil
            self?.lastOrderUpdateTimestamp = nil
            self?.displayedTopCPU.removeAll()
            self?.displayedTopGPU.removeAll()
            self?.cpuHistoryTracker.clear()
            self?.gpuHistoryTracker.clear()
        }
    }

    private func rescheduleTimer() {
        timer?.cancel()
        let source = DispatchSource.makeTimerSource(queue: samplingQueue)
        let interval = updateInterval.rawValue
        source.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(100))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let wantDetails = DispatchQueue.main.sync { self.shouldTrackProcessDetails }
            self.performSample(includeDetails: wantDetails)
        }
        source.resume()
        timer = source
    }

    private func sampleNow(includeDetails: Bool) {
        samplingQueue.async { [weak self] in
            self?.performSample(includeDetails: includeDetails)
        }
    }

    private func performSample(includeDetails: Bool) {
        let now = ProcessInfo.processInfo.systemUptime

        // 1. System CPU % (Mach host_processor_info — zero subprocesses)
        let currentTicks = Self.readSystemCPUTicks()
        let cpuPct: Double
        if let prev = previousCPUTicks, let cur = currentTicks {
            cpuPct = MetricsMath.cpuPercent(previous: prev, current: cur)
        } else {
            cpuPct = 0
        }
        previousCPUTicks = currentTicks

        // 2. System GPU % (and per-process GPU times when popover is open or graph mode is active)
        let gpuSnapshot = Self.readGPUMetrics(includePerProcess: includeDetails)
        let gpuPct = gpuSnapshot.deviceUtilization

        // 3. Mounted local disks (boot volume + connected external SSDs, refreshed every 10s or on mount/unmount)
        var nextDisks: [DiskUsage]?
        if lastDiskSampleTimestamp == nil || (now - (lastDiskSampleTimestamp ?? 0) >= 10.0) {
            nextDisks = Self.readMountedDisks()
            lastDiskSampleTimestamp = now
        }

        var nextTopCPU: [ProcessMetric]?
        var nextTopGPU: [ProcessMetric]?
        var nextCPUSeries: [Int32: [TimedSample]]?
        var nextGPUSeries: [Int32: [TimedSample]]?

        if includeDetails {
            // Guard against ultra-short intervals (< 0.45s) that can cause noisy cputime spikes.
            let canComputeDetails = (previousProcessCPUTimestamp == nil) || (now - (previousProcessCPUTimestamp ?? 0) >= 0.45)
            if canComputeDetails {
                let orderIntervalSec = DispatchQueue.main.sync { self.orderUpdateInterval.rawValue }
                let shouldReorder = (lastOrderUpdateTimestamp == nil) || (now - (lastOrderUpdateTimestamp ?? 0) >= orderIntervalSec - 0.05)

                // Per-process GPU %
                if let prevTs = previousProcessGPUTimestamp {
                    let allGPUMetrics = MetricsMath.gpuAllDeltas(
                        previous: previousProcessGPUTimes,
                        current: gpuSnapshot.processGPUTimesNs,
                        elapsedSeconds: now - prevTs
                    )
                    let latestTop = MetricsMath.topProcesses(from: allGPUMetrics, limit: 5)
                    var allGPUByPID: [Int32: Double] = [:]
                    for m in allGPUMetrics { allGPUByPID[m.pid] = m.percent }
                    displayedTopGPU = MetricsMath.mergeDisplayedOrder(
                        currentOrder: displayedTopGPU,
                        latestTop: latestTop,
                        allCurrentValues: allGPUByPID,
                        shouldReorder: shouldReorder
                    )
                    gpuHistoryTracker.record(topProcesses: latestTop + displayedTopGPU, allCurrentValues: allGPUByPID, at: now)
                    nextTopGPU = displayedTopGPU
                    nextGPUSeries = gpuHistoryTracker.series
                } else {
                    nextTopGPU = displayedTopGPU
                    nextGPUSeries = gpuHistoryTracker.series
                }
                previousProcessGPUTimes = gpuSnapshot.processGPUTimesNs
                previousProcessGPUTimestamp = now

                // Per-process CPU % via /bin/ps (sees WindowServer & all system processes without root)
                let psSnapshot = Self.readProcessCPUSnapshot()
                var allCPUByPID: [Int32: Double] = [:]
                let latestTop: [ProcessMetric]
                if let prevTs = previousProcessCPUTimestamp, now - prevTs >= 0.45 {
                    let dt = now - prevTs
                    var deltas: [ProcessMetric] = []
                    deltas.reserveCapacity(psSnapshot.count)
                    for (pid, entry) in psSnapshot {
                        let pct: Double
                        if let prev = previousProcessCPUTimes[pid], entry.cpuTime >= prev.cpuTime {
                            pct = ((entry.cpuTime - prev.cpuTime) / dt) * 100.0
                        } else {
                            pct = entry.instantCPU
                        }
                        allCPUByPID[pid] = pct
                        if pct >= 0.05 {
                            deltas.append(ProcessMetric(pid: pid, name: entry.name, percent: pct))
                        }
                    }
                    latestTop = MetricsMath.topProcesses(from: deltas, limit: 5)
                } else {
                    var instant: [ProcessMetric] = []
                    instant.reserveCapacity(psSnapshot.count)
                    for (pid, entry) in psSnapshot {
                        allCPUByPID[pid] = entry.instantCPU
                        instant.append(ProcessMetric(pid: pid, name: entry.name, percent: entry.instantCPU))
                    }
                    latestTop = MetricsMath.topProcesses(from: instant, limit: 5)
                }
                displayedTopCPU = MetricsMath.mergeDisplayedOrder(
                    currentOrder: displayedTopCPU,
                    latestTop: latestTop,
                    allCurrentValues: allCPUByPID,
                    shouldReorder: shouldReorder
                )
                cpuHistoryTracker.record(topProcesses: latestTop + displayedTopCPU, allCurrentValues: allCPUByPID, at: now)
                nextTopCPU = displayedTopCPU
                nextCPUSeries = cpuHistoryTracker.series

                if shouldReorder {
                    lastOrderUpdateTimestamp = now
                }
                previousProcessCPUTimes = psSnapshot.mapValues { ($0.name, $0.cpuTime) }
                previousProcessCPUTimestamp = now
            }
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.liveCPUPercent = cpuPct
            self.liveGPUPercent = gpuPct
            if let nextDisks {
                self.liveDisks = nextDisks
                if let boot = nextDisks.first(where: { $0.mountPath == "/" }) ?? nextDisks.first {
                    self.liveDiskUsage = boot
                }
            }
            self.liveCPUHistory.append(cpuPct)
            self.liveGPUHistory.append(gpuPct)
            if let nextTopCPU { self.liveTopCPU = nextTopCPU }
            if let nextTopGPU { self.liveTopGPU = nextTopGPU }
            if let nextCPUSeries {
                self.liveCPUProcessHistory = nextCPUSeries
                self.liveLatestSampleTime = now
            }
            if let nextGPUSeries {
                self.liveGPUProcessHistory = nextGPUSeries
                self.liveLatestSampleTime = now
            }
            if includeDetails { self.liveIsSamplingDetails = false }

            // Always update the lightweight AppKit menu bar canvas.
            self.onMenuBarNeedsUpdate?()

            // Only publish to SwiftUI and check panel sizing while the popup is actually visible.
            if self.isPopoverOpen {
                self.publishPopoverState(allowScrollAnimation: true)
                self.notifyPopoverLayoutIfNeeded()
            }
        }
    }

    // MARK: - Native System CPU via Mach host_processor_info

    private static func readSystemCPUTicks() -> CPUCoreTicks? {
        var cpuCount: natural_t = 0
        var cpuInfo: processor_info_array_t?
        var cpuInfoCount: mach_msg_type_number_t = 0

        let result = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &cpuCount,
            &cpuInfo,
            &cpuInfoCount
        )
        guard result == KERN_SUCCESS, let info = cpuInfo else { return nil }
        defer {
            let size = vm_size_t(cpuInfoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), size)
        }

        var user: UInt64 = 0
        var system: UInt64 = 0
        var idle: UInt64 = 0
        var nice: UInt64 = 0

        let stride = Int(CPU_STATE_MAX)
        for core in 0..<Int(cpuCount) {
            let base = core * stride
            user &+= UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]))
            system &+= UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]))
            idle &+= UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]))
            nice &+= UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]))
        }
        return CPUCoreTicks(user: user, system: system, idle: idle, nice: nice)
    }

    // MARK: - Native System & Per-Process GPU via IOKit IOAccelerator

    private struct GPUSnapshot {
        let deviceUtilization: Double
        let processGPUTimesNs: [Int32: (name: String, ns: UInt64)]
    }

    private static func readGPUMetrics(includePerProcess: Bool) -> GPUSnapshot {
        var iterator: io_iterator_t = 0
        guard let matching = IOServiceMatching("IOAccelerator") else {
            return GPUSnapshot(deviceUtilization: 0, processGPUTimesNs: [:])
        }
        let kr = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
        guard kr == KERN_SUCCESS else {
            return GPUSnapshot(deviceUtilization: 0, processGPUTimesNs: [:])
        }
        defer { IOObjectRelease(iterator) }

        var maxUtilization: Double = 0
        var byPID: [Int32: (name: String, ns: UInt64)] = [:]

        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }

            var unmanagedProps: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(service, &unmanagedProps, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let dict = unmanagedProps?.takeRetainedValue() as? [String: Any],
               let perf = dict["PerformanceStatistics"] as? [String: Any] {
                if let util = (perf["Device Utilization %"] as? NSNumber)?.doubleValue {
                    maxUtilization = max(maxUtilization, util)
                } else if let util = (perf["GPU Activity(%)"] as? NSNumber)?.doubleValue {
                    maxUtilization = max(maxUtilization, util)
                }
            }

            guard includePerProcess else { continue }

            var childIter: io_iterator_t = 0
            if IORegistryEntryGetChildIterator(service, kIOServicePlane, &childIter) == KERN_SUCCESS {
                defer { IOObjectRelease(childIter) }
                var child = IOIteratorNext(childIter)
                while child != 0 {
                    defer {
                        IOObjectRelease(child)
                        child = IOIteratorNext(childIter)
                    }
                    var childProps: Unmanaged<CFMutableDictionary>?
                    guard IORegistryEntryCreateCFProperties(child, &childProps, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                          let cdict = childProps?.takeRetainedValue() as? [String: Any],
                          let appUsage = cdict["AppUsage"] as? [[String: Any]],
                          let creator = cdict["IOUserClientCreator"] as? String,
                          let parsed = MetricsMath.parseIOUserClientCreator(creator) else {
                        continue
                    }
                    var totalNs: UInt64 = 0
                    for entry in appUsage {
                        if let val = (entry["accumulatedGPUTime"] as? NSNumber)?.uint64Value {
                            totalNs &+= val
                        }
                    }
                    if totalNs > 0 {
                        if let existing = byPID[parsed.pid] {
                            byPID[parsed.pid] = (existing.name, existing.ns &+ totalNs)
                        } else {
                            byPID[parsed.pid] = (parsed.name, totalNs)
                        }
                    }
                }
            }
        }

        return GPUSnapshot(
            deviceUtilization: min(max(maxUtilization, 0), 100),
            processGPUTimesNs: byPID
        )
    }

    // MARK: - Mounted Local Disks via Foundation Volume Resource Values

    private static func readMountedDisks() -> [DiskUsage] {
        let keys: [URLResourceKey] = [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
            .volumeIsInternalKey,
            .volumeIsLocalKey,
            .volumeIsReadOnlyKey,
        ]
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) ?? [URL(fileURLWithPath: "/")]

        var result: [DiskUsage] = []
        var seenPaths = Set<String>()

        for url in urls {
            let path = url.path
            guard !seenPaths.contains(path),
                  let values = try? url.resourceValues(forKeys: Set(keys)) else {
                continue
            }
            // Include boot volume and writable local volumes (skip read-only DMGs and network mounts)
            let isBoot = (path == "/")
            let isLocal = values.volumeIsLocal ?? isBoot
            let isReadOnly = values.volumeIsReadOnly ?? false
            let total = Int64(values.volumeTotalCapacity ?? 0)
            guard isBoot || (isLocal && !isReadOnly && total > 0) else { continue }

            let name = values.volumeName ?? (isBoot ? "Macintosh HD" : url.lastPathComponent)
            let immediateFree = Int64(values.volumeAvailableCapacity ?? 0)
            let available = values.volumeAvailableCapacityForImportantUsage ?? immediateFree
            let isInternal = values.volumeIsInternal ?? isBoot

            seenPaths.insert(path)
            result.append(DiskUsage(
                mountPath: path,
                volumeName: name,
                totalBytes: total,
                availableBytes: min(max(0, available), total),
                immediateFreeBytes: min(max(0, immediateFree), total),
                isInternal: isInternal
            ))
        }

        // Always keep boot volume ("/") first, followed by other connected drives alphabetically.
        result.sort { lhs, rhs in
            if lhs.mountPath == "/" { return true }
            if rhs.mountPath == "/" { return false }
            return lhs.volumeName.localizedCaseInsensitiveCompare(rhs.volumeName) == .orderedAscending
        }
        return result.isEmpty ? [.empty] : result
    }

    // MARK: - Per-Process CPU via /bin/ps

    private static func readProcessCPUSnapshot() -> [Int32: (name: String, cpuTime: Double, instantCPU: Double)] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-axo", "pid=,%cpu=,cputime=,comm="]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
        } catch {
            return [:]
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        guard let output = String(data: data, encoding: .utf8) else { return [:] }
        return MetricsMath.parsePSSnapshot(output)
    }
}
