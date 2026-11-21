import AppKit
import SwiftUI

func runSelfTest() {
    func check(_ condition: Bool, _ description: String) {
        guard condition else {
            fputs("FAIL: \(description)\n", stderr)
            exit(1)
        }
        print("PASS: \(description)")
    }

    let t0 = CPUCoreTicks(user: 100, system: 50, idle: 850, nice: 0)
    let t1 = CPUCoreTicks(user: 130, system: 70, idle: 900, nice: 0)
    let cpu = MetricsMath.cpuPercent(previous: t0, current: t1)
    check(abs(cpu - 50.0) < 0.001, "CPU delta math computes 50%")

    let parsedCreator = MetricsMath.parseIOUserClientCreator("pid 447, WindowServer")
    check(parsedCreator?.pid == 447 && parsedCreator?.name == "WindowServer", "parses IOUserClientCreator")

    let parsedPS = MetricsMath.parsePSLine("  447  38.4  112:34.50 /System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer")
    check(parsedPS?.pid == 447 && parsedPS?.name == "WindowServer" && abs((parsedPS?.instantCPU ?? 0) - 38.4) < 0.01, "parses ps line")

    let gpuTop = MetricsMath.gpuDeltas(
        previous: [10: ("AppA", 1_000_000_000), 20: ("AppB", 0)],
        current: [10: ("AppA", 1_500_000_000), 20: ("AppB", 200_000_000)],
        elapsedSeconds: 2.0
    )
    check(gpuTop.count == 2 && gpuTop[0].pid == 10 && abs(gpuTop[0].percent - 25.0) < 0.01, "GPU delta sorts descending")
}

if CommandLine.arguments.contains("--self-test") {
    runSelfTest()
    exit(0)
}

/// Custom floating panel anchored reliably under the menu bar icon (even with auto-hidden menu bar on macOS Tahoe).
final class PopupPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class StatusPopupController {
    private let panel: PopupPanel
    private let hostingController: NSHostingController<PopoverView>
    private let containerView: NSView
    private var globalClickMonitor: Any?
    private var localEventMonitor: Any?
    private var anchoredTopY: CGFloat = 0
    private var anchoredCenterX: CGFloat = 0
    private weak var anchoredScreen: NSScreen?

    var isShown: Bool { panel.isVisible }
    var onVisibilityChange: ((Bool) -> Void)?

    init(rootView: PopoverView) {
        hostingController = NSHostingController(rootView: rootView)
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false

        containerView = NSView()
        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = NSColor.clear.cgColor
        containerView.addSubview(hostingController.view)

        NSLayoutConstraint.activate([
            hostingController.view.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            hostingController.view.topAnchor.constraint(equalTo: containerView.topAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
        ])

        panel = PopupPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 290),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentView = containerView
    }

    func toggle(relativeTo button: NSStatusBarButton) {
        if isShown {
            close()
        } else {
            show(relativeTo: button)
        }
    }

    func show(relativeTo button: NSStatusBarButton) {
        guard let buttonWindow = button.window else { return }
        let buttonRectInWindow = button.convert(button.bounds, to: nil)
        let anchorRect = buttonWindow.convertToScreen(buttonRectInWindow)
        let screen = buttonWindow.screen
            ?? NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: anchorRect.midX, y: anchorRect.midY)) })
            ?? NSScreen.main

        guard let screen else { return }
        anchoredScreen = screen

        // Always anchor cleanly just below the menu bar, even when the menu bar is auto-hidden or animating.
        let menuBarThickness = max(NSStatusBar.system.thickness, anchorRect.height, 24)
        let safeTopEdge = screen.frame.maxY - menuBarThickness - 6
        anchoredTopY = min(anchorRect.minY - 6, safeTopEdge)
        anchoredCenterX = anchorRect.midX

        updatePanelFrame()
        onVisibilityChange?(true)
        panel.orderFrontRegardless()
        panel.makeKey()
        installDismissMonitors(excluding: buttonWindow)
    }

    func updatePanelFrameIfVisible() {
        guard isShown else { return }
        updatePanelFrame()
    }

    func close() {
        removeDismissMonitors()
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        onVisibilityChange?(false)
    }

    private func updatePanelFrame() {
        guard let screen = anchoredScreen ?? NSScreen.main else { return }
        containerView.layoutSubtreeIfNeeded()
        let fitting = hostingController.view.fittingSize
        let width = max(380, ceil(fitting.width))
        let maxHeight = max(220, screen.visibleFrame.height - 24)
        let height = min(maxHeight, max(180, ceil(fitting.height)))

        let minX = screen.frame.minX + 8
        let maxX = screen.frame.maxX - width - 8
        let x = min(max(round(anchoredCenterX - width / 2.0), minX), maxX)
        let y = max(screen.visibleFrame.minY + 8, round(anchoredTopY - height))

        let targetFrame = NSRect(x: x, y: y, width: width, height: height)
        if panel.frame != targetFrame {
            panel.setFrame(targetFrame, display: true, animate: false)
            panel.invalidateShadow()
        }
    }

    private func installDismissMonitors(excluding statusWindow: NSWindow) {
        removeDismissMonitors()
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.close()
        }
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown, event.keyCode == 53 { // Escape
                self.close()
                return nil
            }
            if event.type == .leftMouseDown || event.type == .rightMouseDown {
                if let win = event.window, win != self.panel && win != statusWindow {
                    // Do not dismiss when interacting with dropdown NSMenu windows opened from our panel.
                    let className = NSStringFromClass(type(of: win))
                    if win.level.rawValue < NSWindow.Level.popUpMenu.rawValue && !className.contains("Menu") {
                        self.close()
                    }
                }
            }
            return event
        }
    }

    private func removeDismissMonitors() {
        if let globalClickMonitor {
            NSEvent.removeMonitor(globalClickMonitor)
            self.globalClickMonitor = nil
        }
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }
    }

    deinit {
        removeDismissMonitors()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let monitor = SystemMonitor()
    private var statusItem: NSStatusItem!
    private var canvasView: StatusBarCanvasView!
    private var popupController: StatusPopupController!
    private var lastRenderedMode: MenuBarDisplayMode?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Single-instance guard
        if let bundleID = Bundle.main.bundleIdentifier {
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            if !others.isEmpty {
                NSApp.terminate(nil)
                return
            }
        }

        let initialWidth = monitor.displayMode.statusItemWidth
        statusItem = NSStatusBar.system.statusItem(withLength: initialWidth)
        if let button = statusItem.button {
            button.title = ""
            button.action = #selector(togglePopup(_:))
            button.target = self
            button.toolTip = "MenuBar Stats — CPU & GPU"

            let canvas = StatusBarCanvasView(frame: .zero)
            canvas.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(canvas)
            NSLayoutConstraint.activate([
                canvas.leadingAnchor.constraint(equalTo: button.leadingAnchor),
                canvas.trailingAnchor.constraint(equalTo: button.trailingAnchor),
                canvas.topAnchor.constraint(equalTo: button.topAnchor),
                canvas.bottomAnchor.constraint(equalTo: button.bottomAnchor),
            ])
            canvasView = canvas
        }

        popupController = StatusPopupController(
            rootView: PopoverView(monitor: monitor, onQuit: { [weak self] in self?.quit() })
        )
        popupController.onVisibilityChange = { [weak self] visible in
            self?.monitor.setPopoverOpen(visible)
        }

        monitor.onMenuBarNeedsUpdate = { [weak self] in
            self?.updateStatusItemIfNeeded()
            // Keep popup height cleanly synced downward when Top 5 rows or Graph mode change.
            DispatchQueue.main.async {
                self?.popupController.updatePanelFrameIfVisible()
            }
        }

        updateStatusItemIfNeeded()
        monitor.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor.stop()
    }

    private func updateStatusItemIfNeeded() {
        guard let canvasView else { return }
        let mode = monitor.displayMode

        if lastRenderedMode != mode {
            statusItem.length = mode.statusItemWidth
            lastRenderedMode = mode
        }

        canvasView.update(
            mode: mode,
            cpu: monitor.cpuPercent,
            gpu: monitor.gpuPercent,
            diskUsedFraction: monitor.diskUsage.usedFraction,
            cpuHistory: monitor.cpuHistory.values,
            gpuHistory: monitor.gpuHistory.values
        )
    }

    @objc private func togglePopup(_ sender: AnyObject?) {
        guard let button = statusItem.button else { return }
        popupController.toggle(relativeTo: button)
    }

    private func quit() {
        popupController.close()
        monitor.stop()
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
