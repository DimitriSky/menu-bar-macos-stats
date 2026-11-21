import Foundation

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
    print("PASS: \(message)")
}

// 1. CPU delta calculation
let prev = CPUCoreTicks(user: 1000, system: 200, idle: 8800, nice: 0)
let next = CPUCoreTicks(user: 1150, system: 250, idle: 9400, nice: 0)
let cpu = MetricsMath.cpuPercent(previous: prev, current: next)
check(abs(cpu - 25.0) < 0.001, "CPU delta computes 25%")
check(MetricsMath.cpuPercent(previous: next, current: next) == 0, "Zero delta returns 0%")

// 2. IOUserClientCreator parsing
let creator = MetricsMath.parseIOUserClientCreator("pid 447, WindowServer")
check(creator?.pid == 447 && creator?.name == "WindowServer", "Parses standard IOUserClientCreator")
let creatorWithComma = MetricsMath.parseIOUserClientCreator("pid 18964, Browser Helper (GPU)")
check(creatorWithComma?.pid == 18964 && creatorWithComma?.name == "Browser Helper (GPU)", "Parses helper name")
check(MetricsMath.parseIOUserClientCreator("invalid") == nil, "Rejects malformed IOUserClientCreator")

// 3. ps line parsing
let ps1 = MetricsMath.parsePSLine("  447  40.5  6717:12.54 /System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer")
check(ps1?.pid == 447, "Parses ps PID")
check(abs((ps1?.instantCPU ?? 0) - 40.5) < 0.01, "Parses ps instant CPU")
check(abs((ps1?.cpuTimeSeconds ?? 0) - (6717.0 * 60.0 + 12.54)) < 0.01, "Parses ps cumulative time")
check(ps1?.name == "WindowServer", "Extracts executable basename")

let psSpace = MetricsMath.parsePSLine(" 44349  14.8   27:19.06 /Applications/Antigravity.app/Contents/Frameworks/Antigravity Helper.app/Contents/MacOS/Antigravity Helper")
check(psSpace?.name == "Antigravity Helper", "Preserves spaces in executable name")

// 4. GPU delta & Top 5 limit
var prevGPU: [Int32: (name: String, ns: UInt64)] = [:]
var curGPU: [Int32: (name: String, ns: UInt64)] = [:]
for i in 1...8 {
    prevGPU[Int32(i)] = ("Proc\(i)", 1_000_000_000)
    curGPU[Int32(i)] = ("Proc\(i)", 1_000_000_000 + UInt64(i) * 100_000_000)
}
let topGPU = MetricsMath.gpuDeltas(previous: prevGPU, current: curGPU, elapsedSeconds: 2.0)
check(topGPU.count == 5, "Top GPU capped at 5")
check(topGPU[0].pid == 8 && abs(topGPU[0].percent - 40.0) < 0.01, "Highest GPU consumer is first")
check(topGPU[4].pid == 4 && abs(topGPU[4].percent - 20.0) < 0.01, "Fifth GPU consumer is accurate")

// 5. History ring buffer
var hist = MetricHistory(capacity: 5)
for v in [10.0, 20.0, 30.0, 40.0, 50.0, 60.0] { hist.append(v) }
check(hist.values == [20.0, 30.0, 40.0, 50.0, 60.0], "History buffer keeps latest N samples")
let visibleStart = hist.latestPosition - hist.visibleSpan
hist.append(60.0)
check(hist.latestPosition == 7, "Scroll position advances even when the reading repeats")
check(hist.samples.first == TimedSample(time: visibleStart, value: 20.0),
      "Scrolling history keeps the point leaving the left edge")
hist.append(150.0)
hist.append(-5.0)
check(hist.values.suffix(2) == [100.0, 0.0], "History clamps values to 0...100")

// 6. Per-process 10s rolling history tracker
var tracker = ProcessHistoryTracker(windowSeconds: 10.0)
let p1 = ProcessMetric(pid: 447, name: "WindowServer", percent: 35.0)
let p2 = ProcessMetric(pid: 100, name: "AppA", percent: 10.0)
tracker.record(topProcesses: [p1, p2], allCurrentValues: [447: 35.0, 100: 10.0], at: 100.0)
tracker.record(topProcesses: [p1], allCurrentValues: [447: 20.0, 100: 1.0], at: 105.0)
tracker.record(topProcesses: [p1], allCurrentValues: [447: 15.0], at: 114.0)
check(tracker.series[447]?.count == 3, "Keeps 10s window + smooth slide buffer for active Top-5 process")
check(tracker.series[100] == nil, "Prunes processes that dropped out of Top 5 more than 13s ago")
tracker.record(topProcesses: [p1], allCurrentValues: [447: 12.0], at: 120.0)
check(tracker.series[447]?.map(\.time) == [105.0, 114.0, 120.0], "Drops samples older than slide buffer of 10s window")

// 7. Decoupled Top-5 row order update
let existingOrder = [
    ProcessMetric(pid: 447, name: "WindowServer", percent: 40.0),
    ProcessMetric(pid: 100, name: "AppA", percent: 15.0),
]
let newTop = [
    ProcessMetric(pid: 100, name: "AppA", percent: 55.0),
    ProcessMetric(pid: 447, name: "WindowServer", percent: 25.0),
]
let held = MetricsMath.mergeDisplayedOrder(
    currentOrder: existingOrder,
    latestTop: newTop,
    allCurrentValues: [447: 25.0, 100: 55.0],
    shouldReorder: false
)
check(held.map(\.pid) == [447, 100], "Preserves row order between order-update ticks")
check(abs(held[0].percent - 25.0) < 0.01 && abs(held[1].percent - 55.0) < 0.01, "Refreshes live percentages while order is held")
let reordered = MetricsMath.mergeDisplayedOrder(
    currentOrder: existingOrder,
    latestTop: newTop,
    allCurrentValues: [447: 25.0, 100: 55.0],
    shouldReorder: true
)
check(reordered.map(\.pid) == [100, 447], "Reorders rows when order-update tick fires")

let filled = MetricsMath.mergeDisplayedOrder(
    currentOrder: [ProcessMetric(pid: 447, name: "WindowServer", percent: 20.0)],
    latestTop: [
        ProcessMetric(pid: 100, name: "TalkTo", percent: 30.0),
        ProcessMetric(pid: 447, name: "WindowServer", percent: 20.0),
    ],
    allCurrentValues: [447: 20.0, 100: 30.0],
    shouldReorder: false
)
check(filled.map(\.pid) == [447, 100], "Fills empty slots (<5) without reordering existing rows")

// 8. Disk usage formatting and percentage
let disk = DiskUsage(volumeName: "Macintosh HD", totalBytes: 500_000_000_000, availableBytes: 125_000_000_000, immediateFreeBytes: 100_000_000_000)
check(abs(disk.usedPercent - 75.0) < 0.01, "Disk usedPercent computes 75%")
check(DiskUsage.formatGigabytes(disk.availableBytes) == "125 GB", "Formats >=100 GB cleanly")
check(DiskUsage.formatGigabytes(42_500_000_000) == "42.5 GB", "Formats <100 GB with 1 decimal")
check(DiskUsage.formatGigabytes(1_000_202_272_768) == "1.0 TB", "Formats >=1 TB cleanly")

// 9. ProcessInspector parsing helpers
let headerLine = "  447     1 _windowserver  40.5  1.1 174496 740605259 R   0 15-04:39:16 6716:56.12 Fri Nov  6 11:53:38 2026"
let parsedHeader = ProcessInspectorMath.parsePSHeaderLine(headerLine)
check(parsedHeader?.pid == 447 && parsedHeader?.ppid == 1 && parsedHeader?.user == "_windowserver", "Parses ps detail header")
check(abs((parsedHeader?.cpuPercent ?? 0) - 40.5) < 0.01 && parsedHeader?.rssBytes == 174496 * 1024, "Parses ps CPU and RSS bytes")
check(parsedHeader?.started == "Fri Nov  6 11:53:38 2026", "Preserves lstart date string")

let threadsOut = """
USER            PID   TT   %CPU STAT PRI     STIME     UTIME COMMAND
_windowserver   447   ??   33.7 R    79R 869:06.03 5060:46.94 /System/Library/WindowServer
                447         0.3 S    79R  16:20.23  29:15.96
                447         3.9 S    79R 195:57.62 194:35.31
"""
let parsedThreads = ProcessInspectorMath.parsePSThreadsOutput(threadsOut)
check(parsedThreads.count == 3 && abs(parsedThreads[0].cpuPercent - 33.7) < 0.01 && abs(parsedThreads[1].cpuPercent - 3.9) < 0.01, "Parses and sorts ps -M thread CPU")

let lsofOut = """
p1234
fcwd
tDIR
n/Users/test/project
f3
tREG
n/Users/test/project/app.log
f4
tIPv4
n127.0.0.1:8080 (LISTEN)
"""
let lsof = ProcessInspectorMath.parseLsofOutput(lsofOut)
check(lsof.cwd == "/Users/test/project", "Parses lsof cwd")
check(lsof.sockets == ["[IPv4] 127.0.0.1:8080 (LISTEN)"], "Parses lsof sockets")
check(lsof.sampleFiles == ["/Users/test/project/app.log"], "Parses lsof regular files")

print("All MenuBarStats unit tests passed")
