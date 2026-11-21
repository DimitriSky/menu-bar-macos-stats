import AppKit

/// Custom NSView hosted inside `NSStatusBarButton` so updates only call `needsDisplay = true`
/// without mutating `button.image` or `button.title`.
final class StatusBarCanvasView: NSView {
    private var mode: MenuBarDisplayMode = .percent
    private var cpuInt: Int = 0
    private var gpuInt: Int = 0
    private var diskPercentInt: Int = 0
    private var diskUsedFraction: Double = 0
    private var cpuHistory: [Double] = []
    private var gpuHistory: [Double] = []
    private var hasRendered = false

    override var isOpaque: Bool { false }
    override var allowsVibrancy: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func update(
        mode: MenuBarDisplayMode,
        cpu: Double,
        gpu: Double,
        diskUsedFraction: Double,
        cpuHistory: [Double],
        gpuHistory: [Double]
    ) {
        let nextCPU = Int(cpu.rounded())
        let nextGPU = Int(gpu.rounded())
        let clampedDisk = min(max(diskUsedFraction, 0), 1)
        let nextDiskPct = Int((clampedDisk * 100.0).rounded())

        if hasRendered && self.mode == mode {
            switch mode {
            case .percent:
                guard nextCPU != cpuInt || nextGPU != gpuInt || nextDiskPct != diskPercentInt else { return }
            case .graph:
                guard cpuHistory != self.cpuHistory || gpuHistory != self.gpuHistory || nextDiskPct != diskPercentInt else { return }
            }
        }

        self.mode = mode
        self.cpuInt = nextCPU
        self.gpuInt = nextGPU
        self.diskPercentInt = nextDiskPct
        self.diskUsedFraction = clampedDisk
        self.cpuHistory = cpuHistory
        self.gpuHistory = gpuHistory
        self.hasRendered = true
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        switch mode {
        case .percent:
            drawPercentWithDiskPie(in: bounds)
        case .graph:
            drawGraphsWithDiskPie(in: bounds)
        }
    }

    private func drawPercentWithDiskPie(in rect: NSRect) {
        let pieSize = max(16, rect.height - 3)
        let padX: CGFloat = 2
        let gap: CGFloat = 4
        let textAreaWidth = rect.width - pieSize - gap - padX * 2

        let color = NSColor.labelColor
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 7.5, weight: .semibold),
            .foregroundColor: color.withAlphaComponent(0.68),
        ]
        let valueAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .semibold),
            .foregroundColor: color,
        ]

        let cpuLabel = NSAttributedString(string: "CPU", attributes: labelAttrs)
        let gpuLabel = NSAttributedString(string: "GPU", attributes: labelAttrs)
        let cpuVal = NSAttributedString(string: "\(cpuInt)%", attributes: valueAttrs)
        let gpuVal = NSAttributedString(string: "\(gpuInt)%", attributes: valueAttrs)

        let topY: CGFloat = rect.midY + 0.5
        cpuLabel.draw(at: NSPoint(x: padX, y: topY + 0.5))
        let cpuValSize = cpuVal.size()
        cpuVal.draw(at: NSPoint(x: padX + textAreaWidth - cpuValSize.width, y: topY - 0.5))

        let botY: CGFloat = rect.midY - 10.5
        gpuLabel.draw(at: NSPoint(x: padX, y: botY + 0.5))
        let gpuValSize = gpuVal.size()
        gpuVal.draw(at: NSPoint(x: padX + textAreaWidth - gpuValSize.width, y: botY - 0.5))

        let pieRect = NSRect(
            x: rect.maxX - padX - pieSize,
            y: floor((rect.height - pieSize) / 2.0),
            width: pieSize,
            height: pieSize
        )
        drawDiskPie(in: pieRect, fraction: diskUsedFraction)
    }

    private func drawGraphsWithDiskPie(in rect: NSRect) {
        // Left: CPU (Blue), Middle: GPU (Purple), Right: Disk Pie (Round)
        let padX: CGFloat = 2
        let padY: CGFloat = 1
        let gap: CGFloat = 3
        let graphHeight = max(16, rect.height - padY * 2)
        let graphY = (rect.height - graphHeight) / 2.0

        let pieSize = graphHeight
        let availableGraphsWidth = rect.width - padX * 2 - pieSize - gap * 2
        let graphWidth = floor(availableGraphsWidth / 2.0)

        let cpuRect = NSRect(x: padX, y: graphY, width: graphWidth, height: graphHeight)
        let gpuRect = NSRect(x: padX + graphWidth + gap, y: graphY, width: graphWidth, height: graphHeight)
        let pieRect = NSRect(
            x: gpuRect.maxX + gap,
            y: (rect.height - pieSize) / 2.0,
            width: pieSize,
            height: pieSize
        )

        let cpuColor = NSColor(srgbRed: 0.22, green: 0.62, blue: 1.0, alpha: 1.0)
        let gpuColor = NSColor(srgbRed: 0.80, green: 0.36, blue: 1.0, alpha: 1.0)

        drawColoredSparklineBox(tag: "C", values: cpuHistory, in: cpuRect, accent: cpuColor)
        drawColoredSparklineBox(tag: "G", values: gpuHistory, in: gpuRect, accent: gpuColor)
        drawDiskPie(in: pieRect, fraction: diskUsedFraction)
    }

    private func drawDiskPie(in rect: NSRect, fraction: Double) {
        let clamped = min(max(fraction, 0), 1)
        let accent: NSColor
        if clamped >= 0.90 {
            accent = NSColor(srgbRed: 1.0, green: 0.32, blue: 0.32, alpha: 1.0)
        } else if clamped >= 0.75 {
            accent = NSColor(srgbRed: 1.0, green: 0.66, blue: 0.18, alpha: 1.0)
        } else {
            accent = NSColor(srgbRed: 0.22, green: 0.82, blue: 0.56, alpha: 1.0)
        }

        let circleRect = rect.insetBy(dx: 0.75, dy: 0.75)
        let bgCircle = NSBezierPath(ovalIn: circleRect)
        accent.withAlphaComponent(0.16).setFill()
        bgCircle.fill()

        if clamped > 0.005 {
            let center = NSPoint(x: circleRect.midX, y: circleRect.midY)
            let radius = min(circleRect.width, circleRect.height) / 2.0
            let startAngle: CGFloat = 90 // 12 o'clock
            let endAngle: CGFloat = startAngle - CGFloat(clamped) * 360.0 // clockwise
            let wedge = NSBezierPath()
            wedge.move(to: center)
            wedge.appendArc(withCenter: center, radius: radius, startAngle: startAngle, endAngle: endAngle, clockwise: true)
            wedge.close()
            accent.withAlphaComponent(0.88).setFill()
            wedge.fill()
        }

        bgCircle.lineWidth = 1.1
        accent.withAlphaComponent(0.85).setStroke()
        bgCircle.stroke()
    }

    private func drawColoredSparklineBox(tag: String, values: [Double], in rect: NSRect, accent: NSColor) {
        let boxPath = NSBezierPath(roundedRect: rect, xRadius: 3.5, yRadius: 3.5)
        accent.withAlphaComponent(0.14).setFill()
        boxPath.fill()

        let inner = rect.insetBy(dx: 1.0, dy: 1.0)
        if values.count >= 2, inner.width > 1, inner.height > 1 {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: inner, xRadius: 2.5, yRadius: 2.5).addClip()

            let samples = Array(values.suffix(16))
            let stepX = inner.width / CGFloat(max(1, samples.count - 1))

            let linePath = NSBezierPath()
            let fillPath = NSBezierPath()

            for (index, rawVal) in samples.enumerated() {
                let clamped = min(max(rawVal, 0), 100) / 100.0
                let x = inner.minX + CGFloat(index) * stepX
                let y = inner.minY + max(0.8, CGFloat(clamped) * (inner.height - 1.2))
                let pt = NSPoint(x: x, y: y)
                if index == 0 {
                    linePath.move(to: pt)
                    fillPath.move(to: NSPoint(x: inner.minX, y: inner.minY))
                    fillPath.line(to: pt)
                } else {
                    linePath.line(to: pt)
                    fillPath.line(to: pt)
                }
            }
            fillPath.line(to: NSPoint(x: inner.maxX, y: inner.minY))
            fillPath.close()

            accent.withAlphaComponent(0.48).setFill()
            fillPath.fill()

            linePath.lineWidth = 1.35
            linePath.lineJoinStyle = .round
            accent.setStroke()
            linePath.stroke()

            NSGraphicsContext.restoreGraphicsState()
        }

        boxPath.lineWidth = 1.0
        accent.withAlphaComponent(0.72).setStroke()
        boxPath.stroke()

        let tagAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 6.5, weight: .bold),
            .foregroundColor: NSColor.labelColor.withAlphaComponent(0.88),
        ]
        NSAttributedString(string: tag, attributes: tagAttrs).draw(at: NSPoint(x: rect.minX + 2.2, y: rect.maxY - 8.5))
    }
}
