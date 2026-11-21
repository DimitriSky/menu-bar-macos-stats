import AppKit
import CoreGraphics
import Darwin
import Foundation
import IOKit

struct ProcessThreadInfo: Identifiable, Equatable {
    let index: Int
    let cpuPercent: Double
    let state: String
    let priority: String
    let sysTime: String
    let userTime: String

    var id: Int { index }
}

struct ProcessWindowInfo: Identifiable, Equatable {
    let windowID: Int
    let layer: Int
    let isOnScreen: Bool
    let alpha: Double
    let bounds: CGRect
    let memoryBytes: Int
    let title: String

    var id: Int { windowID }
}

struct ProcessLsofSummary: Equatable {
    let cwd: String?
    let totalOpenFiles: Int
    let sockets: [String]
    let sampleFiles: [String]
    let restricted: Bool
}

struct ProcessTaskRates: Equatable {
    let physFootprintBytes: UInt64
    let diskReadBytes: UInt64
    let diskWriteBytes: UInt64
    let idleWakeups: UInt64
    let pageFaults: Int32
    let cswPerSec: Double?
    let machSentPerSec: Double?
    let machRecvPerSec: Double?
    let restricted: Bool
}

struct ProcessDetailSnapshot: Equatable {
    let pid: Int32
    let ppid: Int32
    let parentName: String
    let user: String
    let name: String
    let bundleID: String?
    let bundleURL: URL?
    let executablePath: String
    let commandLine: String
    let state: String
    let nice: String
    let uptime: String
    let started: String
    let cpuPercent: Double
    let cumulativeCPUTime: String
    let memPercent: Double
    let rssBytes: Int64
    let vszBytes: Int64
    let gpuPercent: Double
    let lifetimeGPUSeconds: Double
    let threads: [ProcessThreadInfo]
    let windows: [ProcessWindowInfo]
    let taskRates: ProcessTaskRates
    let isGUIApp: Bool
    let isHidden: Bool
    let isOwnedByCurrentUser: Bool
    let isAlive: Bool
}

enum ProcessInspectorMath {
    static func formatBytes(_ bytes: UInt64) -> String {
        let b = Double(bytes)
        if b >= 1_000_000_000 { return String(format: "%.2f GB", b / 1_000_000_000) }
        if b >= 1_000_000 { return String(format: "%.1f MB", b / 1_000_000) }
        if b >= 1_000 { return String(format: "%.0f KB", b / 1_000) }
        return "\(bytes) B"
    }

    static func formatDurationSeconds(_ seconds: Double) -> String {
        guard seconds > 0.005 else { return "0.0s" }
        if seconds >= 3600 {
            let h = Int(seconds) / 3600
            let m = (Int(seconds) % 3600) / 60
            return "\(h)h \(m)m"
        }
        if seconds >= 60 {
            let m = Int(seconds) / 60
            let s = Int(seconds) % 60
            return "\(m)m \(s)s"
        }
        return String(format: "%.1fs", seconds)
    }

    struct PSHeaderInfo: Equatable {
        let pid: Int32
        let ppid: Int32
        let user: String
        let cpuPercent: Double
        let memPercent: Double
        let rssBytes: Int64
        let vszBytes: Int64
        let state: String
        let nice: String
        let uptime: String
        let cpuTime: String
        let started: String
    }

    static func parsePSHeaderLine(_ line: String) -> PSHeaderInfo? {
        // Expected fields from: ps -p <pid> -o pid=,ppid=,user=,%cpu=,%mem=,rss=,vsz=,state=,nice=,etime=,cputime=,lstart=
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(maxSplits: 11, omittingEmptySubsequences: true, whereSeparator: { $0.isWhitespace })
        guard parts.count == 12,
              let pid = Int32(parts[0]),
              let ppid = Int32(parts[1]),
              let cpu = Double(parts[3]),
              let mem = Double(parts[4]),
              let rssKB = Int64(parts[5]),
              let vszKB = Int64(parts[6]) else {
            return nil
        }
        return PSHeaderInfo(
            pid: pid,
            ppid: ppid,
            user: String(parts[2]),
            cpuPercent: cpu,
            memPercent: mem,
            rssBytes: rssKB * 1024,
            vszBytes: vszKB * 1024,
            state: describeState(String(parts[7])),
            nice: String(parts[8]),
            uptime: String(parts[9]),
            cpuTime: String(parts[10]),
            started: String(parts[11]).trimmingCharacters(in: .whitespaces)
        )
    }

    static func describeState(_ raw: String) -> String {
        guard let first = raw.first else { return raw }
        switch first {
        case "R": return "Running (\(raw))"
        case "S": return "Sleeping (\(raw))"
        case "I": return "Idle (\(raw))"
        case "U": return "Uninterruptible (\(raw))"
        case "T": return "Stopped (\(raw))"
        case "Z": return "Zombie (\(raw))"
        default: return raw
        }
    }

    static func parsePSThreadsOutput(_ output: String) -> [ProcessThreadInfo] {
        // Header: USER PID TT %CPU STAT PRI STIME UTIME COMMAND
        let lines = output.split(whereSeparator: \.isNewline)
        guard lines.count > 1 else { return [] }
        var threads: [ProcessThreadInfo] = []
        for (idx, rawLine) in lines.dropFirst().enumerated() {
            let parts = rawLine.split(omittingEmptySubsequences: true, whereSeparator: { $0.isWhitespace })
            // First row has USER PID TT %CPU STAT PRI STIME UTIME COMMAND...
            // Subsequent rows have PID %CPU STAT PRI STIME UTIME
            if idx == 0, parts.count >= 8, let cpu = Double(parts[3]) {
                threads.append(ProcessThreadInfo(
                    index: idx,
                    cpuPercent: cpu,
                    state: String(parts[4]),
                    priority: String(parts[5]),
                    sysTime: String(parts[6]),
                    userTime: String(parts[7])
                ))
            } else if parts.count >= 6, let cpu = Double(parts[1]) {
                threads.append(ProcessThreadInfo(
                    index: idx,
                    cpuPercent: cpu,
                    state: String(parts[2]),
                    priority: String(parts[3]),
                    sysTime: String(parts[4]),
                    userTime: String(parts[5])
                ))
            }
        }
        return threads.sorted { lhs, rhs in
            if lhs.cpuPercent != rhs.cpuPercent { return lhs.cpuPercent > rhs.cpuPercent }
            return lhs.index < rhs.index
        }
    }

    static func parseLsofOutput(_ output: String) -> ProcessLsofSummary {
        // Parses `lsof -nP -F ftn -p <pid>` field output:
        // f<fd>, t<type>, n<name>
        var cwd: String?
        var openFiles = 0
        var sockets: [String] = []
        var sampleFiles: [String] = []

        var curFD: String?
        var curType: String?
        var curName: String?

        func flushEntry() {
            guard let fd = curFD, let name = curName else { return }
            if fd == "cwd" {
                cwd = name
            } else if curType == "IPv4" || curType == "IPv6" || curType == "unix" {
                openFiles += 1
                if sockets.count < 40 && !name.isEmpty {
                    let prefix = curType ?? "sock"
                    sockets.append("[\(prefix)] \(name)")
                }
            } else if curType == "REG" || curType == "DIR" || curType == "VREG" {
                openFiles += 1
                if fd != "txt" && sampleFiles.count < 30 && name.hasPrefix("/") {
                    sampleFiles.append(name)
                }
            } else if fd.first?.isNumber == true {
                openFiles += 1
            }
            curFD = nil
            curType = nil
            curName = nil
        }

        for rawLine in output.split(whereSeparator: \.isNewline) {
            guard let tag = rawLine.first else { continue }
            let val = String(rawLine.dropFirst())
            switch tag {
            case "f":
                flushEntry()
                curFD = val
            case "t":
                curType = val
            case "n":
                curName = val
            default:
                break
            }
        }
        flushEntry()

        return ProcessLsofSummary(
            cwd: cwd,
            totalOpenFiles: openFiles,
            sockets: sockets,
            sampleFiles: sampleFiles,
            restricted: false
        )
    }
}

final class ProcessInspectorModel: ObservableObject {
    @Published private(set) var detail: ProcessDetailSnapshot?
    @Published private(set) var lsofSummary: ProcessLsofSummary?
    @Published private(set) var isLoadingLsof = false
    @Published private(set) var sampleOutput: String?
    @Published private(set) var isRunningSample = false

    private let queue = DispatchQueue(label: "com.local.MenuBarStats.inspector", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var targetPID: Int32 = 0
    private var fallbackName: String = ""

    // Delta state (queue-only)
    private var prevTimestamp: TimeInterval?
    private var prevGPUns: UInt64?
    private var prevCSW: Int32?
    private var prevMachSent: Int32?
    private var prevMachRecv: Int32?

    func inspect(pid: Int32, name: String) {
        stop()
        targetPID = pid
        fallbackName = name
        lsofSummary = nil
        sampleOutput = nil
        isRunningSample = false

        queue.async { [weak self] in
            self?.prevTimestamp = nil
            self?.prevGPUns = nil
            self?.prevCSW = nil
            self?.prevMachSent = nil
            self?.prevMachRecv = nil
            self?.refreshSnapshot()
        }

        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + 2.0, repeating: 2.0, leeway: .milliseconds(150))
        source.setEventHandler { [weak self] in
            self?.refreshSnapshot()
        }
        source.resume()
        timer = source
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    func refreshLsof() {
        let pid = targetPID
        guard pid > 0 else { return }
        DispatchQueue.main.async { self.isLoadingLsof = true }
        queue.async { [weak self] in
            let summary = Self.readLsof(pid: pid)
            DispatchQueue.main.async {
                guard let self, self.targetPID == pid else { return }
                self.lsofSummary = summary
                self.isLoadingLsof = false
            }
        }
    }

    func runOneSecondSample() {
        let pid = targetPID
        guard pid > 0, !isRunningSample else { return }
        DispatchQueue.main.async {
            self.isRunningSample = true
            self.sampleOutput = nil
        }
        queue.async { [weak self] in
            let text = Self.captureSample(pid: pid)
            DispatchQueue.main.async {
                guard let self, self.targetPID == pid else { return }
                self.sampleOutput = text
                self.isRunningSample = false
            }
        }
    }

    func revealInFinder() {
        guard let detail else { return }
        let url = detail.bundleURL ?? URL(fileURLWithPath: detail.executablePath)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func activateOrToggleHide() {
        guard let app = NSRunningApplication(processIdentifier: targetPID) else { return }
        if app.isHidden {
            _ = app.unhide()
            app.activate()
        } else {
            app.activate()
        }
    }

    func hideApp() {
        guard let app = NSRunningApplication(processIdentifier: targetPID) else { return }
        _ = app.hide()
        queue.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.refreshSnapshot() }
    }

    func terminateProcess(force: Bool) {
        if let app = NSRunningApplication(processIdentifier: targetPID) {
            if force { _ = app.forceTerminate() } else { _ = app.terminate() }
        } else {
            kill(targetPID, force ? SIGKILL : SIGTERM)
        }
        queue.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.refreshSnapshot() }
    }

    private func refreshSnapshot() {
        let pid = targetPID
        guard pid > 0 else { return }
        let now = ProcessInfo.processInfo.systemUptime

        guard let header = Self.readPSHeader(pid: pid) else {
            DispatchQueue.main.async { [weak self] in
                guard let self, let existing = self.detail else { return }
                self.detail = ProcessDetailSnapshot(
                    pid: existing.pid, ppid: existing.ppid, parentName: existing.parentName,
                    user: existing.user, name: existing.name, bundleID: existing.bundleID,
                    bundleURL: existing.bundleURL, executablePath: existing.executablePath,
                    commandLine: existing.commandLine, state: "Exited", nice: existing.nice,
                    uptime: existing.uptime, started: existing.started,
                    cpuPercent: 0, cumulativeCPUTime: existing.cumulativeCPUTime,
                    memPercent: 0, rssBytes: 0, vszBytes: 0, gpuPercent: 0,
                    lifetimeGPUSeconds: existing.lifetimeGPUSeconds, threads: [], windows: [],
                    taskRates: existing.taskRates, isGUIApp: existing.isGUIApp,
                    isHidden: existing.isHidden, isOwnedByCurrentUser: existing.isOwnedByCurrentUser,
                    isAlive: false
                )
            }
            return
        }

        let execPath = Self.runCommand("/bin/ps", ["-p", "\(pid)", "-o", "comm="]).trimmingCharacters(in: .whitespacesAndNewlines)
        let cmdLine = Self.runCommand("/bin/ps", ["-p", "\(pid)", "-o", "args="]).trimmingCharacters(in: .whitespacesAndNewlines)
        let parentComm = header.ppid > 0
            ? Self.runCommand("/bin/ps", ["-p", "\(header.ppid)", "-o", "comm="]).trimmingCharacters(in: .whitespacesAndNewlines)
            : "kernel"
        let parentName = URL(fileURLWithPath: parentComm).lastPathComponent

        let runningApp = NSRunningApplication(processIdentifier: pid)
        let displayName = runningApp?.localizedName
            ?? (execPath.isEmpty ? fallbackName : URL(fileURLWithPath: execPath).lastPathComponent)

        let threads = ProcessInspectorMath.parsePSThreadsOutput(
            Self.runCommand("/bin/ps", ["-M", "-p", "\(pid)"])
        )
        let windows = Self.readWindows(pid: pid)

        // GPU lifetime + live % delta
        let gpuNs = Self.readProcessGPUTimeNs(pid: pid)
        let gpuPct: Double
        if let prevTs = prevTimestamp, let prevNs = prevGPUns, now - prevTs > 0.1, gpuNs >= prevNs {
            gpuPct = Double(gpuNs - prevNs) / ((now - prevTs) * 1_000_000_000.0) * 100.0
        } else {
            gpuPct = 0
        }
        prevGPUns = gpuNs

        // Native libproc stats (available for current-user processes)
        let rates = readTaskRates(pid: pid, now: now)
        prevTimestamp = now

        let currentUser = NSUserName()
        let owned = (header.user == currentUser)

        let snapshot = ProcessDetailSnapshot(
            pid: pid,
            ppid: header.ppid,
            parentName: parentName.isEmpty ? "PID \(header.ppid)" : parentName,
            user: header.user,
            name: displayName,
            bundleID: runningApp?.bundleIdentifier,
            bundleURL: runningApp?.bundleURL,
            executablePath: execPath,
            commandLine: cmdLine.isEmpty ? execPath : cmdLine,
            state: header.state,
            nice: header.nice,
            uptime: header.uptime,
            started: header.started,
            cpuPercent: header.cpuPercent,
            cumulativeCPUTime: header.cpuTime,
            memPercent: header.memPercent,
            rssBytes: header.rssBytes,
            vszBytes: header.vszBytes,
            gpuPercent: gpuPct,
            lifetimeGPUSeconds: Double(gpuNs) / 1_000_000_000.0,
            threads: threads,
            windows: windows,
            taskRates: rates,
            isGUIApp: runningApp?.activationPolicy == .regular,
            isHidden: runningApp?.isHidden ?? false,
            isOwnedByCurrentUser: owned,
            isAlive: true
        )

        DispatchQueue.main.async { [weak self] in
            guard let self, self.targetPID == pid else { return }
            self.detail = snapshot
        }
    }

    private func readTaskRates(pid: Int32, now: TimeInterval) -> ProcessTaskRates {
        var taskInfo = proc_taskinfo()
        let taskSize = Int32(MemoryLayout<proc_taskinfo>.size)
        let taskRes = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &taskInfo, taskSize)

        var rusage = rusage_info_v4()
        let rusageRes = withUnsafeMutablePointer(to: &rusage) { ptr -> Int32 in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(pid, RUSAGE_INFO_V4, rebound)
            }
        }

        guard taskRes == taskSize || rusageRes == 0 else {
            return ProcessTaskRates(
                physFootprintBytes: 0, diskReadBytes: 0, diskWriteBytes: 0,
                idleWakeups: 0, pageFaults: 0, cswPerSec: nil,
                machSentPerSec: nil, machRecvPerSec: nil, restricted: true
            )
        }

        var cswRate: Double?
        var sentRate: Double?
        var recvRate: Double?
        if taskRes == taskSize {
            if let prevTs = prevTimestamp, now - prevTs > 0.2 {
                let dt = now - prevTs
                if let pCSW = prevCSW, taskInfo.pti_csw >= pCSW {
                    cswRate = Double(taskInfo.pti_csw - pCSW) / dt
                }
                if let pSent = prevMachSent, taskInfo.pti_messages_sent >= pSent {
                    sentRate = Double(taskInfo.pti_messages_sent - pSent) / dt
                }
                if let pRecv = prevMachRecv, taskInfo.pti_messages_received >= pRecv {
                    recvRate = Double(taskInfo.pti_messages_received - pRecv) / dt
                }
            }
            prevCSW = taskInfo.pti_csw
            prevMachSent = taskInfo.pti_messages_sent
            prevMachRecv = taskInfo.pti_messages_received
        }

        return ProcessTaskRates(
            physFootprintBytes: rusageRes == 0 ? rusage.ri_phys_footprint : 0,
            diskReadBytes: rusageRes == 0 ? rusage.ri_diskio_bytesread : 0,
            diskWriteBytes: rusageRes == 0 ? rusage.ri_diskio_byteswritten : 0,
            idleWakeups: rusageRes == 0 ? rusage.ri_pkg_idle_wkups : 0,
            pageFaults: taskRes == taskSize ? taskInfo.pti_faults : 0,
            cswPerSec: cswRate,
            machSentPerSec: sentRate,
            machRecvPerSec: recvRate,
            restricted: false
        )
    }

    private static func readPSHeader(pid: Int32) -> ProcessInspectorMath.PSHeaderInfo? {
        let out = runCommand("/bin/ps", [
            "-p", "\(pid)", "-o",
            "pid=,ppid=,user=,%cpu=,%mem=,rss=,vsz=,state=,nice=,etime=,cputime=,lstart=",
        ])
        guard let firstLine = out.split(whereSeparator: \.isNewline).first else { return nil }
        return ProcessInspectorMath.parsePSHeaderLine(String(firstLine))
    }

    private static func readWindows(pid: Int32) -> [ProcessWindowInfo] {
        guard let list = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        var result: [ProcessWindowInfo] = []
        for w in list {
            guard (w[kCGWindowOwnerPID as String] as? Int32) == pid else { continue }
            let wid = w[kCGWindowNumber as String] as? Int ?? 0
            let layer = w[kCGWindowLayer as String] as? Int ?? 0
            let onScreen = w[kCGWindowIsOnscreen as String] as? Bool ?? false
            let alpha = w[kCGWindowAlpha as String] as? Double ?? 1.0
            let mem = w[kCGWindowMemoryUsage as String] as? Int ?? 0
            let title = w[kCGWindowName as String] as? String ?? ""
            var rect = CGRect.zero
            if let dict = w[kCGWindowBounds as String] as? NSDictionary {
                CGRectMakeWithDictionaryRepresentation(dict, &rect)
            }
            result.append(ProcessWindowInfo(
                windowID: wid, layer: layer, isOnScreen: onScreen,
                alpha: alpha, bounds: rect, memoryBytes: mem, title: title
            ))
        }
        return result.sorted { lhs, rhs in
            if lhs.isOnScreen != rhs.isOnScreen { return lhs.isOnScreen && !rhs.isOnScreen }
            return (lhs.bounds.width * lhs.bounds.height) > (rhs.bounds.width * rhs.bounds.height)
        }
    }

    private static func readProcessGPUTimeNs(pid: Int32) -> UInt64 {
        var iterator: io_iterator_t = 0
        guard let matching = IOServiceMatching("IOAccelerator"),
              IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return 0
        }
        defer { IOObjectRelease(iterator) }

        var totalNs: UInt64 = 0
        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            var childIter: io_iterator_t = 0
            guard IORegistryEntryGetChildIterator(service, kIOServicePlane, &childIter) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(childIter) }
            var child = IOIteratorNext(childIter)
            while child != 0 {
                defer {
                    IOObjectRelease(child)
                    child = IOIteratorNext(childIter)
                }
                var props: Unmanaged<CFMutableDictionary>?
                guard IORegistryEntryCreateCFProperties(child, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                      let dict = props?.takeRetainedValue() as? [String: Any],
                      let creator = dict["IOUserClientCreator"] as? String,
                      let parsed = MetricsMath.parseIOUserClientCreator(creator),
                      parsed.pid == pid,
                      let appUsage = dict["AppUsage"] as? [[String: Any]] else {
                    continue
                }
                for entry in appUsage {
                    if let val = (entry["accumulatedGPUTime"] as? NSNumber)?.uint64Value {
                        totalNs &+= val
                    }
                }
            }
        }
        return totalNs
    }

    private static func readLsof(pid: Int32) -> ProcessLsofSummary {
        let out = runCommand("/usr/sbin/lsof", ["-nP", "-F", "ftn", "-p", "\(pid)"])
        if out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ProcessLsofSummary(cwd: nil, totalOpenFiles: 0, sockets: [], sampleFiles: [], restricted: true)
        }
        return ProcessInspectorMath.parseLsofOutput(out)
    }

    private static func captureSample(pid: Int32) -> String {
        let out = runCommand("/usr/bin/sample", ["\(pid)", "1"])
        if out.isEmpty {
            return "Unable to sample PID \(pid) (restricted by macOS SIP or owned by another user)."
        }
        if let range = out.range(of: "Sort by top of stack") {
            let tail = String(out[range.lowerBound...])
            if let binRange = tail.range(of: "\nBinary Images:") {
                return String(tail[..<binRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return String(tail.prefix(2500)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(out.prefix(1500)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func runCommand(_ path: String, _ arguments: [String]) -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        do {
            try task.run()
        } catch {
            return ""
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
