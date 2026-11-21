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

    private var effectiveScrollAnimationDuration: Double {
        (monitor.isPopoverOpen && monitor.popoverState.allowScrollAnimation) ? scrollAnimationDuration : 0
    }

    var body: some View {
        let state = monitor.popoverState
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                // Left column: CPU summary + Top 5 CPU
                VStack(alignment: .leading, spacing: 8) {
                    metricCard(
                        label: "CPU",
                        percent: state.cpuPercent,
                        history: state.cpuHistory,
                        tint: cpuTint,
                        trackID: -1
                    )
                    processSection(
                        title: showProcessGraphs ? "Top 5 CPU (10s)" : "Top 5 CPU",
                        symbol: "cpu",
                        tint: cpuTint,
                        processes: state.topCPU,
                        historyMap: state.cpuProcessHistory,
                        icons: state.processIcons,
                        referenceTime: state.latestSampleTime,
                        emptyText: state.isSamplingDetails ? "Sampling…" : "Idle"
                    )
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)

                // Right column: GPU summary + Top 5 GPU
                VStack(alignment: .leading, spacing: 8) {
                    metricCard(
                        label: "GPU",
                        percent: state.gpuPercent,
                        history: state.gpuHistory,
                        tint: gpuTint,
                        trackID: -2
                    )
                    processSection(
                        title: showProcessGraphs ? "Top 5 GPU (10s)" : "Top 5 GPU",
                        symbol: "memorychip",
                        tint: gpuTint,
                        processes: state.topGPU,
                        historyMap: state.gpuProcessHistory,
                        icons: state.processIcons,
                        referenceTime: state.latestSampleTime,
                        emptyText: state.isSamplingDetails ? "Sampling…" : "Idle"
                    )
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }

            disksSummarySection(state: state)

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

    private func disksSummarySection(state: PopoverSnapshot) -> some View {
        let items = state.disks.isEmpty ? [state.diskUsage] : state.disks
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
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.quaternary.opacity(0.38))

            HorizontalFillBarShape(fraction: disk.usedFraction, cornerRadius: 6)
                .fill(tint.opacity(0.24))

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

    private func metricCard(label: String, percent: Double, history: MetricHistory, tint: Color, trackID: Int32) -> some View {
        let displayPercent = String(format: "%.0f%%", percent)
        let duration = effectiveScrollAnimationDuration
        return ZStack(alignment: .top) {
            TimedSparklineView(
                trackID: trackID,
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
        icons: [Int32: NSImage],
        referenceTime: TimeInterval,
        emptyText: String
    ) -> some View {
        let duration = effectiveScrollAnimationDuration
        let rowHeight: CGFloat = showProcessGraphs ? 28 : 24
        let spacing: CGFloat = 5
        let listHeight = CGFloat(processes.count) * rowHeight + CGFloat(max(0, processes.count - 1)) * spacing

        return VStack(alignment: .leading, spacing: 6) {
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
                ProcessRowsRepresentable(
                    processes: processes,
                    icons: icons,
                    historyMap: historyMap,
                    tint: NSColor(tint),
                    showGraph: showProcessGraphs,
                    referenceTime: referenceTime,
                    windowSeconds: SystemMonitor.processGraphWindowSeconds,
                    scrollAnimationDuration: reduceMotion ? 0 : duration,
                    animateReorder: !reduceMotion && monitor.isPopoverOpen && monitor.popoverState.allowScrollAnimation,
                    onSelect: onSelectProcess
                )
                .frame(height: listHeight)
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

/// Core Animation container for the Top 5 process rows: animates BOTH smooth row reordering
/// (`NSAnimationContext` frame slide + fade) and 10s sparkline leftward scrolling (`CABasicAnimation`)
/// completely outside SwiftUI's DisplayLink / layout engine (~2% CPU while open).
private struct ProcessRowsRepresentable: NSViewRepresentable {
    let processes: [ProcessMetric]
    let icons: [Int32: NSImage]
    let historyMap: [Int32: [TimedSample]]
    let tint: NSColor
    let showGraph: Bool
    let referenceTime: TimeInterval
    let windowSeconds: TimeInterval
    let scrollAnimationDuration: Double
    let animateReorder: Bool
    let onSelect: (ProcessMetric) -> Void

    func makeNSView(context: Context) -> ProcessRowsContainerNSView {
        let view = ProcessRowsContainerNSView()
        view.update(
            processes: processes,
            icons: icons,
            historyMap: historyMap,
            tint: tint,
            showGraph: showGraph,
            referenceTime: referenceTime,
            windowSeconds: windowSeconds,
            scrollAnimationDuration: 0,
            animateReorder: false,
            onSelect: onSelect
        )
        return view
    }

    func updateNSView(_ nsView: ProcessRowsContainerNSView, context: Context) {
        nsView.update(
            processes: processes,
            icons: icons,
            historyMap: historyMap,
            tint: tint,
            showGraph: showGraph,
            referenceTime: referenceTime,
            windowSeconds: windowSeconds,
            scrollAnimationDuration: scrollAnimationDuration,
            animateReorder: animateReorder,
            onSelect: onSelect
        )
    }
}

private final class ProcessRowsContainerNSView: NSView {
    private var rowViews: [Int32: ProcessRowNSView] = [:]
    private var orderedPIDs: [Int32] = []
    private var showGraph: Bool = true
    private var lastWidth: CGFloat = 0

    private var rowHeight: CGFloat { showGraph ? 28 : 24 }
    private let spacing: CGFloat = 5

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        guard bounds.width > 1, abs(bounds.width - lastWidth) > 0.5 else { return }
        lastWidth = bounds.width
        for (idx, pid) in orderedPIDs.enumerated() {
            if let row = rowViews[pid] {
                row.frame = frameForRow(at: idx, width: bounds.width)
            }
        }
    }

    private func frameForRow(at index: Int, width: CGFloat) -> NSRect {
        NSRect(
            x: 0,
            y: CGFloat(index) * (rowHeight + spacing),
            width: max(0, width),
            height: rowHeight
        )
    }

    func update(
        processes: [ProcessMetric],
        icons: [Int32: NSImage],
        historyMap: [Int32: [TimedSample]],
        tint: NSColor,
        showGraph: Bool,
        referenceTime: TimeInterval,
        windowSeconds: TimeInterval,
        scrollAnimationDuration: Double,
        animateReorder: Bool,
        onSelect: @escaping (ProcessMetric) -> Void
    ) {
        let modeChanged = (self.showGraph != showGraph)
        self.showGraph = showGraph

        let newOrder = processes.map(\.pid)
        let newPIDSet = Set(newOrder)
        let orderChanged = (newOrder != orderedPIDs) && !orderedPIDs.isEmpty && !modeChanged
        let shouldAnimateReorder = orderChanged && animateReorder && bounds.width > 2

        // Remove rows that dropped out of Top 5
        for (pid, rowView) in rowViews where !newPIDSet.contains(pid) {
            rowViews.removeValue(forKey: pid)
            rowView.prepareForRemoval()
            if shouldAnimateReorder {
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.22
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    rowView.animator().alphaValue = 0
                }, completionHandler: { [weak rowView] in
                    rowView?.removeFromSuperview()
                })
            } else {
                rowView.removeFromSuperview()
            }
        }

        let width = bounds.width
        var newlyAdded: [ProcessRowNSView] = []
        var frameTargets: [(ProcessRowNSView, NSRect)] = []

        for (index, proc) in processes.enumerated() {
            let targetFrame = frameForRow(at: index, width: width)
            let samples = historyMap[proc.pid] ?? []
            if let existing = rowViews[proc.pid] {
                existing.configure(
                    process: proc,
                    icon: icons[proc.pid],
                    tint: tint,
                    showGraph: showGraph,
                    samples: samples,
                    referenceTime: referenceTime,
                    windowSeconds: windowSeconds,
                    scrollAnimationDuration: modeChanged ? 0 : scrollAnimationDuration,
                    onSelect: onSelect
                )
                if existing.frame != targetFrame {
                    if shouldAnimateReorder {
                        frameTargets.append((existing, targetFrame))
                    } else {
                        existing.frame = targetFrame
                    }
                }
            } else {
                let row = ProcessRowNSView(frame: targetFrame)
                row.configure(
                    process: proc,
                    icon: icons[proc.pid],
                    tint: tint,
                    showGraph: showGraph,
                    samples: samples,
                    referenceTime: referenceTime,
                    windowSeconds: windowSeconds,
                    scrollAnimationDuration: 0,
                    onSelect: onSelect
                )
                if shouldAnimateReorder {
                    row.alphaValue = 0
                    newlyAdded.append(row)
                }
                addSubview(row)
                rowViews[proc.pid] = row
            }
        }

        if shouldAnimateReorder && (!frameTargets.isEmpty || !newlyAdded.isEmpty) {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.38
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
                ctx.allowsImplicitAnimation = true
                for (row, rect) in frameTargets {
                    row.animator().frame = rect
                }
                for row in newlyAdded {
                    row.animator().alphaValue = 1
                }
            }
        }

        orderedPIDs = newOrder
        lastWidth = width
    }
}

private final class ProcessRowNSView: NSView {
    private let sparklineView = SparklineCanvasNSView()
    private let iconView = NSImageView()
    private let nameField = NSTextField(labelWithString: "")
    private let percentField = NSTextField(labelWithString: "")
    private let barTrackLayer = CALayer()
    private let barFillLayer = CALayer()

    private var process: ProcessMetric?
    private var tintColor: NSColor = .systemBlue
    private var showGraph: Bool = true
    private var currentFraction: Double = 0
    private var isHovering: Bool = false
    private var onSelect: ((ProcessMetric) -> Void)?
    private var trackingArea: NSTrackingArea?

    private static let fallbackIcon: NSImage? = {
        let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        return NSImage(systemSymbolName: "gearshape.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
    }()

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        let childNoActions: [String: CAAction] = [
            "backgroundColor": NSNull(),
            "borderColor": NSNull(),
            "borderWidth": NSNull(),
            "bounds": NSNull(),
            "position": NSNull(),
            "frame": NSNull(),
        ]
        layer?.masksToBounds = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        // Keep position/frame animatable so `row.animator().frame = targetFrame` slides rows smoothly on reorder.
        layer?.actions = [
            "backgroundColor": NSNull(),
            "borderColor": NSNull(),
            "borderWidth": NSNull(),
        ]

        addSubview(sparklineView)

        barTrackLayer.cornerRadius = 1.5
        barTrackLayer.masksToBounds = true
        barTrackLayer.actions = childNoActions
        layer?.addSublayer(barTrackLayer)

        barFillLayer.cornerRadius = 1.5
        barFillLayer.actions = childNoActions
        barTrackLayer.addSublayer(barFillLayer)

        iconView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(iconView)

        nameField.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        nameField.textColor = .labelColor
        nameField.lineBreakMode = .byTruncatingTail
        nameField.maximumNumberOfLines = 1
        nameField.drawsBackground = false
        nameField.isBezeled = false
        nameField.isEditable = false
        nameField.isSelectable = false
        addSubview(nameField)

        percentField.font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold)
        percentField.textColor = .labelColor
        percentField.alignment = .right
        percentField.lineBreakMode = .byClipping
        percentField.maximumNumberOfLines = 1
        percentField.drawsBackground = false
        percentField.isBezeled = false
        percentField.isEditable = false
        percentField.isSelectable = false
        addSubview(percentField)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        NSCursor.pointingHand.set()
        updateChromeColors()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        NSCursor.arrow.set()
        updateChromeColors()
    }

    override func mouseUp(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        if bounds.contains(loc), let proc = process {
            onSelect?(proc)
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil && isHovering {
            isHovering = false
            NSCursor.arrow.set()
        }
    }

    func prepareForRemoval() {
        if isHovering {
            isHovering = false
            NSCursor.arrow.set()
        }
        onSelect = nil
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateChromeColors()
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        let h = bounds.height
        guard w > 4, h > 4 else { return }

        let pctSize = percentField.attributedStringValue.size()
        let pctW = ceil(pctSize.width) + 2

        if showGraph {
            sparklineView.isHidden = false
            sparklineView.frame = bounds
            barTrackLayer.isHidden = true

            let padX: CGFloat = 6
            let iconSize: CGFloat = 14
            iconView.frame = NSRect(x: padX, y: floor((h - iconSize) / 2), width: iconSize, height: iconSize)

            let pctH: CGFloat = 14
            let pctX = max(padX + iconSize + 10, w - padX - pctW)
            percentField.frame = NSRect(x: pctX, y: floor((h - pctH) / 2), width: pctW, height: pctH)

            let nameX = padX + iconSize + 5
            let nameW = max(0, pctX - nameX - 3)
            let nameH: CGFloat = 14
            nameField.frame = NSRect(x: nameX, y: floor((h - nameH) / 2), width: nameW, height: nameH)
        } else {
            sparklineView.isHidden = true
            barTrackLayer.isHidden = false

            let padX: CGFloat = 3
            let iconSize: CGFloat = 14
            iconView.frame = NSRect(x: padX, y: floor((h - iconSize) / 2), width: iconSize, height: iconSize)

            let contentX = padX + iconSize + 5
            let rightX = w - padX
            let pctX = max(contentX + 8, rightX - pctW)
            percentField.frame = NSRect(x: pctX, y: 2, width: pctW, height: 14)

            let nameW = max(0, pctX - contentX - 3)
            nameField.frame = NSRect(x: contentX, y: 2, width: nameW, height: 14)

            let barW = max(0, rightX - contentX)
            let trackRect = NSRect(x: contentX, y: h - 5, width: barW, height: 3)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            barTrackLayer.frame = trackRect
            barFillLayer.frame = NSRect(x: 0, y: 0, width: barW * CGFloat(currentFraction), height: 3)
            CATransaction.commit()
        }
    }

    func configure(
        process: ProcessMetric,
        icon: NSImage?,
        tint: NSColor,
        showGraph: Bool,
        samples: [TimedSample],
        referenceTime: TimeInterval,
        windowSeconds: TimeInterval,
        scrollAnimationDuration: Double,
        onSelect: @escaping (ProcessMetric) -> Void
    ) {
        let modeChanged = (self.showGraph != showGraph)
        let prevFraction = self.currentFraction

        self.process = process
        self.tintColor = tint
        self.showGraph = showGraph
        self.onSelect = onSelect
        self.currentFraction = min(max(process.percent / 100.0, 0.015), 1.0)

        if let icon {
            iconView.image = icon
            iconView.contentTintColor = nil
        } else {
            iconView.image = Self.fallbackIcon
            iconView.contentTintColor = .secondaryLabelColor
        }

        if nameField.stringValue != process.name {
            nameField.stringValue = process.name
        }
        let nextPct = String(format: "%.1f%%", process.percent)
        let pctChanged = (percentField.stringValue != nextPct)
        if pctChanged {
            percentField.stringValue = nextPct
        }
        toolTip = "\(process.name) (PID \(process.pid)) — Click for details"

        updateChromeColors()

        if showGraph {
            sparklineView.configure(
                trackID: process.pid,
                samples: samples,
                currentValue: process.percent,
                referenceTime: referenceTime,
                windowSeconds: windowSeconds,
                scrollAnimationDuration: scrollAnimationDuration,
                tint: tint,
                cornerRadius: 6
            )
        } else if !modeChanged && scrollAnimationDuration > 0 && abs(currentFraction - prevFraction) > 0.002 {
            let barW = barTrackLayer.bounds.width
            let oldW = barW * CGFloat(prevFraction)
            let newW = barW * CGFloat(currentFraction)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            barFillLayer.frame = NSRect(x: 0, y: 0, width: newW, height: 3)
            CATransaction.commit()
            let anim = CABasicAnimation(keyPath: "bounds.size.width")
            anim.fromValue = oldW
            anim.toValue = newW
            anim.duration = scrollAnimationDuration
            anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
            barFillLayer.add(anim, forKey: "barWidth")
        }

        if modeChanged || pctChanged {
            needsLayout = true
        }
    }

    private func updateChromeColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            guard let root = layer else { return }
            let quat = NSColor.quaternaryLabelColor.usingColorSpace(.sRGB) ?? NSColor.quaternaryLabelColor
            if showGraph {
                // Multiply quaternaryLabelColor's alpha (~0.098) by 0.38 to match SwiftUI .quaternary.opacity(0.38)
                root.backgroundColor = quat.withAlphaComponent(quat.alphaComponent * 0.38).cgColor
                root.borderWidth = isHovering ? 1.0 : 0.75
                root.borderColor = tintColor.withAlphaComponent(isHovering ? 0.65 : 0.22).cgColor
            } else {
                root.backgroundColor = nil
                root.borderWidth = isHovering ? 1.0 : 0
                root.borderColor = isHovering ? tintColor.withAlphaComponent(0.65).cgColor : nil
                barTrackLayer.backgroundColor = quat.withAlphaComponent(quat.alphaComponent * 0.6).cgColor
                barFillLayer.backgroundColor = tintColor.withAlphaComponent(0.8).cgColor
            }
        }
    }
}

/// GPU-composited Core Animation sparkline (`CAShapeLayer` + `CABasicAnimation("transform.translation.x")`)
/// used by the top CPU and GPU summary cards.
private struct TimedSparklineView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let trackID: Int32
    let samples: [TimedSample]
    let currentValue: Double
    let referenceTime: TimeInterval
    let windowSeconds: TimeInterval
    let scrollAnimationDuration: Double
    let tint: Color
    var cornerRadius: CGFloat = 6

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.quaternary.opacity(0.38))

            SparklineCanvasRepresentable(
                trackID: trackID,
                samples: samples,
                currentValue: currentValue,
                referenceTime: referenceTime,
                windowSeconds: windowSeconds,
                scrollAnimationDuration: reduceMotion ? 0 : scrollAnimationDuration,
                tint: NSColor(tint),
                cornerRadius: cornerRadius
            )

            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(tint.opacity(0.22), lineWidth: 0.75)
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

private struct SparklineCanvasRepresentable: NSViewRepresentable {
    let trackID: Int32
    let samples: [TimedSample]
    let currentValue: Double
    let referenceTime: TimeInterval
    let windowSeconds: TimeInterval
    let scrollAnimationDuration: Double
    let tint: NSColor
    let cornerRadius: CGFloat

    func makeNSView(context: Context) -> SparklineCanvasNSView {
        let view = SparklineCanvasNSView()
        view.configure(
            trackID: trackID,
            samples: samples,
            currentValue: currentValue,
            referenceTime: referenceTime,
            windowSeconds: windowSeconds,
            scrollAnimationDuration: 0,
            tint: tint,
            cornerRadius: cornerRadius
        )
        return view
    }

    func updateNSView(_ nsView: SparklineCanvasNSView, context: Context) {
        nsView.configure(
            trackID: trackID,
            samples: samples,
            currentValue: currentValue,
            referenceTime: referenceTime,
            windowSeconds: windowSeconds,
            scrollAnimationDuration: scrollAnimationDuration,
            tint: tint,
            cornerRadius: cornerRadius
        )
    }
}

private final class SparklineCanvasNSView: NSView {
    private let midlineLayer = CAShapeLayer()
    private let plotContainerLayer = CALayer()
    private let areaLayer = CAShapeLayer()
    private let lineLayer = CAShapeLayer()

    private var trackID: Int32 = 0
    private var samples: [TimedSample] = []
    private var currentValue: Double = 0
    private var referenceTime: TimeInterval = 0
    private var windowSeconds: TimeInterval = 10
    private var tintColor: NSColor = .systemBlue
    private var cornerRadius: CGFloat = 6
    private var lastReferenceTime: TimeInterval?
    private var lastBoundsSize: CGSize = .zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setupLayers()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    private func setupLayers() {
        guard let root = layer else { return }
        let noActions: [String: CAAction] = [
            "path": NSNull(),
            "bounds": NSNull(),
            "position": NSNull(),
            "frame": NSNull(),
            "backgroundColor": NSNull(),
            "borderColor": NSNull(),
            "fillColor": NSNull(),
            "strokeColor": NSNull(),
        ]
        root.actions = noActions
        root.masksToBounds = true
        root.cornerCurve = .continuous
        root.backgroundColor = nil
        root.borderWidth = 0

        midlineLayer.actions = noActions
        midlineLayer.fillColor = nil
        midlineLayer.lineWidth = 0.5
        root.addSublayer(midlineLayer)

        plotContainerLayer.actions = noActions
        root.addSublayer(plotContainerLayer)

        areaLayer.actions = noActions
        areaLayer.strokeColor = nil
        plotContainerLayer.addSublayer(areaLayer)

        lineLayer.actions = noActions
        lineLayer.fillColor = nil
        lineLayer.lineWidth = 1.4
        lineLayer.lineCap = .round
        lineLayer.lineJoin = .round
        plotContainerLayer.addSublayer(lineLayer)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateBackingScale()
    }

    override func layout() {
        super.layout()
        guard let root = layer else { return }
        let size = bounds.size
        guard size != lastBoundsSize else { return }
        lastBoundsSize = size

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.cornerRadius = cornerRadius
        midlineLayer.frame = bounds
        plotContainerLayer.frame = bounds
        areaLayer.frame = bounds
        lineLayer.frame = bounds

        let midPath = CGMutablePath()
        let midY = size.height * 0.5
        midPath.move(to: CGPoint(x: 0, y: midY))
        midPath.addLine(to: CGPoint(x: size.width, y: midY))
        midlineLayer.path = midPath

        updateBackingScale()
        updateColors()
        rebuildPaths(animateShift: 0, duration: 0)
        CATransaction.commit()
    }

    func configure(
        trackID: Int32,
        samples: [TimedSample],
        currentValue: Double,
        referenceTime: TimeInterval,
        windowSeconds: TimeInterval,
        scrollAnimationDuration: Double,
        tint: NSColor,
        cornerRadius: CGFloat
    ) {
        let trackChanged = (self.trackID != trackID)
        let prevRefTime = trackChanged ? nil : self.lastReferenceTime

        self.trackID = trackID
        self.samples = samples
        self.currentValue = currentValue
        self.referenceTime = referenceTime
        self.windowSeconds = max(0.1, windowSeconds)
        self.tintColor = tint
        self.cornerRadius = cornerRadius
        self.lastReferenceTime = referenceTime

        if let root = layer, root.cornerRadius != cornerRadius {
            root.cornerRadius = cornerRadius
        }
        updateColors()

        var shiftX: CGFloat = 0
        if !trackChanged,
           scrollAnimationDuration > 0,
           bounds.width > 2,
           let prev = prevRefTime {
            let dt = referenceTime - prev
            if dt > 0.001 && dt <= self.windowSeconds * 0.85 {
                shiftX = bounds.width * CGFloat(dt / self.windowSeconds)
            }
        }

        rebuildPaths(animateShift: shiftX, duration: scrollAnimationDuration)
    }

    private func updateBackingScale() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        layer?.contentsScale = scale
        midlineLayer.contentsScale = scale
        plotContainerLayer.contentsScale = scale
        areaLayer.contentsScale = scale
        lineLayer.contentsScale = scale
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            midlineLayer.strokeColor = NSColor.labelColor.withAlphaComponent(0.07).cgColor
            areaLayer.fillColor = tintColor.withAlphaComponent(0.28).cgColor
            lineLayer.strokeColor = tintColor.withAlphaComponent(0.95).cgColor
        }
    }

    private func rebuildPaths(animateShift: CGFloat, duration: Double) {
        let rect = bounds
        guard rect.width > 2, rect.height > 2 else {
            areaLayer.path = nil
            lineLayer.path = nil
            return
        }

        let source = samples.isEmpty ? [TimedSample(time: referenceTime, value: currentValue)] : samples
        let startTime = referenceTime - windowSeconds
        let span = max(0.1, windowSeconds)

        var pts: [CGPoint] = []
        pts.reserveCapacity(source.count)
        for sample in source {
            let fracX = (sample.time - startTime) / span
            let fracY = min(max(sample.value / 100.0, 0), 1)
            // Bottom-left CALayer coordinates: 0% sits at y=0, 50% at midY, 100% at top edge.
            let y = min(rect.height - 0.75, CGFloat(fracY) * rect.height)
            pts.append(CGPoint(x: CGFloat(fracX) * rect.width, y: y))
        }

        let linePath = CGMutablePath()
        let areaPath = CGMutablePath()

        if pts.count == 1, let p = pts.first {
            linePath.addEllipse(in: CGRect(x: p.x - 2, y: p.y - 2, width: 4, height: 4))
        } else if pts.count >= 2 {
            linePath.move(to: pts[0])
            areaPath.move(to: CGPoint(x: pts[0].x, y: 0))
            areaPath.addLine(to: pts[0])
            for pt in pts.dropFirst() {
                linePath.addLine(to: pt)
                areaPath.addLine(to: pt)
            }
            areaPath.addLine(to: CGPoint(x: pts[pts.count - 1].x, y: 0))
            areaPath.closeSubpath()
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        areaLayer.path = pts.count >= 2 ? areaPath : nil
        lineLayer.path = linePath
        plotContainerLayer.removeAnimation(forKey: "scrollX")
        CATransaction.commit()

        if animateShift > 0.25 && duration > 0 {
            let anim = CABasicAnimation(keyPath: "transform.translation.x")
            anim.fromValue = animateShift
            anim.toValue = 0.0
            anim.duration = duration
            anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
            anim.isRemovedOnCompletion = true
            plotContainerLayer.add(anim, forKey: "scrollX")
        }
    }
}

private struct HorizontalFillBarShape: Shape {
    var fraction: Double
    let cornerRadius: CGFloat

    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let clamped = min(max(fraction, 0), 1)
        let fillRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width * CGFloat(clamped), height: rect.height)
        return Path(roundedRect: fillRect, cornerRadius: cornerRadius, style: .continuous)
    }
}
