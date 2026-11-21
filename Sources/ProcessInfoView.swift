import AppKit
import SwiftUI

private enum InspectorTab: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case windows = "Windows"
    case files = "Files & Net"
    case sample = "Sample"

    var id: String { rawValue }
}

struct ProcessInfoView: View {
    @ObservedObject var inspector: ProcessInspectorModel
    @State private var selectedTab: InspectorTab = .overview
    @State private var showForceQuitConfirm = false

    var body: some View {
        Group {
            if let detail = inspector.detail {
                VStack(alignment: .leading, spacing: 12) {
                    header(detail)
                    metricsGrid(detail)

                    Picker("", selection: $selectedTab) {
                        Text("Overview").tag(InspectorTab.overview)
                        Text("Windows (\(detail.windows.filter(\.isOnScreen).count)/\(detail.windows.count))")
                            .tag(InspectorTab.windows)
                        Text("Files & Net").tag(InspectorTab.files)
                        Text("Sample").tag(InspectorTab.sample)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .controlSize(.small)
                    .onChange(of: selectedTab) { _, tab in
                        if tab == .files && inspector.lsofSummary == nil && !inspector.isLoadingLsof {
                            inspector.refreshLsof()
                        }
                    }

                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            switch selectedTab {
                            case .overview:
                                overviewTab(detail)
                            case .windows:
                                windowsTab(detail)
                            case .files:
                                filesTab(detail)
                            case .sample:
                                sampleTab(detail)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(14)
            } else {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Loading process details…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 460, minHeight: 460)
    }

    private func header(_ d: ProcessDetailSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                iconView(pid: d.pid)
                    .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(d.name)
                            .font(.system(size: 15, weight: .semibold))
                            .lineLimit(1)
                        Text("PID \(d.pid)")
                            .font(.system(size: 11, weight: .medium))
                            .monospacedDigit()
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary.opacity(0.65), in: Capsule())
                        if !d.isAlive {
                            Text("Exited")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.red, in: Capsule())
                        }
                    }

                    Text([d.bundleID, "user: \(d.user)", d.state].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()
            }

            HStack(spacing: 6) {
                Button("Copy PID") { copyToClipboard("\(d.pid)") }
                Button("Copy Cmd") { copyToClipboard(d.commandLine) }
                Button("Reveal") { inspector.revealInFinder() }

                if d.isGUIApp && d.isAlive {
                    Button(d.isHidden ? "Show" : "Focus") { inspector.activateOrToggleHide() }
                    if !d.isHidden {
                        Button("Hide") { inspector.hideApp() }
                    }
                }

                Spacer()

                if d.isOwnedByCurrentUser && d.isAlive {
                    Button("Quit") { inspector.terminateProcess(force: false) }
                    Button("Force Quit", role: .destructive) { showForceQuitConfirm = true }
                        .confirmationDialog(
                            "Force Quit \(d.name) (PID \(d.pid))?",
                            isPresented: $showForceQuitConfirm
                        ) {
                            Button("Force Quit", role: .destructive) { inspector.terminateProcess(force: true) }
                            Button("Cancel", role: .cancel) {}
                        }
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private func metricsGrid(_ d: ProcessDetailSnapshot) -> some View {
        let memoryDisplay = d.taskRates.physFootprintBytes > 0
            ? ProcessInspectorMath.formatBytes(d.taskRates.physFootprintBytes)
            : ProcessInspectorMath.formatBytes(UInt64(max(0, d.rssBytes)))
        let memSubtitle = d.taskRates.physFootprintBytes > 0
            ? "RSS \(ProcessInspectorMath.formatBytes(UInt64(max(0, d.rssBytes)))) · \(String(format: "%.1f%%", d.memPercent))"
            : String(format: "%.1f%% RAM", d.memPercent)

        return HStack(spacing: 8) {
            statBox(
                title: "CPU",
                value: String(format: "%.1f%%", d.cpuPercent),
                subtitle: "Total \(d.cumulativeCPUTime)",
                tint: Color(red: 0.22, green: 0.62, blue: 1.0)
            )
            statBox(
                title: "GPU",
                value: String(format: "%.1f%%", d.gpuPercent),
                subtitle: "Life \(ProcessInspectorMath.formatDurationSeconds(d.lifetimeGPUSeconds))",
                tint: Color(red: 0.80, green: 0.36, blue: 1.0)
            )
            statBox(
                title: "Memory",
                value: memoryDisplay,
                subtitle: memSubtitle,
                tint: Color(red: 0.22, green: 0.82, blue: 0.56)
            )
            statBox(
                title: "Threads",
                value: "\(d.threads.count)",
                subtitle: "\(d.windows.filter(\.isOnScreen).count) on-screen win",
                tint: .orange
            )
        }
    }

    private func statBox(title: String, value: String, subtitle: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(tint)
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
            Text(subtitle)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(.quaternary.opacity(0.42), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func overviewTab(_ d: ProcessDetailSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            groupBox("Identity & Runtime") {
                infoRow("Parent", "\(d.parentName) (PID \(d.ppid))")
                infoRow("Uptime", "\(d.uptime)  (started \(d.started))")
                infoRow("Priority / Nice", d.nice)
                infoRow("Virtual Memory", ProcessInspectorMath.formatBytes(UInt64(max(0, d.vszBytes))))
                if let bundle = d.bundleURL {
                    infoRow("App Bundle", bundle.path)
                }
                infoRow("Executable", d.executablePath)
            }

            groupBox("Command Line") {
                Text(d.commandLine)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            groupBox("Activity & I/O") {
                if d.taskRates.restricted {
                    Text("Detailed I/O & Mach IPC counters are restricted by macOS for processes owned by \(d.user).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    infoRow("Physical Footprint", ProcessInspectorMath.formatBytes(d.taskRates.physFootprintBytes))
                    infoRow("Disk Read / Write", "\(ProcessInspectorMath.formatBytes(d.taskRates.diskReadBytes)) / \(ProcessInspectorMath.formatBytes(d.taskRates.diskWriteBytes))")
                    infoRow("Context Switches", d.taskRates.cswPerSec.map { String(format: "%.1f /s", $0) } ?? "Sampling…")
                    infoRow(
                        "Mach IPC (Sent / Recv)",
                        (d.taskRates.machSentPerSec != nil && d.taskRates.machRecvPerSec != nil)
                            ? String(format: "%.1f / %.1f /s", d.taskRates.machSentPerSec!, d.taskRates.machRecvPerSec!)
                            : "Sampling…"
                    )
                    infoRow("Idle Wakeups / Faults", "\(d.taskRates.idleWakeups) / \(d.taskRates.pageFaults)")
                }
            }

            if !d.threads.isEmpty {
                groupBox("Top Threads (\(d.threads.count) total)") {
                    ForEach(d.threads.prefix(6)) { t in
                        HStack {
                            Text("Thread #\(t.index + 1)")
                                .font(.system(size: 11, weight: .medium))
                                .monospacedDigit()
                            Text(t.state)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                            Text("pri \(t.priority)")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                            Spacer()
                            Text("u:\(t.userTime) s:\(t.sysTime)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Text(String(format: "%.1f%%", t.cpuPercent))
                                .font(.system(size: 11, weight: .semibold))
                                .monospacedDigit()
                                .frame(width: 46, alignment: .trailing)
                        }
                    }
                }
            }
        }
    }

    private func windowsTab(_ d: ProcessDetailSnapshot) -> some View {
        groupBox("Windows (\(d.windows.filter(\.isOnScreen).count) on-screen / \(d.windows.count) total)") {
            if d.windows.isEmpty {
                Text("No windows registered with WindowServer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(d.windows) { w in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(w.isOnScreen ? Color.green : Color.secondary.opacity(0.4))
                            .frame(width: 7, height: 7)
                        Text("#\(w.windowID)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Text("\(Int(w.bounds.width))×\(Int(w.bounds.height))")
                            .font(.system(size: 11, weight: .medium))
                            .monospacedDigit()
                        Text("layer \(w.layer)")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        if !w.title.isEmpty {
                            Text(w.title)
                                .font(.system(size: 11))
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        Spacer()
                        Text(ProcessInspectorMath.formatBytes(UInt64(max(0, w.memoryBytes))))
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                }
            }
        }
    }

    private func filesTab(_ d: ProcessDetailSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Open Files & Network Sockets")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Refresh") { inspector.refreshLsof() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(inspector.isLoadingLsof)
            }

            if inspector.isLoadingLsof {
                ProgressView("Inspecting with lsof…")
                    .controlSize(.small)
            } else if let lsof = inspector.lsofSummary {
                if lsof.restricted {
                    Text("macOS restricts lsof inspection for processes owned by \(d.user).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    groupBox("Summary") {
                        if let cwd = lsof.cwd {
                            infoRow("Working Dir", cwd)
                        }
                        infoRow("Open Descriptors", "\(lsof.totalOpenFiles)")
                        infoRow("Network / Sockets", "\(lsof.sockets.count)")
                    }

                    if !lsof.sockets.isEmpty {
                        groupBox("Sockets & Connections (\(lsof.sockets.count))") {
                            ForEach(Array(lsof.sockets.enumerated()), id: \.offset) { _, s in
                                Text(s)
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .textSelection(.enabled)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }

                    if !lsof.sampleFiles.isEmpty {
                        groupBox("Open Files (first \(lsof.sampleFiles.count))") {
                            ForEach(Array(lsof.sampleFiles.enumerated()), id: \.offset) { _, path in
                                Text(path)
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .textSelection(.enabled)
                                    .lineLimit(1)
                                    .truncationMode(.head)
                            }
                        }
                    }
                }
            }
        }
    }

    private func sampleTab(_ d: ProcessDetailSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("1-Second Live Call Stack Summary")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(inspector.isRunningSample ? "Sampling…" : "Run 1s Sample") {
                    inspector.runOneSecondSample()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(inspector.isRunningSample || !d.isAlive)
            }

            if let output = inspector.sampleOutput {
                Text(output)
                    .font(.system(size: 10.5, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else if !inspector.isRunningSample {
                Text("Click \"Run 1s Sample\" to capture top active functions for this process (works for your user-owned processes; blocked by SIP for root/WindowServer).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func groupBox<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                content()
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 118, alignment: .leading)
            Text(value)
                .font(.system(size: 11, weight: .medium))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func iconView(pid: Int32) -> some View {
        Group {
            if let icon = NSRunningApplication(processIdentifier: pid)?.icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
