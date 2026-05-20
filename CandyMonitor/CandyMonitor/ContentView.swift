import Charts
import AppKit
import SwiftData
import SwiftUI

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @State private var store = MonitorStore()

    var body: some View {
        NavigationSplitView {
            CandySidebar(store: store)
                .navigationSplitViewColumnWidth(min: 230, ideal: 250, max: 300)
        } detail: {
            detail
                .frame(minWidth: 760, minHeight: 540)
                .background(Color(nsColor: .windowBackgroundColor))
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            store.isShowingAddDevice = true
                        } label: {
                            Label("添加设备", systemImage: "plus")
                        }
                    }
                }
        }
        .task {
            store.configure(modelContext: modelContext)
        }
        .onAppear {
            store.configure(modelContext: modelContext)
            store.reloadPersistedState()
        }
        .onChange(of: scenePhase) { _, phase in
            store.isRealtimeRefreshEnabled = phase == .active
            if phase == .active {
                store.reloadPersistedState()
            }
        }
        .sheet(isPresented: Binding(
            get: { store.isShowingAddDevice },
            set: { store.isShowingAddDevice = $0 }
        )) {
            AddDeviceSheet(store: store)
        }
        .alert("可能已经充满", isPresented: Binding(
            get: { store.lowPowerSessionPrompt != nil },
            set: { if !$0 { store.lowPowerSessionPrompt = nil } }
        )) {
            Button("结束记录") {
                if let session = store.lowPowerSessionPrompt {
                    store.stopSession(session, reason: "low_power_confirmed")
                }
            }
            Button("继续记录", role: .cancel) {
                store.lowPowerSessionPrompt = nil
            }
        } message: {
            Text("这一路已经进入低功率尾段，但设备没有返回电量。可以继续等，也可以手动结束并保留完整曲线。")
        }
        .tint(CandyTheme.syrup)
        .accentColor(CandyTheme.syrup)
    }

    @ViewBuilder
    private var detail: some View {
        if store.hasDevices == false {
            EmptyDeviceView {
                store.isShowingAddDevice = true
            }
        } else {
            switch store.selectedSection {
            case .monitor:
                NativeMonitorView(store: store)
            case .sessions:
                SessionsView(store: store)
            case .control:
                ControlConsoleView(store: store)
            case .settings:
                SettingsView(store: store)
            }
        }
    }
}

private struct CandySidebar: View {
    let store: MonitorStore
    @State private var hoveredDevice: UUID?
    @State private var hoveredSection: AppSection?
    @Namespace private var sidebarNamespace

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                Image(systemName: "bolt.badge.clock.fill")
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 64, height: 64)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .shadow(color: Color.accentColor.opacity(0.3), radius: 12, y: 6)

                Text("CandyMonitor")
                    .font(.system(size: 16, weight: .semibold))
            }
            .padding(.top, 48)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 8) {
                Label("设备", systemImage: "rectangle.connected.to.line.below")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)

                if store.devices.isEmpty {
                    Button {
                        store.isShowingAddDevice = true
                    } label: {
                        Label("添加小电拼", systemImage: "plus.circle")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .padding(10)
                    .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    .padding(.horizontal, 12)
                } else {
                    ForEach(store.devices, id: \.id) { device in
                        SidebarRow(
                            title: device.name,
                            subtitle: device.psn ?? device.productFamily ?? "Mirror",
                            icon: "powerplug.portrait",
                            isSelected: store.selectedDeviceID == device.id,
                            isHovered: hoveredDevice == device.id,
                            selectedBackground: CandyTheme.sidebarDeviceSelection,
                            selectedForeground: .primary,
                            selectedSubtitleForeground: .secondary,
                            selectedShadow: .clear,
                            selectedStroke: Color.primary.opacity(0.08),
                            selectionID: "device-\(device.id.uuidString)",
                            namespace: sidebarNamespace
                        ) {
                            store.selectDevice(device)
                        }
                        .onHover { hoveredDevice = $0 ? device.id : nil }
                    }
                }
            }

            Divider()
                .padding(.vertical, 14)
                .padding(.horizontal, 16)

            VStack(spacing: 8) {
                ForEach(AppSection.allCases) { section in
                    SidebarRow(
                        title: section.title,
                        subtitle: nil,
                        icon: section.icon,
                        isSelected: store.selectedSection == section,
                        isHovered: hoveredSection == section,
                        selectionID: "section-\(section.id)",
                        namespace: sidebarNamespace
                    ) {
                        store.selectedSection = section
                    }
                    .onHover { hoveredSection = $0 ? section : nil }
                }
            }

            Spacer()

            HStack(spacing: 8) {
                Circle()
                    .fill(store.connectionState.color)
                    .frame(width: 8, height: 8)
                Text(store.connectionState.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 20)
        }
        .ignoresSafeArea(.container, edges: .top)
    }
}

private struct SidebarRow: View {
    let title: String
    let subtitle: String?
    let icon: String
    let isSelected: Bool
    let isHovered: Bool
    var selectedBackground: Color = Color.accentColor
    var selectedForeground: Color = .white
    var selectedSubtitleForeground: Color = .white.opacity(0.7)
    var selectedShadow: Color = Color.accentColor.opacity(0.28)
    var selectedStroke: Color = .white.opacity(0.22)
    let selectionID: String
    let namespace: Namespace.ID
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 22)
                    .foregroundStyle(isSelected ? selectedForeground : .primary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(isSelected ? selectedForeground : .primary)
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundStyle(isSelected ? selectedSubtitleForeground : .secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, subtitle == nil ? 9 : 8)
            .contentShape(Rectangle())
            .background {
                ZStack {
                    if isHovered && !isSelected {
                        Capsule()
                            .fill(.secondary.opacity(0.08))
                            .transition(.opacity)
                    }

                    if isSelected {
                        Capsule()
                            .fill(selectedBackground)
                            .matchedGeometryEffect(id: selectionID, in: namespace)
                            .shadow(color: selectedShadow, radius: 8, y: 4)
                            .overlay {
                                Capsule()
                                    .stroke(selectedStroke, lineWidth: 1)
                            }
                    }
                }
            }
        }
        .buttonStyle(PressedButtonStyle())
        .padding(.horizontal, 12)
    }
}

private struct EmptyDeviceView: View {
    let addAction: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "bolt.horizontal.icloud")
                .font(.system(size: 48, weight: .semibold))
                .foregroundStyle(Color.accentColor)

            VStack(spacing: 8) {
                Text("还没有添加设备")
                    .font(.title2.weight(.semibold))
                Text("填写小电拼的 MCP SSE 地址后，CandyMonitor 会先握手校验，再开始记录曲线。")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 430)
            }

            Button(action: addAction) {
                Label("添加设备", systemImage: "plus.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

private struct NativeMonitorView: View {
    let store: MonitorStore
    @State private var metric: ChartMetric = .power
    @State private var selectedPortIDs: Set<Int> = []
    @State private var hoveredLiveSample: ChartSamplePoint?
    @State private var detailPort: PortViewState?

    private var effectivePortIDs: Set<Int> {
        selectedPortIDs.isEmpty ? Set(store.livePorts.map(\.port.index)) : selectedPortIDs
    }

    private var filteredSamples: [ChartSamplePoint] {
        store.recentSamples
            .filter { effectivePortIDs.contains($0.portIndex) }
            .sorted { $0.timestamp < $1.timestamp }
    }

    private var lineSamples: [ChartLinePoint] {
        segmentedChartPoints(from: filteredSamples)
    }

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar(title: "我的设备", subtitle: store.selectedDevice?.productFamily ?? "CoCan Mirror") {
                Button {
                    store.selectedSection = .control
                } label: {
                    Label("控制台", systemImage: "slider.horizontal.3")
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    MirrorDeviceHero(
                        deviceName: store.selectedDevice?.name ?? "AI 小电拼",
                        connectionState: store.connectionState,
                        lastRefreshedAt: store.lastRefreshedAt,
                        temperatureMode: LocalizedTelemetry.temperatureModeLabel(store.temperatureModeLabel),
                        activeSessions: store.activeChargingSessions.count
                    )

                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 12) {
                            topologyPanel
                                .frame(minWidth: 500)
                                .frame(height: dashboardHeight)

                            VStack(spacing: 10) {
                                nativeMetrics
                                recordingPanel(fillsHeight: true)
                            }
                            .frame(width: 280, height: dashboardHeight, alignment: .top)
                        }

                        VStack(spacing: 12) {
                            topologyPanel
                            nativeMetrics
                            recordingPanel()
                        }
                    }

                    chartPanel
                }
                .padding(16)
            }
        }
        .onChange(of: store.livePorts) { _, ports in
            selectedPortIDs = selectedPortIDs.intersection(Set(ports.map(\.port.index)))
            if let detailPort,
               let refreshed = ports.first(where: { $0.port.index == detailPort.port.index }) {
                self.detailPort = refreshed
            }
        }
        .sheet(item: $detailPort) { port in
            PortDetailSheet(
                port: port,
                session: store.activeSession(for: port.port.index),
                store: store
            )
        }
    }

    private var nativeMetrics: some View {
        VStack(spacing: 8) {
            MetricCard(title: "实时功率", value: String(format: "%.1f W", store.totalPowerW), icon: "bolt.fill")
            MetricCard(title: "端口", value: "\(store.livePorts.filter(\.connected).count)/\(store.livePorts.count)", icon: "powerplug")
            MetricCard(title: "活跃记录", value: "\(store.activeChargingSessions.count)", icon: "record.circle")
        }
    }

    private var topologyPanel: some View {
        MirrorPowerTopologyPanel(
            ports: store.livePorts,
            totalPowerW: store.totalPowerW,
            selectedPortIDs: selectedPortIDs,
            selectPort: { detailPort = $0 },
            togglePort: togglePort
        )
    }

    private var dashboardHeight: CGFloat { 394 }

    private var chartPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("实时采样曲线")
                        .font(.headline)
                    Text("按端口筛选，观察功率、电压、电流和温度变化。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("指标", selection: $metric) {
                    ForEach(ChartMetric.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 320)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)

            portFilterBar

            ZStack(alignment: .topLeading) {
                Chart(lineSamples) { point in
                    LineMark(
                        x: .value("Time", point.sample.timestamp),
                        y: .value(metric.title, metric.displayValue(point.sample)),
                        series: .value("Segment", point.seriesID)
                    )
                    .foregroundStyle(by: .value("Port", point.sample.portName))
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.linear)

                    if hoveredLiveSample?.id == point.sample.id {
                        RuleMark(x: .value("Time", point.sample.timestamp))
                            .foregroundStyle(CandyTheme.syrup.opacity(0.42))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        PointMark(
                            x: .value("Time", point.sample.timestamp),
                            y: .value(metric.title, metric.displayValue(point.sample))
                        )
                        .foregroundStyle(CandyTheme.syrup)
                        .symbolSize(90)
                    }
                }
                .chartYAxisLabel(metric.axisLabel)
                .chartYScale(domain: metric.displayDomain(for: filteredSamples))
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        Rectangle()
                            .fill(.clear)
                            .contentShape(Rectangle())
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let location):
                                    updateHover(location: location, proxy: proxy, geometry: geometry)
                                case .ended:
                                    hoveredLiveSample = nil
                                }
                            }
                    }
                }
                .frame(height: 220)

                if let hoveredLiveSample {
                    ChartReadout(sample: hoveredLiveSample, metric: metric)
                        .padding(14)
                }
            }
            .padding(14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(CandyTheme.separator, lineWidth: 1)
            }

            if filteredSamples.isEmpty {
                Text("暂无采样。连接负载后会自动开始记录完整充电曲线。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func recordingPanel(fillsHeight: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Label("全程充电记录", systemImage: "waveform.path.ecg")
                .font(.headline)
            Text(recordingText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let session = store.activeChargingSessions.first {
                HStack {
                    Button {
                        store.selectSession(session)
                        store.selectedSection = .sessions
                    } label: {
                        Label("曲线", systemImage: "chart.xyaxis.line")
                    }
                    Button {
                        store.exportSessionCSV(session)
                    } label: {
                        Label("CSV", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                Text("接上设备后自动开始")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(CandyTheme.mint)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(CandyTheme.mint.opacity(0.12), in: Capsule())
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: fillsHeight ? .infinity : nil, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(CandyTheme.separator, lineWidth: 1)
        }
    }

    private var recordingText: String {
        if let session = store.activeChargingSessions.first {
            let minutes = Int(Date().timeIntervalSince(session.startedAt) / 60)
            return "\(session.portName) 正在记录全程曲线，已采 \(session.sampleCount) 个点，持续 \(minutes) 分钟。"
        }
        return "每个端口独立记录，从有功率输出开始，到满电、拔掉或手动停止结束。"
    }

    private var portFilterBar: some View {
        HStack(spacing: 8) {
            FilterChip(title: "全部", isSelected: selectedPortIDs.isEmpty) {
                selectedPortIDs.removeAll()
            }
            ForEach(store.livePorts) { port in
                FilterChip(
                    title: port.port.displayName,
                    isSelected: selectedPortIDs.contains(port.port.index)
                ) {
                    togglePort(port.port.index)
                }
            }
        }
    }

    private func togglePort(_ port: Int) {
        if selectedPortIDs.isEmpty {
            selectedPortIDs = [port]
        } else if selectedPortIDs.contains(port) {
            selectedPortIDs.remove(port)
        } else {
            selectedPortIDs.insert(port)
        }
    }

    private func updateHover(location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) {
        guard let plotAnchor = proxy.plotFrame else {
            hoveredLiveSample = nil
            return
        }
        let plotFrame = geometry[plotAnchor]
        guard plotFrame.contains(location),
              let date: Date = proxy.value(atX: location.x - plotFrame.origin.x) else {
            hoveredLiveSample = nil
            return
        }

        hoveredLiveSample = filteredSamples.min {
            abs($0.timestamp.timeIntervalSince(date)) < abs($1.timestamp.timeIntervalSince(date))
        }
    }
}

private struct MirrorDeviceHero: View {
    let deviceName: String
    let connectionState: ConnectionState
    let lastRefreshedAt: Date?
    let temperatureMode: String
    let activeSessions: Int

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text("CoCan")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                    Text("Mirror")
                        .font(.system(size: 15, weight: .semibold, design: .rounded).italic())
                        .foregroundStyle(CandyTheme.syrup)
                }

                HStack(spacing: 8) {
                    Text(deviceName)
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .lineLimit(1)
                    Image(systemName: "seal.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(CandyTheme.syrup)
                }

                HStack(spacing: 8) {
                    MirrorStatusBadge(title: connectionState == .connected ? "在线" : connectionState.label, color: connectionState.color)
                    Text(lastRefreshedAt.map { "刷新于 \($0.formatted(date: .omitted, time: .standard))" } ?? "等待刷新")
                        .font(.callout.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 8) {
                HStack(spacing: 8) {
                    MirrorFeaturePill(title: "温控", icon: "thermometer.medium", isActive: false)
                    MirrorFeaturePill(title: "自由流", icon: "sun.max", isActive: true)
                    MirrorFeaturePill(title: "睡眠充", icon: "moon.zzz", isActive: false)
                    MirrorFeaturePill(title: "小家电", icon: "battery.50", isActive: false)
                }
                HStack(spacing: 8) {
                    MirrorRoundStatusIcon(systemName: "wifi", color: .secondary)
                    MirrorRoundStatusIcon(systemName: "point.3.connected.trianglepath.dotted", color: CandyTheme.syrup)
                    MirrorSubstatus(title: "当前温控", value: temperatureMode)
                    MirrorSubstatus(title: "记录中", value: "\(activeSessions)")
                }
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(CandyTheme.separator, lineWidth: 1)
        }
    }
}

private enum MirrorTopologyLayout {
    static let chargerWidth: CGFloat = 260
    static let chargerHeight: CGFloat = 96
    static let chargerTrailingPadding: CGFloat = 8
    static let chargerBottomPadding: CGFloat = 4
}

private struct MirrorPowerTopologyPanel: View {
    let ports: [PortViewState]
    let totalPowerW: Double
    let selectedPortIDs: Set<Int>
    let selectPort: (PortViewState) -> Void
    let togglePort: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("功率拓扑")
                        .font(.headline)
                    Text("实时充电功率")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                capacityBadge
                Text(String(format: "%.1fW", totalPowerW))
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(CandyTheme.syrup)
            }

            HStack(spacing: 10) {
                ForEach(ports) { port in
                    MirrorPortTile(
                        port: port,
                        isSelected: selectedPortIDs.isEmpty || selectedPortIDs.contains(port.port.index)
                    ) {
                        selectPort(port)
                    } toggle: {
                        togglePort(port.port.index)
                    }
                }
            }

            ZStack(alignment: .bottom) {
                GeometryReader { proxy in
                    ForEach(Array(ports.enumerated()), id: \.element.id) { index, port in
                        MirrorCablePath(index: index, total: max(ports.count, 1))
                            .stroke(
                                port.connected ? CandyTheme.syrup.opacity(0.55) : CandyTheme.syrup.opacity(0.26),
                                style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [1, 7])
                            )
                            .frame(width: proxy.size.width, height: proxy.size.height)
                    }
                }
                .allowsHitTesting(false)

                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        MirrorLegend()
                        HStack(spacing: 8) {
                            Image(systemName: "hourglass")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white)
                                .frame(width: 20, height: 20)
                                .background(.secondary.opacity(0.55), in: Circle())
                            Text(totalPowerW > 0.5 ? "供电中" : "待机中")
                                .font(.callout.weight(.semibold))
                        }
                    }
                    Spacer()
                    MirrorChargerIllustration()
                        .frame(width: MirrorTopologyLayout.chargerWidth, height: MirrorTopologyLayout.chargerHeight)
                }
                .padding(.horizontal, 8)
                .padding(.bottom, MirrorTopologyLayout.chargerBottomPadding)
            }
            .frame(height: 204)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(CandyTheme.separator, lineWidth: 1)
        }
    }

    private var capacityBadge: some View {
        HStack(spacing: 6) {
            Text("4C 1A")
                .font(.caption.weight(.bold))
            Text("160W")
                .font(.callout.weight(.bold).monospacedDigit())
            Text("\(Int(min(totalPowerW / 160, 1) * 100))%")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(CandyTheme.syrup)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
        .overlay {
            Capsule()
                .stroke(CandyTheme.syrup.opacity(0.65), lineWidth: 1)
        }
    }
}

private struct MirrorPortTile: View {
    let port: PortViewState
    let isSelected: Bool
    let action: () -> Void
    let toggle: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Text(port.port.displayName)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                MirrorConnectorGlyph(connectorType: port.port.connectorType)
                    .frame(width: 44, height: 16)
                Text(port.connected ? String(format: "%.1fW", port.powerW) : "待机中")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(port.connected ? CandyTheme.mint : CandyTheme.syrup.opacity(0.76))
                    .lineLimit(1)
                Divider()
                    .padding(.horizontal, 2)
                    .opacity(0.72)
                Text("\(port.port.power)W")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 92)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isSelected ? CandyTheme.syrup.opacity(0.66) : CandyTheme.syrup.opacity(0.22), lineWidth: 1.4)
            }
        }
        .buttonStyle(PressedButtonStyle())
        .contextMenu {
            Button("筛选此端口", action: toggle)
            Button("查看详情", action: action)
        }
    }
}

private struct MirrorConnectorGlyph: View {
    let connectorType: String
    var activeColor: Color = CandyTheme.syrup

    private var isUSBA: Bool {
        connectorType.lowercased().contains("a")
    }

    var body: some View {
        ZStack {
            if isUSBA {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .stroke(.secondary, lineWidth: 1.5)
                    .frame(width: 28, height: 12)
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(activeColor.opacity(0.72))
                    .frame(width: 18, height: 4)
            } else {
                Capsule()
                    .stroke(.secondary, lineWidth: 1.5)
                    .frame(width: 34, height: 8)
                Capsule()
                    .fill(activeColor.opacity(0.72))
                    .frame(width: 21, height: 3)
            }
        }
        .accessibilityLabel(isUSBA ? "USB-A" : "USB-C")
    }
}

private struct MirrorCablePath: Shape {
    let index: Int
    let total: Int

    func path(in rect: CGRect) -> Path {
        let count = max(total, 1)
        let step = rect.width / CGFloat(count)
        let startX = step * (CGFloat(index) + 0.5)
        let chargerCenterX = rect.width - MirrorTopologyLayout.chargerTrailingPadding - MirrorTopologyLayout.chargerWidth / 2
        let endX = chargerCenterX
        let start = CGPoint(x: startX, y: 0)
        let end = CGPoint(x: endX, y: rect.height - MirrorTopologyLayout.chargerBottomPadding - MirrorTopologyLayout.chargerHeight / 2)
        let drift = CGFloat(index - count / 2) * 14

        var path = Path()
        path.move(to: start)
        path.addCurve(
            to: end,
            control1: CGPoint(x: startX + drift, y: rect.height * 0.30),
            control2: CGPoint(x: endX - drift, y: rect.height * 0.66)
        )
        return path
    }
}

private struct MirrorChargerIllustration: View {
    var body: some View {
        Image("Mirror4C1ADevice")
            .resizable()
            .scaledToFit()
            .shadow(color: .black.opacity(0.18), radius: 10, y: 5)
            .accessibilityLabel("小电拼 4C1A 图示")
    }
}

private struct MirrorLegend: View {
    var body: some View {
        HStack(spacing: 10) {
            legendItem(color: CandyTheme.syrup, title: "充电功率")
            legendItem(color: .secondary.opacity(0.5), title: "端口关闭")
            HStack(spacing: 4) {
                Rectangle()
                    .fill(CandyTheme.syrup.opacity(0.45))
                    .frame(width: 12, height: 8)
                    .mask {
                        HStack(spacing: 2) {
                            ForEach(0..<4, id: \.self) { _ in
                                Rectangle().frame(width: 2)
                            }
                        }
                    }
                Text("待机中")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            legendItem(color: CandyTheme.mint, title: ">80%")
        }
    }

    private func legendItem(color: Color, title: String) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 9, height: 9)
            Text(title)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

private struct MirrorFeaturePill: View {
    let title: String
    let icon: String
    let isActive: Bool

    var body: some View {
        Label(title, systemImage: icon)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .foregroundStyle(isActive ? .white : .primary)
            .background(isActive ? CandyTheme.syrup : Color.secondary.opacity(0.10), in: Capsule())
            .overlay {
                Capsule()
                    .stroke(isActive ? .clear : .secondary.opacity(0.24), lineWidth: 1)
            }
    }
}

private struct MirrorRoundStatusIcon: View {
    let systemName: String
    let color: Color

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(color)
            .frame(width: 38, height: 38)
            .background(.regularMaterial, in: Circle())
            .overlay {
                Circle()
                    .stroke(CandyTheme.separator, lineWidth: 1)
            }
    }
}

private struct MirrorStatusBadge: View {
    let title: String
    let color: Color

    var body: some View {
        Text(title)
            .font(.caption.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color, in: Capsule())
    }
}

private struct MirrorSubstatus: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

private struct MonitorView: View {
    let store: MonitorStore
    @State private var metric: ChartMetric = .power
    @State private var selectedPortIDs: Set<Int> = []
    @State private var hoveredLiveSample: ChartSamplePoint?
    @State private var detailPort: PortViewState?

    private var effectivePortIDs: Set<Int> {
        selectedPortIDs.isEmpty ? Set(store.livePorts.map(\.port.index)) : selectedPortIDs
    }

    private var filteredSamples: [ChartSamplePoint] {
        store.recentSamples
            .filter { effectivePortIDs.contains($0.portIndex) }
            .sorted { $0.timestamp < $1.timestamp }
    }

    private var lineSamples: [ChartLinePoint] {
        segmentedChartPoints(from: filteredSamples)
    }

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar(title: "今日的糖流", subtitle: store.selectedDevice?.name ?? "-") {
                Button {
                    store.selectedSection = .sessions
                } label: {
                    Label("全程记录", systemImage: "clock.arrow.circlepath")
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    recordingPanel
                    metrics
                    portGrid
                    chartPanel
                }
                .padding(24)
            }
        }
        .onChange(of: store.livePorts) { _, ports in
            selectedPortIDs = selectedPortIDs.intersection(Set(ports.map(\.port.index)))
            if let detailPort,
               let refreshed = ports.first(where: { $0.port.index == detailPort.port.index }) {
                self.detailPort = refreshed
            }
        }
        .sheet(item: $detailPort) { port in
            PortDetailSheet(
                port: port,
                session: store.activeSession(for: port.port.index),
                store: store
            )
        }
    }

    private var metrics: some View {
        HStack(spacing: 12) {
            MetricCard(title: "总功率", value: String(format: "%.1f W", store.totalPowerW), icon: "bolt.fill")
            MetricCard(title: "温控", value: LocalizedTelemetry.temperatureModeLabel(store.temperatureModeLabel), icon: "thermometer.medium")
            MetricCard(title: "端口", value: "\(store.livePorts.filter(\.connected).count)/\(store.livePorts.count)", icon: "powerplug")
            MetricCard(title: "记录", value: "\(store.sessions.filter { $0.endedAt == nil }.count)", icon: "record.circle")
        }
    }

    private var portGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 5), spacing: 12) {
            ForEach(store.livePorts) { port in
                PortCard(
                    port: port,
                    isSelected: selectedPortIDs.contains(port.port.index)
                ) {
                    detailPort = port
                }
            }
        }
    }

    private var chartPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("20 分钟曲线")
                        .font(.headline)
                    Text("点接口卡片查看详情；下方芯片切换单路曲线。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Picker("指标", selection: $metric) {
                        ForEach(ChartMetric.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 320)
                }
                portFilterBar
            }

            ZStack(alignment: .topLeading) {
                Chart(lineSamples) { point in
                    LineMark(
                        x: .value("Time", point.sample.timestamp),
                        y: .value(metric.title, metric.displayValue(point.sample)),
                        series: .value("Segment", point.seriesID)
                    )
                    .foregroundStyle(by: .value("Port", point.sample.portName))
                    .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.linear)

                    if hoveredLiveSample?.id == point.sample.id {
                        RuleMark(x: .value("Time", point.sample.timestamp))
                            .foregroundStyle(CandyTheme.berry.opacity(0.45))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        PointMark(
                            x: .value("Time", point.sample.timestamp),
                            y: .value(metric.title, metric.displayValue(point.sample))
                        )
                        .foregroundStyle(CandyTheme.berry)
                        .symbolSize(90)
                    }
                }
                .chartYAxisLabel(metric.axisLabel)
                .chartYScale(domain: metric.displayDomain(for: filteredSamples))
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        Rectangle()
                            .fill(.clear)
                            .contentShape(Rectangle())
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let location):
                                    updateHover(location: location, proxy: proxy, geometry: geometry)
                                case .ended:
                                    hoveredLiveSample = nil
                                }
                            }
                    }
                }
                .frame(height: 300)

                if let hoveredLiveSample {
                    ChartReadout(sample: hoveredLiveSample, metric: metric)
                        .padding(14)
                }
            }
            .padding(16)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            if filteredSamples.isEmpty {
                Text("暂无采样。连接负载后会自动开始记录完整充电曲线。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var recordingPanel: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Label("全程充电记录", systemImage: "sparkles")
                    .font(.headline)
                    .foregroundStyle(CandyTheme.ink)
                Text(recordingText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let session = store.activeChargingSessions.first {
                Button {
                    store.selectSession(session)
                    store.selectedSection = .sessions
                } label: {
                    Label("查看曲线", systemImage: "chart.xyaxis.line")
                }
                Button {
                    store.exportSessionCSV(session)
                } label: {
                    Label("导出 CSV", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)
            } else {
                Text("接上设备后自动开始")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(CandyTheme.mint)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(CandyTheme.mint.opacity(0.12), in: Capsule())
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var recordingText: String {
        if let session = store.activeChargingSessions.first {
            let minutes = Int(Date().timeIntervalSince(session.startedAt) / 60)
            return "\(session.portName) 正在记录全程曲线，已采 \(session.sampleCount) 个点，持续 \(minutes) 分钟。"
        }
        return "每个端口独立记录，从有功率输出开始，到满电、拔掉或手动停止结束。CSV 会保留逐采样数据和摘要。"
    }

    private var portFilterBar: some View {
        HStack(spacing: 8) {
            FilterChip(title: "全部", isSelected: selectedPortIDs.isEmpty) {
                selectedPortIDs.removeAll()
            }
            ForEach(store.livePorts) { port in
                FilterChip(
                    title: port.port.displayName,
                    isSelected: selectedPortIDs.contains(port.port.index)
                ) {
                    togglePort(port.port.index)
                }
            }
        }
    }

    private func togglePort(_ port: Int) {
        if selectedPortIDs.isEmpty {
            selectedPortIDs = [port]
        } else if selectedPortIDs.contains(port) {
            selectedPortIDs.remove(port)
        } else {
            selectedPortIDs.insert(port)
        }
    }

    private func updateHover(location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) {
        guard let plotAnchor = proxy.plotFrame else {
            hoveredLiveSample = nil
            return
        }
        let plotFrame = geometry[plotAnchor]
        guard plotFrame.contains(location),
              let date: Date = proxy.value(atX: location.x - plotFrame.origin.x) else {
            hoveredLiveSample = nil
            return
        }

        hoveredLiveSample = filteredSamples.min {
            abs($0.timestamp.timeIntervalSince(date)) < abs($1.timestamp.timeIntervalSince(date))
        }
    }
}

private enum ChartMetric: String, CaseIterable, Identifiable {
    case power
    case voltage
    case current
    case temperature

    var id: String { rawValue }

    var title: String {
        switch self {
        case .power: "功率"
        case .voltage: "电压"
        case .current: "电流"
        case .temperature: "温度"
        }
    }

    var axisLabel: String {
        switch self {
        case .power: "W"
        case .voltage: "V"
        case .current: "A"
        case .temperature: "温度等级"
        }
    }

    func displayValue(_ sample: ChartSamplePoint) -> Double {
        switch self {
        case .power:
            sample.powerW < Self.idlePowerDeadband ? 0 : sample.powerW
        case .voltage:
            sample.powerW < Self.idlePowerDeadband && sample.currentA < Self.idleCurrentDeadband ? 0 : sample.voltageV
        case .current:
            sample.currentA < Self.idleCurrentDeadband ? 0 : sample.currentA
        case .temperature: sample.temperatureScore
        }
    }

    func formattedValue(_ sample: ChartSamplePoint) -> String {
        switch self {
        case .power:
            return String(format: "%.1f W", displayValue(sample))
        case .voltage:
            return String(format: "%.2f V", displayValue(sample))
        case .current:
            return String(format: "%.2f A", displayValue(sample))
        case .temperature:
            return String(format: "%.0f", sample.temperatureScore)
        }
    }

    func displayDomain(for samples: [ChartSamplePoint]) -> ClosedRange<Double> {
        let maxValue = samples.map(displayValue).max() ?? 0
        switch self {
        case .power:
            return 0...(max(5, ceil(maxValue * 1.15)))
        case .current:
            return 0...(max(0.5, maxValue * 1.15))
        case .voltage:
            return 0...(max(5, ceil(maxValue * 1.1)))
        case .temperature:
            return 0...(max(5, ceil(maxValue * 1.1)))
        }
    }

    private static let idlePowerDeadband = 0.5
    private static let idleCurrentDeadband = 0.05
}

private struct ChartLinePoint: Identifiable {
    let id: String
    let sample: ChartSamplePoint
    let seriesID: String
}

private func segmentedChartPoints(from samples: [ChartSamplePoint]) -> [ChartLinePoint] {
    let grouped = Dictionary(grouping: samples) { $0.portIndex }
    var points: [ChartLinePoint] = []

    for portIndex in grouped.keys.sorted() {
        let sortedSamples = (grouped[portIndex] ?? []).sorted { $0.timestamp < $1.timestamp }
        var segment = 0
        var previous: ChartSamplePoint?

        for sample in sortedSamples {
            if let previous,
               sample.timestamp.timeIntervalSince(previous.timestamp) > 4 || sample.connected != previous.connected {
                segment += 1
            }
            points.append(ChartLinePoint(
                id: "\(sample.id.uuidString)-\(segment)",
                sample: sample,
                seriesID: "\(sample.portName)-\(segment)"
            ))
            previous = sample
        }
    }

    return points
}

private struct FilterChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.callout.weight(.medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .foregroundStyle(isSelected ? .white : CandyTheme.ink)
                .background(isSelected ? CandyTheme.syrup : Color.secondary.opacity(0.10), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct ChartReadout: View {
    let sample: ChartSamplePoint
    let metric: ChartMetric

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(sample.portName)
                .font(.caption.weight(.semibold))
            Text(sample.timestamp, format: .dateTime.hour().minute().second())
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("\(metric.title) \(metric.formattedValue(sample))")
                .font(.headline.monospacedDigit())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(CandyTheme.syrup.opacity(0.28), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.12), radius: 12, y: 6)
    }
}

private enum CandyTheme {
    static let ink = Color.primary
    static let cream = adaptive(
        light: NSColor(calibratedRed: 0.97, green: 0.96, blue: 0.94, alpha: 1),
        dark: NSColor(calibratedRed: 0.18, green: 0.18, blue: 0.18, alpha: 1)
    )
    static let syrup = Color(red: 1.00, green: 0.28, blue: 0.12)
    static let mint = Color(red: 0.10, green: 0.68, blue: 0.24)
    static let berry = Color(red: 0.84, green: 0.24, blue: 0.34)
    static let caramel = Color(red: 0.95, green: 0.55, blue: 0.18)
    static let sidebarDeviceSelection = adaptive(
        light: NSColor(calibratedWhite: 0.90, alpha: 1),
        dark: NSColor(calibratedWhite: 0.24, alpha: 1)
    )
    static let separator = Color.primary.opacity(0.08)

    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

private struct PortCard: View {
    let port: PortViewState
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(port.port.displayName)
                        .font(.headline)
                    Spacer()
                    Circle()
                        .fill(port.connected ? CandyTheme.mint : .secondary.opacity(0.35))
                        .frame(width: 9, height: 9)
                }

                Text(String(format: "%.1f W", port.powerW))
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .monospacedDigit()

                VStack(alignment: .leading, spacing: 4) {
                    Text(port.chargeStateLabel)
                    Text(port.protocolLabel)
                        .lineLimit(1)
                    Text("\(port.voltageText) / \(port.currentText)")
                    Text("温度 \(port.temperatureLabel)")
                    if let battery = port.batteryPercent {
                        Text("电量 \(Int(battery))%")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isSelected ? CandyTheme.syrup : .clear, lineWidth: 2)
            }
        }
        .buttonStyle(PressedButtonStyle())
    }
}

private struct PortDetailSheet: View {
    let port: PortViewState
    let session: ChargingSession?
    let store: MonitorStore
    @Environment(\.dismiss) private var dismiss
    @State private var pendingPowerState: Bool?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 34, height: 34)
                        .background(.secondary.opacity(0.10), in: Circle())
                }
                .buttonStyle(PressedButtonStyle())

                Spacer()
                Text("端口详情")
                    .font(.title3.weight(.semibold))
                Spacer()

                SyncStatusView(date: store.lastRefreshedAt, isRefreshing: store.isRefreshingNow)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("点击端口查看详情")
                        .font(.headline)
                        .foregroundStyle(.secondary)

                    PortMapView(selectedPort: port.port.index)

                    sectionHeader("\(portTitle) \(port.connected ? "在充设备" : "未接入设备")")

                    detailCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(deviceTitle)
                                .font(.title2.weight(.semibold))
                            Text(deviceSubtitle)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 18) {
                            PortDetailMetric(title: "品牌", value: isXiaomiSurgeCharge ? "小米" : "-")
                            PortDetailMetric(title: "型号", value: port.detail?.deviceNameZH ?? port.detail?.deviceNameEN ?? (isXiaomiSurgeCharge ? "澎湃秒充" : "-"))
                            PortDetailMetric(title: "电池容量(mWh)", value: "-")
                            PortDetailMetric(title: "健康度", value: "-")
                            PortDetailMetric(title: "当前电量", value: port.batteryPercent.map { "\(Int($0))%" } ?? "-")
                            PortDetailMetric(title: "预计充满", value: "-")
                        }
                    }

                    Text("仅支持 PD 协议，且部分设备厂商信息不准，仅供参考")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    sectionHeader("\(portTitle) 充电口")

                    detailCard {
                        HStack {
                            Label(port.portSwitchState == nil ? "实时端口数据" : "充电口开关", systemImage: port.portSwitchState == nil ? "waveform.path.ecg" : "shippingbox")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(CandyTheme.caramel)
                            Spacer()
                            if let portSwitchState = port.portSwitchState {
                                Button {
                                    pendingPowerState = !portSwitchState
                                } label: {
                                    Label(portSwitchState ? "关闭" : "开启", systemImage: portSwitchState ? "power.circle" : "power.circle.fill")
                                }
                                .buttonStyle(SoftButtonStyle(prominent: portSwitchState == false, destructive: portSwitchState))
                            } else {
                                StatusPill(text: "开关状态未上报", color: .secondary)
                            }
                        }

                        if let portSwitchHelpText {
                            Text(portSwitchHelpText)
                                .font(.callout)
                                .foregroundStyle(.secondary)

                            Divider()
                        }

                        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 18) {
                            PortDetailMetric(title: "电压(V)", value: String(format: "%.2f", Double(port.detail?.voutMV ?? 0) / 1000))
                            PortDetailMetric(title: "电流(A)", value: String(format: "%.2f", Double(port.detail?.ioutMA ?? 0) / 1000))
                            PortDetailMetric(title: "功率(W)", value: String(format: "%.1f", port.powerW))
                            PortDetailMetric(title: "协议", value: port.protocolLabel)
                            PortDetailMetric(title: "端口", value: port.port.connectorType.uppercased())
                            PortDetailMetric(title: "充电时长(min)", value: sessionDurationText)
                        }
                    }

                    sectionHeader("\(portTitle) 兼容协议")

                    detailCard {
                        FlowChips(items: protocolChips)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 26)
            }
        }
        .frame(width: 620, height: 760)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            await store.refreshSelectedDeviceNow()
        }
        .confirmationDialog("确认控制操作", isPresented: Binding(
            get: { pendingPowerState != nil },
            set: { if !$0 { pendingPowerState = nil } }
        )) {
            if let pendingPowerState {
                Button(pendingPowerState ? "确认开启" : "确认关闭", role: pendingPowerState ? nil : .destructive) {
                    Task {
                        await store.setPort(port.port.index, enabled: pendingPowerState)
                        self.pendingPowerState = nil
                    }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("\(pendingPowerState == true ? "开启" : "关闭") \(port.port.displayName) 充电口。")
        }
    }

    private var portTitle: String {
        port.port.connectorType.uppercased().contains("C") ? "USB-\(port.port.displayName)" : "USB-A"
    }

    private var portSwitchHelpText: String? {
        guard let portSwitchState = port.portSwitchState else { return nil }
        let prefix = portSwitchState ? "当前充电口已开启。" : "当前充电口已关闭。"
        return "\(prefix)开则充电口可用，关则充电口不可用。执行后 CandyMonitor 会重新读取设备状态。"
    }

    private var deviceTitle: String {
        if let name = port.detail?.deviceNameZH ?? port.detail?.deviceNameEN, name.isEmpty == false {
            return name
        }
        if isXiaomiSurgeCharge {
            return "小米澎湃秒充设备"
        }
        return "未知设备型号"
    }

    private var deviceSubtitle: String {
        if isXiaomiSurgeCharge {
            return "检测到小米私有快充协议；设备型号和电池信息不一定会通过标准 PD 返回。"
        }
        if port.connected {
            return port.batteryPercent == nil
                ? "此设备没有正确实现标准协议，无法准确识别设备型号和电池电量等信息。"
                : "已读取到 PD 电量数据，曲线会优先使用电量判断满电。"
        }
        return "当前端口没有检测到负载，接入设备后会自动刷新这里的信息。"
    }

    private var isXiaomiSurgeCharge: Bool {
        port.protocolLabel == "小米澎湃秒充"
    }

    private var sessionDurationText: String {
        guard let session else { return "-" }
        let seconds = Int((session.endedAt ?? Date()).timeIntervalSince(session.startedAt))
        return "\(max(seconds / 60, 0))"
    }

    private var protocolChips: [String] {
        var items = [
            port.protocolLabel,
            port.port.connectorType.uppercased(),
            "最高 \(port.port.power) W",
            "温度 \(port.temperatureLabel)"
        ]
        if let battery = port.batteryPercent {
            items.append("电量 \(Int(battery))%")
        } else {
            items.append("无电量数据")
        }
        if port.detail?.sessionChargeMWh ?? 0 > 0 {
            items.append(String(format: "本次 %.2f Wh", Double(port.detail?.sessionChargeMWh ?? 0) / 1000))
        }
        return items
    }

    @ViewBuilder
    private func detailCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            content()
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.primary.opacity(0.05), lineWidth: 1)
        }
    }

    private func sectionHeader(_ title: String, trailing: String? = nil) -> some View {
        HStack {
            Text(title)
                .font(.title2.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct PortMapView: View {
    let selectedPort: Int

    var body: some View {
        HStack(spacing: 20) {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.regularMaterial)
                .frame(height: 120)
                .overlay {
                    HStack(spacing: 22) {
                        portGlyph(name: "A", index: 1, width: 86)
                        portGlyph(name: "C1", index: 2, width: 68)
                        portGlyph(name: "C2", index: 3, width: 68)
                        portGlyph(name: "C3", index: 4, width: 68)
                    }
                    .padding(.horizontal, 26)
                }
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.regularMaterial)
                .frame(width: 106, height: 120)
                .overlay {
                    portGlyph(name: "C4", index: 5, width: 68)
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(.primary.opacity(0.08), lineWidth: 1)
        }
    }

    private func portGlyph(name: String, index: Int, width: CGFloat) -> some View {
        VStack(spacing: 8) {
            RoundedRectangle(cornerRadius: name == "A" ? 4 : 8, style: .continuous)
                .stroke(selectedPort == index ? CandyTheme.caramel : .primary.opacity(0.55), lineWidth: 3)
                .frame(width: width, height: name == "A" ? 24 : 18)
                .overlay(alignment: .topTrailing) {
                    if selectedPort == index {
                        Image(systemName: "bolt.fill")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(CandyTheme.caramel)
                            .offset(x: 18, y: -8)
                    }
                }
            Text(name)
                .font(.callout.weight(.medium))
                .foregroundStyle(selectedPort == index ? CandyTheme.caramel : .secondary)
        }
    }
}

private struct PortDetailMetric: View {
    let title: String
    let value: String

    var body: some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct FlowChips: View {
    let items: [String]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 10)], alignment: .leading, spacing: 10) {
            ForEach(items, id: \.self) { item in
                Text(item)
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                    .background(.secondary.opacity(0.08), in: Capsule())
            }
        }
    }
}

private struct SessionsView: View {
    let store: MonitorStore
    @State private var selectedSessionIDs = Set<UUID>()
    @State private var isConfirmingBulkDelete = false

    var body: some View {
        Group {
            if store.sessions.isEmpty {
                VStack(spacing: 0) {
                    HeaderBar(title: "充电记录", subtitle: "0 条会话")
                    ContentUnavailableView(
                        "暂无充电记录",
                        systemImage: "chart.xyaxis.line",
                        description: Text("接入设备并开始充电后，会自动生成完整曲线。")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .background(Color(nsColor: .windowBackgroundColor))
            } else {
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        HeaderBar(title: "充电记录", subtitle: "\(store.sessions.count) 条会话") {
                            HStack(spacing: 8) {
                                if selectedSessionIDs.isEmpty == false {
                                    Button("取消选择") {
                                        selectedSessionIDs.removeAll()
                                    }
                                    .buttonStyle(SoftButtonStyle())

                                    Button(role: .destructive) {
                                        isConfirmingBulkDelete = true
                                    } label: {
                                        Label("删除 \(selectedSessionIDs.count)", systemImage: "trash")
                                    }
                                    .buttonStyle(SoftButtonStyle(destructive: true))
                                }
                            }
                        }
                        ScrollView {
                            LazyVStack(spacing: 8) {
                                ForEach(store.sessions, id: \.id) { session in
                                    HStack(spacing: 8) {
                                        Button {
                                            toggleSelection(for: session)
                                        } label: {
                                            Image(systemName: selectedSessionIDs.contains(session.id) ? "checkmark.circle.fill" : "circle")
                                                .font(.system(size: 17, weight: .semibold))
                                                .foregroundStyle(selectedSessionIDs.contains(session.id) ? CandyTheme.syrup : .secondary)
                                                .frame(width: 22, height: 22)
                                        }
                                        .buttonStyle(.plain)

                                        Button {
                                            store.selectSession(session)
                                        } label: {
                                            SessionRow(
                                                session: session,
                                                isSelected: store.selectedSession?.id == session.id
                                            )
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 12)
                        }
                        .scrollContentBackground(.hidden)
                        .background(Color(nsColor: .controlBackgroundColor))
                    }
                    .frame(width: 310)
                    .background(Color(nsColor: .controlBackgroundColor))

                    Divider()

                    SessionDetailView(store: store)
                }
            }
        }
        .onChange(of: store.sessions.map(\.id)) { _, ids in
            selectedSessionIDs = selectedSessionIDs.intersection(Set(ids))
        }
        .alert("删除选中的充电记录？", isPresented: $isConfirmingBulkDelete) {
            Button("删除", role: .destructive) {
                store.deleteSessions(ids: selectedSessionIDs)
                selectedSessionIDs.removeAll()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会同时删除这些记录下的采样点，操作不可撤销。")
        }
    }

    private func toggleSelection(for session: ChargingSession) {
        if selectedSessionIDs.contains(session.id) {
            selectedSessionIDs.remove(session.id)
        } else {
            selectedSessionIDs.insert(session.id)
        }
    }
}

private struct SessionRow: View {
    let session: ChargingSession
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(session.displayTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                if session.endedAt == nil {
                    Text("记录中")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.green)
                }
            }
            Text(session.startedAt, format: .dateTime.month().day().hour().minute())
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(String(format: "峰值 %.1f W · 平均 %.1f W", session.peakPowerW, session.averagePowerW))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Color.secondary.opacity(0.16) : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct SessionDetailView: View {
    let store: MonitorStore
    @State private var renamingSession: ChargingSession?
    @State private var deletingSession: ChargingSession?

    var body: some View {
        VStack(spacing: 0) {
            if let session = store.selectedSession {
                HeaderBar(title: session.displayTitle, subtitle: sessionSubtitle(session)) {
                    Button {
                        renamingSession = session
                    } label: {
                        Label("重命名", systemImage: "pencil")
                    }
                    if session.endedAt == nil {
                        Button("结束记录") {
                            store.stopSession(session)
                        }
                    }
                    Button(role: .destructive) {
                        deletingSession = session
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                    Button {
                        store.exportSelectedSessionCSV()
                    } label: {
                        Label("导出 CSV", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderedProminent)
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack(spacing: 12) {
                            MetricCard(title: "峰值功率", value: String(format: "%.1f W", session.peakPowerW), icon: "bolt.fill")
                            MetricCard(title: "平均功率", value: String(format: "%.1f W", session.averagePowerW), icon: "waveform.path")
                            MetricCard(title: "实时功率", value: String(format: "%.1f W", latestPowerW), icon: "gauge.medium")
                            MetricCard(title: "耗时", value: durationText(session), icon: "clock")
                        }

                        SessionPowerChart(samples: store.selectedSessionSamples)
                    }
                    .padding(24)
                }
            } else {
                ContentUnavailableView("暂无充电记录", systemImage: "chart.xyaxis.line", description: Text("连接设备并开始充电后，会自动生成完整曲线。"))
            }
        }
        .sheet(item: $renamingSession) { session in
            RenameSessionSheet(store: store, session: session)
        }
        .alert("删除充电记录？", isPresented: Binding(
            get: { deletingSession != nil },
            set: { if !$0 { deletingSession = nil } }
        )) {
            Button("删除", role: .destructive) {
                if let deletingSession {
                    store.deleteSession(deletingSession)
                }
                deletingSession = nil
            }
            Button("取消", role: .cancel) {
                deletingSession = nil
            }
        } message: {
            Text("会同时删除这条记录下的采样点，操作不可撤销。")
        }
    }

    private func sessionSubtitle(_ session: ChargingSession) -> String {
        if let endedAt = session.endedAt {
            return "\(session.startedAt.formatted(date: .abbreviated, time: .shortened)) - \(endedAt.formatted(date: .omitted, time: .shortened))"
        }
        return "正在记录"
    }

    private var latestPowerW: Double {
        store.selectedSessionSamples.last?.powerW ?? store.selectedSession?.averagePowerW ?? 0
    }

    private func durationText(_ session: ChargingSession) -> String {
        let seconds = Int((session.endedAt ?? Date()).timeIntervalSince(session.startedAt))
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }
}

private struct RenameSessionSheet: View {
    @Environment(\.dismiss) private var dismiss
    let store: MonitorStore
    let session: ChargingSession
    @State private var title: String

    init(store: MonitorStore, session: ChargingSession) {
        self.store = store
        self.session = session
        _title = State(initialValue: session.displayTitle)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("重命名充电记录")
                    .font(.title3.weight(.semibold))
                Text("\(session.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(session.portName)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            TextField("记录名称", text: $title)
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("取消") {
                    dismiss()
                }
                Button("保存") {
                    store.renameSession(session, title: title)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 420)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct SessionPowerChart: View {
    let samples: [PortSample]
    @State private var hoveredSample: PortSample?

    var body: some View {
        ZStack(alignment: .topLeading) {
            Chart(samples) { sample in
                LineMark(
                    x: .value("时间", sample.timestamp),
                    y: .value("功率", sample.powerW)
                )
                .foregroundStyle(CandyTheme.syrup)
                .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                .interpolationMethod(.linear)

                if hoveredSample?.id == sample.id {
                    RuleMark(x: .value("时间", sample.timestamp))
                        .foregroundStyle(CandyTheme.berry.opacity(0.45))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    PointMark(
                        x: .value("时间", sample.timestamp),
                        y: .value("功率", sample.powerW)
                    )
                    .foregroundStyle(CandyTheme.berry)
                    .symbolSize(90)
                }
            }
            .chartYAxisLabel("W")
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                updateHover(location: location, proxy: proxy, geometry: geometry)
                            case .ended:
                                hoveredSample = nil
                            }
                        }
                }
            }
            .frame(height: 300)

            if let hoveredSample {
                SessionReadout(sample: hoveredSample)
                    .padding(14)
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func updateHover(location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) {
        guard let plotAnchor = proxy.plotFrame else {
            hoveredSample = nil
            return
        }
        let plotFrame = geometry[plotAnchor]
        guard plotFrame.contains(location),
              let date: Date = proxy.value(atX: location.x - plotFrame.origin.x) else {
            hoveredSample = nil
            return
        }

        hoveredSample = samples.min {
            abs($0.timestamp.timeIntervalSince(date)) < abs($1.timestamp.timeIntervalSince(date))
        }
    }
}

private struct SessionReadout: View {
    let sample: PortSample

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(sample.portName)
                .font(.caption.weight(.semibold))
            Text(sample.timestamp, format: .dateTime.hour().minute().second())
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(String(format: "功率 %.2f W", sample.powerW))
                .font(.headline.monospacedDigit())
            Text("\(sample.voltageMV) mV / \(sample.currentMA) mA")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(CandyTheme.syrup.opacity(0.28), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.12), radius: 12, y: 6)
    }
}

private struct ControlConsoleView: View {
    let store: MonitorStore
    @State private var strategy: ChargingStrategy = .fast
    @State private var temperatureMode: TemperatureMode = .powerPriority
    @State private var allocations: [Double] = []
    @State private var cablePort = 1
    @State private var cableGear: CableCompensationGear = .low
    @State private var pending: PendingControl?

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar(title: "控制台", subtitle: store.selectedDevice?.name ?? "-") {
                HStack(spacing: 10) {
                    SyncStatusView(date: store.lastRefreshedAt, isRefreshing: store.isRefreshingNow)
                    Button {
                        Task { await store.refreshSelectedDeviceNow() }
                    } label: {
                        Label("刷新状态", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(SoftButtonStyle())
                    .disabled(store.isRefreshingNow)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack(alignment: .top, spacing: 16) {
                        strategyGroup
                        temperatureGroup
                    }
                    portPowerGroup
                    allocationGroup
                    cableGroup
                }
                .padding(24)
            }
        }
        .onAppear {
            resetAllocations()
            syncTemperatureModeFromStore()
            Task { await store.refreshSelectedDeviceNow() }
        }
        .onChange(of: store.livePorts) { _, _ in
            if allocations.count != store.livePorts.count {
                resetAllocations()
            }
        }
        .onChange(of: store.temperatureModeLabel) { _, _ in
            syncTemperatureModeFromStore()
        }
        .confirmationDialog("确认控制操作", isPresented: Binding(
            get: { pending != nil },
            set: { if !$0 { pending = nil } }
        )) {
            if let action = pending {
                Button(action.confirmTitle, role: action.role) {
                    Task { await perform(action) }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(pending?.message ?? "")
        }
    }

    private var strategyGroup: some View {
        controlGroup("充电策略", icon: "bolt.horizontal", subtitle: "影响整机输出偏好，适合在发热、速度、单口优先之间切换。") {
            Picker("策略", selection: $strategy) {
                ForEach(ChargingStrategy.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)

            Button {
                pending = .strategy(strategy)
            } label: {
                Label("应用策略", systemImage: "checkmark.circle")
            }
            .buttonStyle(SoftButtonStyle(prominent: true))
        }
    }

    private var temperatureGroup: some View {
        controlGroup("温控模式", icon: "thermometer.medium", subtitle: "当前：\(LocalizedTelemetry.temperatureModeLabel(store.temperatureModeLabel))。切换后会立即重新读取状态。") {
            Picker("温控", selection: $temperatureMode) {
                ForEach(TemperatureMode.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)

            Button {
                pending = .temperature(temperatureMode)
            } label: {
                Label("应用温控", systemImage: "checkmark.circle")
            }
            .buttonStyle(SoftButtonStyle(prominent: true))
        }
    }

    private var portPowerGroup: some View {
        controlGroup("端口开关", icon: "powerplug", subtitle: "只切换对应接口；操作前会确认，完成后自动刷新端口状态。") {
            VStack(spacing: 8) {
                ForEach(store.livePorts) { port in
                    HStack(spacing: 12) {
                        Text(port.port.displayName)
                            .font(.headline.monospaced())
                            .frame(width: 42, alignment: .leading)
                        if let portSwitchState = port.portSwitchState {
                            StatusPill(text: portSwitchState ? "已开启" : "已关闭", color: portSwitchState ? CandyTheme.mint : .secondary)
                        } else {
                            StatusPill(text: "开关未知", color: .secondary)
                        }
                        StatusPill(text: port.connected ? "已接入" : "空闲", color: port.connected ? CandyTheme.mint : .secondary)
                        Text(String(format: "%.1f W", port.powerW))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Spacer()
                        if let portSwitchState = port.portSwitchState {
                            HStack(spacing: 6) {
                                Button("开启") { pending = .port(port.port.index, true) }
                                    .buttonStyle(SoftButtonStyle())
                                    .disabled(portSwitchState == true)
                                Button("关闭", role: .destructive) { pending = .port(port.port.index, false) }
                                    .buttonStyle(SoftButtonStyle(destructive: true))
                                    .disabled(portSwitchState == false)
                            }
                        } else {
                            Text("无法控制")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
        }
    }

    private var allocationGroup: some View {
        controlGroup("功率分配", icon: "slider.horizontal.below.rectangle", subtitle: "调整各接口功率上限。滑条值来自设备当前端口能力，应用后会自动刷新实时数据。") {
            powerAllocationControls
            Button {
                pending = .allocation(allocations.map { Int($0.rounded()) })
            } label: {
                Label("应用功率分配", systemImage: "checkmark.circle")
            }
            .buttonStyle(SoftButtonStyle(prominent: true))
        }
    }

    private var cableGroup: some View {
        controlGroup("线补档位", icon: "cable.connector", subtitle: "补偿线材压降。只显示低、中、高、高性能四档，不暴露底层电阻参数。") {
            HStack(spacing: 14) {
                Picker("端口", selection: $cablePort) {
                    ForEach(store.livePorts) { port in
                        Text(port.port.displayName).tag(port.port.index)
                    }
                }
                .frame(width: 160)

                Picker("档位", selection: $cableGear) {
                    ForEach(CableCompensationGear.visibleCases) { gear in
                        Text(gear.title).tag(gear)
                    }
                }
                .frame(width: 180)

                Button {
                    pending = .cable(cablePort, cableGear)
                } label: {
                    Label("应用线补", systemImage: "checkmark.circle")
                }
                .buttonStyle(SoftButtonStyle(prominent: true))
            }
        }
    }

    private var powerAllocationControls: some View {
        VStack(spacing: 10) {
            ForEach(Array(store.livePorts.enumerated()), id: \.element.id) { index, port in
                HStack {
                    Text(port.port.displayName)
                        .font(.headline.monospaced())
                        .frame(width: 42, alignment: .leading)
                    Slider(
                        value: Binding(
                            get: { allocations.indices.contains(index) ? allocations[index] : Double(port.port.power) },
                            set: { value in
                                if allocations.indices.contains(index) {
                                    allocations[index] = value
                                }
                            }
                        ),
                        in: 0...Double(max(port.port.power, 1)),
                        step: 1
                    )
                    Text("\(Int((allocations.indices.contains(index) ? allocations[index] : 0).rounded())) W")
                        .font(.body.monospacedDigit())
                        .frame(width: 58, alignment: .trailing)
                }
                .padding(.vertical, 2)
            }
        }
    }

    @ViewBuilder
    private func controlGroup<Content: View>(_ title: String, icon: String, subtitle: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 28, height: 28)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.primary.opacity(0.06), lineWidth: 1)
        }
    }

    private func resetAllocations() {
        allocations = store.livePorts.map { Double($0.port.power) }
        cablePort = store.livePorts.first?.port.index ?? 1
    }

    private func perform(_ action: PendingControl) async {
        switch action {
        case .strategy(let strategy):
            await store.applyStrategy(strategy)
        case .temperature(let mode):
            await store.applyTemperatureMode(mode)
        case .port(let port, let enabled):
            await store.setPort(port, enabled: enabled)
        case .allocation(let watts):
            await store.applyPowerAllocation(watts)
        case .cable(let port, let gear):
            await store.applyCableCompensation(port: port, gear: gear)
        }
    }

    private func syncTemperatureModeFromStore() {
        switch store.temperatureModeLabel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "temperature_priority", "temperature priority", "1":
            temperatureMode = .temperaturePriority
        default:
            temperatureMode = .powerPriority
        }
    }
}

private enum PendingControl: Identifiable {
    case strategy(ChargingStrategy)
    case temperature(TemperatureMode)
    case port(Int, Bool)
    case allocation([Int])
    case cable(Int, CableCompensationGear)

    var id: String {
        switch self {
        case .strategy(let value): "strategy-\(value.rawValue)"
        case .temperature(let value): "temperature-\(value.rawValue)"
        case .port(let port, let enabled): "port-\(port)-\(enabled)"
        case .allocation(let values): "allocation-\(values.map(String.init).joined(separator: "-"))"
        case .cable(let port, let gear): "cable-\(port)-\(gear.rawValue)"
        }
    }

    var confirmTitle: String {
        switch self {
        case .port(_, false): "确认关闭"
        default: "确认应用"
        }
    }

    var role: ButtonRole? {
        switch self {
        case .port(_, false): .destructive
        default: nil
        }
    }

    var message: String {
        switch self {
        case .strategy(let strategy): "将设备策略切换为 \(strategy.detail)。"
        case .temperature(let mode): "将温控模式切换为 \(mode.detail)。"
        case .port(let port, let enabled): "\(enabled ? "开启" : "关闭") \(LocalizedTelemetry.portName(port))。"
        case .allocation(let values): "应用功率分配：\(values.map(String.init).joined(separator: " / ")) W。"
        case .cable(let port, let gear): "将 \(LocalizedTelemetry.portName(port)) 线补设置为 \(gear.title)。"
        }
    }
}

private enum SettingsField: Hashable {
    case name
    case url
}

private struct SettingsView: View {
    let store: MonitorStore
    @State private var editingName = ""
    @State private var editingURL = ""
    @State private var isSaving = false
    @FocusState private var focusedField: SettingsField?

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar(title: "设置", subtitle: "设备、连接与数据") {
                HStack(spacing: 10) {
                    SyncStatusView(date: store.lastRefreshedAt, isRefreshing: store.isRefreshingNow)
                    Button {
                        Task { await store.refreshSelectedDeviceNow() }
                    } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(SoftButtonStyle())
                }
            }
            ScrollView {
                if let device = store.selectedDevice {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(alignment: .top, spacing: 16) {
                            SettingsCard(title: "设备身份", icon: "powerplug.portrait", subtitle: "这里决定侧栏里看到的名字；保存时会重新连接 MCP 并读取机器信息。") {
                                LabeledContent("显示名称") {
                                    HStack(spacing: 8) {
                                        TextField("例如 Shawn’s Mirror", text: $editingName)
                                            .textFieldStyle(.roundedBorder)
                                            .frame(maxWidth: 360)
                                            .focused($focusedField, equals: .name)
                                            .onSubmit {
                                                commitName(device)
                                            }
                                        Button("保存") {
                                            commitName(device)
                                        }
                                        .buttonStyle(SoftButtonStyle(prominent: editingName.trimmingCharacters(in: .whitespacesAndNewlines) != device.name))
                                    }
                                }
                                LabeledContent("产品序列") {
                                    Text(device.psn ?? "尚未读取")
                                        .foregroundStyle(.secondary)
                                }
                                LabeledContent("机型") {
                                    Text(device.model ?? device.productFamily ?? "Mirror")
                                        .foregroundStyle(.secondary)
                                }
                            }

                            SettingsCard(title: "MCP 连接", icon: "network", subtitle: "CandyMonitor 通过这个 SSE 地址连接小电拼；地址会加密保存在本机应用目录，不再触发钥匙串授权。") {
                                TextField("https://.../sse", text: $editingURL)
                                    .textFieldStyle(.roundedBorder)
                                HStack {
                                    Button {
                                        Task { await save(device) }
                                    } label: {
                                        Label(isSaving ? "校验中" : "保存并校验", systemImage: "checkmark.shield")
                                    }
                                    .buttonStyle(SoftButtonStyle(prominent: true))
                                    .disabled(isSaving || editingURL.isEmpty)

                                    Button {
                                        Task { await store.refreshSelectedDeviceNow() }
                                    } label: {
                                        Label("读取状态", systemImage: "arrow.clockwise")
                                    }
                                    .buttonStyle(SoftButtonStyle())
                                }
                            }
                        }

                        HStack(alignment: .top, spacing: 16) {
                            SettingsCard(title: "记录行为", icon: "record.circle", subtitle: "接入负载并开始输出功率时自动生成会话；拔掉、满电或手动停止后关闭会话。") {
                                LabeledContent("实时采样") {
                                    Text("前台 1 秒")
                                        .foregroundStyle(.secondary)
                                }
                                LabeledContent("后台记录") {
                                    Text("30 秒")
                                        .foregroundStyle(.secondary)
                                }
                                LabeledContent("当前记录") {
                                    Text("\(store.activeChargingSessions.count) 条")
                                        .foregroundStyle(.secondary)
                                }
                            }

                            SettingsCard(title: "本地数据", icon: "externaldrive", subtitle: "充电会话、采样点和控制日志保存在本机 SwiftData；CSV 从完整采样导出。") {
                                LabeledContent("历史会话") {
                                    Text("\(store.sessions.count) 条")
                                        .foregroundStyle(.secondary)
                                }
                                LabeledContent("最大功率预算") {
                                    Text(device.maxPowerBudget > 0 ? "\(device.maxPowerBudget) W" : "尚未读取")
                                        .foregroundStyle(.secondary)
                                }
                                Button(role: .destructive) {
                                    store.deleteSelectedDevice()
                                } label: {
                                    Label("删除这台设备及本地记录", systemImage: "trash")
                                }
                                .buttonStyle(SoftButtonStyle(destructive: true))
                            }
                        }
                    }
                    .padding(24)
                }
            }
        }
        .onAppear(perform: load)
        .onChange(of: store.selectedDeviceID) { _, _ in load() }
        .onChange(of: focusedField) { oldValue, newValue in
            guard oldValue == .name, newValue != .name, let device = store.selectedDevice else { return }
            commitName(device)
        }
    }

    private func load() {
        guard let device = store.selectedDevice else { return }
        editingName = device.name
        editingURL = store.mcpURL(for: device)
    }

    private func save(_ device: MirrorDevice) async {
        isSaving = true
        defer { isSaving = false }
        try? await store.updateDevice(device, name: editingName, sseURLString: editingURL)
    }

    private func commitName(_ device: MirrorDevice) {
        store.renameDevice(device, name: editingName)
        editingName = store.selectedDevice?.name ?? editingName
    }
}

private struct AddDeviceSheet: View {
    @Environment(\.dismiss) private var dismiss
    let store: MonitorStore
    @State private var name = ""
    @State private var sseURL = ""
    @State private var errorText: String?
    @State private var isSaving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("添加小电拼")
                    .font(.title2.weight(.semibold))
                Text("填写设备昵称和 MCP SSE 地址。CandyMonitor 会先握手校验，成功后再保存。")
                    .foregroundStyle(.secondary)
            }

            TextField("设备名称，例如 Shawn’s Mirror", text: $name)
                .textFieldStyle(.roundedBorder)
            TextField("https://.../sse", text: $sseURL)
                .textFieldStyle(.roundedBorder)

            if let errorText {
                Text(errorText)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("取消") {
                    dismiss()
                }
                Button(isSaving ? "校验中" : "添加") {
                    Task { await add() }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(isSaving || sseURL.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 520)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func add() async {
        isSaving = true
        errorText = nil
        do {
            try await store.addDevice(name: name, sseURLString: sseURL)
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
        isSaving = false
    }
}

private struct HeaderBar<Trailing: View>: View {
    let title: String
    let subtitle: String
    let trailing: () -> Trailing

    init(title: String, subtitle: String, @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.title3.weight(.semibold))
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            trailing()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(.bar)
    }
}

private struct SyncStatusView: View {
    let date: Date?
    let isRefreshing: Bool

    var body: some View {
        HStack(spacing: 6) {
            if isRefreshing {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Circle()
                    .fill(CandyTheme.mint)
                    .frame(width: 7, height: 7)
            }
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(.secondary.opacity(0.08), in: Capsule())
    }

    private var text: String {
        if isRefreshing { return "读取中" }
        guard let date else { return "等待同步" }
        return "同步 \(date.formatted(date: .omitted, time: .standard))"
    }
}

private struct StatusPill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(color.opacity(0.12), in: Capsule())
    }
}

private struct SettingsCard<Content: View>: View {
    let title: String
    let icon: String
    let subtitle: String
    let content: () -> Content

    init(title: String, icon: String, subtitle: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.icon = icon
        self.subtitle = subtitle
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 28, height: 28)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.primary.opacity(0.06), lineWidth: 1)
        }
    }
}

private struct SoftButtonStyle: ButtonStyle {
    var prominent = false
    var destructive = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.medium))
            .padding(.horizontal, 12)
            .frame(height: 30)
            .foregroundStyle(foreground)
            .background(background, in: Capsule())
            .overlay {
                Capsule()
                    .stroke(.primary.opacity(prominent ? 0 : 0.08), lineWidth: 1)
            }
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.interactiveSpring(response: 0.22, dampingFraction: 0.8), value: configuration.isPressed)
    }

    private var foreground: Color {
        if prominent { return .white }
        if destructive { return .red }
        return .primary
    }

    private var background: Color {
        if prominent { return Color.accentColor }
        if destructive { return Color.red.opacity(0.12) }
        return Color.secondary.opacity(0.10)
    }
}

private struct PressedButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.interactiveSpring(response: 0.22, dampingFraction: 0.8), value: configuration.isPressed)
    }
}

private struct MetricCard: View {
    let title: String
    let value: String
    let icon: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(Color.accentColor)
                .frame(width: 26, height: 26)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.headline.monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            Spacer()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [MirrorDevice.self, ChargingSession.self, PortSample.self, ControlEvent.self], inMemory: true)
}
