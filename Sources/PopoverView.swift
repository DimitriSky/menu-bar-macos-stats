import AppKit
import SwiftUI

struct PopoverView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var monitor: SystemMonitor
    let onSelectProcess: (ProcessMetric) -> Void
    let onQuit: () -> Void

    private let cpuTint = Color(red: 0.22, green: 0.62, blue: 1.0)
    private let gpuTint = Color(red: 0.80, green: 0.36, blue: 1.0)

    private var showProcessGraphs: Bool {
        monitor.displayMode == .graph
    }

    private var scrollAnimationDuration: Double {
        min(0.42, monitor.updateInterval.rawValue * 0.45)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                // Left column: CPU summary + Top 5 CPU
                VStack(alignment: .leading, spacing: 8) {
                    metricCard(
                        label: "CPU",
                        percent: monitor.cpuPercent,
                        history: monitor.cpuHistory,
                        tint: cpuTint
                    )
                    processSection(
                        title: showProcessGraphs ? "Top 5 CPU (10s)" : "Top 5 CPU",
                        symbol: "cpu",
                        tint: cpuTint,
                        processes: monitor.topCPU,
                        historyMap: monitor.cpuProcessHistory,
                        emptyText: monitor.isSamplingDetails ? "Sampling…" : "Idle"
                    )
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)

                // Right column: GPU summary + Top 5 GPU
                VStack(alignment: .leading, spacing: 8) {
                    metricCard(
                        label: "GPU",
                        percent: monitor.gpuPercent,
                        history: monitor.gpuHistory,
                        tint: gpuTint
                    )
                    processSection(
                        title: showProcessGraphs ? "Top 5 GPU (10s)" : "Top 5 GPU",
                        symbol: "memorychip",
                        tint: gpuTint,
                        processes: monitor.topGPU,
                        historyMap: monitor.gpuProcessHistory,
                        emptyText: monitor.isSamplingDetails ? "Sampling…" : "Idle"
                    )
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }

            disksSummarySection

            Divider()

            bottomControlsRow
        }
        .padding(10)
        .frame(width: 380)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(colorScheme == .dark ? Color.black : Color.white)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func diskTint(for disk: DiskUsage) -> Color {
        let f = disk.usedFraction
        if f >= 0.90 { return Color(red: 1.0, green: 0.32, blue: 0.32) }
        if f >= 0.75 { return Color(red: 1.0, green: 0.66, blue: 0.18) }
        return Color(red: 0.22, green: 0.82, blue: 0.56)
    }

    private var disksSummarySection: some View {
        let items = monitor.disks.isEmpty ? [monitor.diskUsage] : monitor.disks
        return VStack(spacing: 5) {
            ForEach(items) { disk in
                diskRow(for: disk)
            }
        }
    }

    private func diskRow(for disk: DiskUsage) -> some View {
        let tint = diskTint(for: disk)
        let freeText = DiskUsage.formatGigabytes(disk.availableBytes)
        let totalText = DiskUsage.formatGigabytes(disk.totalBytes)
        let pctText = String(format: "%.0f%%", disk.usedPercent)
        let tooltip = "\(disk.volumeName) (\(disk.mountPath)): \(pctText) used · Total: \(totalText) · Available: \(freeText) · Immediately free: \(DiskUsage.formatGigabytes(disk.immediateFreeBytes))"

        return ZStack {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.quaternary.opacity(0.38))
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(tint.opacity(0.24))
                        .frame(width: proxy.size.width * CGFloat(disk.usedFraction))
                }
            }

            HStack(spacing: 6) {
                Image(systemName: disk.isInternal ? "internaldrive" : "externaldrive")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)

                Text(disk.volumeName)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text("· \(freeText) free")
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()

                Spacer(minLength: 4)

                Text("\(pctText) \(totalText)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 8)

            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(tint.opacity(0.26), lineWidth: 0.75)
        }
        .frame(height: 24)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .help(tooltip)
    }

    private func metricCard(label: String, percent: Double, history: MetricHistory, tint: Color) -> some View {
        let displayPercent = String(format: "%.0f%%", percent)
        let duration = monitor.isPopoverOpen ? scrollAnimationDuration : 0
        let numberAnimation: Animation? = reduceMotion || duration == 0 ? nil : .easeOut(duration: duration)
        return ZStack(alignment: .top) {
            TimedSparklineView(
                samples: history.samples,
                currentValue: percent,
                referenceTime: history.latestPosition,
                windowSeconds: history.visibleSpan,
                scrollAnimationDuration: duration,
                tint: tint,
                cornerRadius: 8
            )

            HStack(alignment: .top) {
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer()
                Text(displayPercent)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                    .monospacedDigit()
                    .contentTransition(numberAnimation == nil ? .identity : .numericText(value: percent))
                    .animation(numberAnimation, value: displayPercent)
            }
            .padding(.horizontal, 8)
            .padding(.top, 5)
        }
        .frame(height: 44)
    }

    private func processSection(
        title: String,
        symbol: String,
        tint: Color,
        processes: [ProcessMetric],
        historyMap: [Int32: [TimedSample]],
        emptyText: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }

            if processes.isEmpty {
                Text(emptyText)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
            } else {
                VStack(spacing: 5) {
                    ForEach(processes) { proc in
                        ProcessRowView(
                            process: proc,
                            tint: tint,
                            showGraph: showProcessGraphs,
                            samples: historyMap[proc.pid] ?? [],
                            referenceTime: monitor.latestSampleTime,
                            windowSeconds: SystemMonitor.processGraphWindowSeconds,
                            scrollAnimationDuration: scrollAnimationDuration,
                            onSelect: { onSelectProcess(proc) }
                        )
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.96)),
                            removal: .opacity
                        ))
                    }
                }
                .animation(.spring(response: 0.42, dampingFraction: 0.84), value: processes.map(\.pid))
            }
        }
    }

    private var bottomControlsRow: some View {
        HStack(spacing: 6) {
            Picker("", selection: $monitor.displayMode) {
                ForEach(MenuBarDisplayMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(.small)
            .frame(width: 112)

            intervalMenuButton(
                symbol: "arrow.clockwise",
                title: monitor.updateInterval.label,
                tooltip: "Update graphs & values every \(monitor.updateInterval.label)",
                selection: $monitor.updateInterval
            )

            intervalMenuButton(
                symbol: "arrow.up.arrow.down",
                title: monitor.orderUpdateInterval.label,
                tooltip: "Update Top 5 row order every \(monitor.orderUpdateInterval.label)",
                selection: $monitor.orderUpdateInterval
            )

            Spacer(minLength: 2)

            Toggle("Login", isOn: Binding(
                get: { monitor.launchAtLogin },
                set: { monitor.setLaunchAtLogin($0) }
            ))
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .font(.caption)
            .foregroundStyle(.secondary)
            .help("Launch at login")

            Button("Quit", action: onQuit)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .keyboardShortcut("q", modifiers: .command)
        }
    }

    private func intervalMenuButton(
        symbol: String,
        title: String,
        tooltip: String,
        selection: Binding<UpdateIntervalOption>
    ) -> some View {
        Menu {
            ForEach(UpdateIntervalOption.allCases) { option in
                Button {
                    selection.wrappedValue = option
                } label: {
                    if selection.wrappedValue == option {
                        Label("Every \(option.label)", systemImage: "checkmark")
                    } else {
                        Text("Every \(option.label)")
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .semibold))
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
            }
            .padding(.horizontal, 5.5)
            .padding(.vertical, 3)
            .background(.quaternary.opacity(0.65), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(tooltip)
    }
}

private struct ProcessRowView: View {
    let process: ProcessMetric
    let tint: Color
    let showGraph: Bool
    let samples: [TimedSample]
    let referenceTime: TimeInterval
    let windowSeconds: TimeInterval
    let scrollAnimationDuration: Double
    let onSelect: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onSelect) {
            rowContent
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(isHovering ? tint.opacity(0.65) : .clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
            if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        }
        .onDisappear {
            if isHovering {
                isHovering = false
                NSCursor.arrow.set()
            }
        }
        .help("\(process.name) (PID \(process.pid)) — Click for details")
    }

    @ViewBuilder
    private var rowContent: some View {
        if showGraph {
            ZStack {
                TimedSparklineView(
                    samples: samples,
                    currentValue: process.percent,
                    referenceTime: referenceTime,
                    windowSeconds: windowSeconds,
                    scrollAnimationDuration: scrollAnimationDuration,
                    tint: tint
                )

                HStack(spacing: 5) {
                    ProcessIconView(pid: process.pid)
                        .frame(width: 14, height: 14)

                    Text(process.name)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer(minLength: 3)

                    Text(String(format: "%.1f%%", process.percent))
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.primary)
                        .monospacedDigit()
                }
                .padding(.horizontal, 6)
            }
            .frame(height: 28)
        } else {
            HStack(spacing: 5) {
                ProcessIconView(pid: process.pid)
                    .frame(width: 14, height: 14)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 3) {
                        Text(process.name)
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 3)
                        Text(String(format: "%.1f%%", process.percent))
                            .font(.system(size: 10.5, weight: .semibold))
                            .monospacedDigit()
                    }

                    GeometryReader { proxy in
                        let fraction = min(max(process.percent / 100.0, 0.015), 1.0)
                        ZStack(alignment: .leading) {
                            Capsule().fill(.quaternary.opacity(0.6))
                            Capsule().fill(tint.opacity(0.8))
                                .frame(width: proxy.size.width * fraction)
                                .animation(.easeOut(duration: scrollAnimationDuration), value: fraction)
                        }
                    }
                    .frame(height: 3)
                }
            }
            .padding(.horizontal, 3)
            .padding(.vertical, 2)
        }
    }
}

private struct TimedSparklineView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let samples: [TimedSample]
    let currentValue: Double
    let referenceTime: TimeInterval
    let windowSeconds: TimeInterval
    let scrollAnimationDuration: Double
    let tint: Color
    var cornerRadius: CGFloat = 6

    var body: some View {
        let source = samples.isEmpty ? [TimedSample(time: referenceTime, value: currentValue)] : samples
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.quaternary.opacity(0.38))

            // Subtle 50% reference line so exact 0–100% scale is immediately readable.
            GeometryReader { proxy in
                Path { path in
                    let midY = proxy.size.height * 0.5
                    path.move(to: CGPoint(x: 0, y: midY))
                    path.addLine(to: CGPoint(x: proxy.size.width, y: midY))
                }
                .stroke(Color.primary.opacity(0.07), lineWidth: 0.5)
            }

            TimedSparklineAreaShape(
                samples: source,
                displayTime: referenceTime,
                windowSeconds: windowSeconds
            )
            .fill(tint.opacity(0.28))

            TimedSparklineLineShape(
                samples: source,
                displayTime: referenceTime,
                windowSeconds: windowSeconds
            )
            .stroke(tint.opacity(0.95), style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))

            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(tint.opacity(0.22), lineWidth: 0.75)
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .animation(
            reduceMotion || scrollAnimationDuration == 0 ? nil : .easeOut(duration: scrollAnimationDuration),
            value: referenceTime
        )
    }
}

private struct TimedSparklineLineShape: Shape {
    let samples: [TimedSample]
    var displayTime: Double
    let windowSeconds: Double

    var animatableData: Double {
        get { displayTime }
        set { displayTime = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard rect.width > 2, rect.height > 2, !samples.isEmpty else { return path }

        let pts = timedPoints(samples: samples, displayTime: displayTime, windowSeconds: windowSeconds, in: rect)
        if pts.count == 1, let p = pts.first {
            path.addEllipse(in: CGRect(x: p.x - 2, y: p.y - 2, width: 4, height: 4))
            return path
        }
        path.move(to: pts[0])
        for pt in pts.dropFirst() {
            path.addLine(to: pt)
        }
        return path
    }
}

private struct TimedSparklineAreaShape: Shape {
    let samples: [TimedSample]
    var displayTime: Double
    let windowSeconds: Double

    var animatableData: Double {
        get { displayTime }
        set { displayTime = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard rect.width > 2, rect.height > 2, samples.count >= 2 else { return path }

        let pts = timedPoints(samples: samples, displayTime: displayTime, windowSeconds: windowSeconds, in: rect)
        path.move(to: CGPoint(x: pts[0].x, y: rect.maxY))
        for pt in pts {
            path.addLine(to: pt)
        }
        path.addLine(to: CGPoint(x: pts[pts.count - 1].x, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

private func timedPoints(samples: [TimedSample], displayTime: Double, windowSeconds: Double, in rect: CGRect) -> [CGPoint] {
    let startTime = displayTime - windowSeconds
    let span = max(0.1, windowSeconds)

    return samples.map { sample in
        let fracX = (sample.time - startTime) / span
        let fracY = min(max(sample.value / 100.0, 0), 1)
        // Exact 0–100% mapping: 0% sits on the bottom edge, 50% at exact midpoint, 100% at top edge.
        let y = max(rect.minY + 0.75, rect.maxY - CGFloat(fracY) * rect.height)
        return CGPoint(
            x: rect.minX + CGFloat(fracX) * rect.width,
            y: y
        )
    }
}

private struct ProcessIconView: View {
    let pid: Int32

    var body: some View {
        if let icon = NSRunningApplication(processIdentifier: pid)?.icon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
        } else {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }
}
