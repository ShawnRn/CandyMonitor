import Charts
import AppKit
import SwiftData
import SwiftUI
import ServiceManagement
import Sparkle

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    let store: MonitorStore

    var body: some View {
        NavigationSplitView {
            CandySidebar(store: store)
                .navigationSplitViewColumnWidth(min: 230, ideal: 250, max: 300)
        } detail: {
            detail
                .frame(minWidth: 760, minHeight: 540)
                .background(Color(nsColor: .windowBackgroundColor))
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    store.isShowingAddDevice = true
                } label: {
                    Label("添加设备", systemImage: "plus")
                }
                .id("add-device-toolbar-btn")
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
                Image("CandyMenuBarIconWhite")
                    .resizable()
                    .interpolation(.high)
                    .antialiased(true)
                    .scaledToFit()
                    .frame(width: 30, height: 30)
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
    @State private var portFilterAnchor: Int?
    @State private var detailPort: PortViewState?

    private var effectivePortIDs: Set<Int> {
        selectedPortIDs.isEmpty ? Set(store.livePorts.map(\.port.index)) : selectedPortIDs
    }

    private var filteredSamples: [ChartSamplePoint] {
        store.recentSamples
            .filter { effectivePortIDs.contains($0.portIndex) }
    }

    @State private var plottedSamplesCache: [ChartSamplePoint] = []
    @State private var lineSamplesCache: [ChartLinePoint] = []

    private func updateChartCache(with samples: [ChartSamplePoint], metric: ChartMetric) {
        let plotted = downsampleChartSamples(samples, metric: metric)
        self.plottedSamplesCache = plotted
        self.lineSamplesCache = segmentedChartPoints(from: plotted)
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
                        productFamily: store.selectedDevice?.productFamily,
                        connectionState: store.connectionState,
                        lastRefreshedAt: store.lastRefreshedAt,
                        temperatureMode: LocalizedTelemetry.temperatureModeLabel(store.temperatureModeLabel),
                        activeSessions: store.activeChargingSessions.count,
                        totalPowerW: store.totalPowerW
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
        .onChange(of: store.recentSamples, initial: true) { _, _ in
            updateChartCache(with: filteredSamples, metric: metric)
        }
        .onChange(of: selectedPortIDs) { _, _ in
            updateChartCache(with: filteredSamples, metric: metric)
        }
        .onChange(of: metric) { _, newMetric in
            updateChartCache(with: filteredSamples, metric: newMetric)
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
            togglePort: selectPortFilter,
            productFamily: store.selectedDevice?.productFamily,
            maxPowerBudget: store.selectedDevice?.maxPowerBudget ?? 0
        )
    }

    private var dashboardHeight: CGFloat { 408 }

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

            LiveMonitorChartView(
                lineSamplesCache: lineSamplesCache,
                plottedSamplesCache: plottedSamplesCache,
                metric: metric
            )
            .padding(14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(CandyTheme.separator, lineWidth: 1)
            }

            if plottedSamplesCache.isEmpty {
                Text("暂无采样。连接负载后会自动开始记录完整充电曲线。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func recordingPanel(fillsHeight: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label("全程充电记录", systemImage: "waveform.path.ecg")
                    .font(.headline)
                Spacer()
                if !store.activeChargingSessions.isEmpty {
                    RecordingIndicator()
                } else {
                    IdleIndicator()
                }
            }

            if store.activeChargingSessions.isEmpty == false {
                let sessionsList = VStack(alignment: .leading, spacing: 6) {
                    ForEach(store.activeChargingSessions) { session in
                        HStack(alignment: .center, spacing: 8) {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    // 端口标识
                                    Text(session.portName)
                                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1.5)
                                        .background(CandyTheme.syrup, in: RoundedRectangle(cornerRadius: 3.5, style: .continuous))
                                    
                                    Text(session.displayTitle)
                                        .font(.system(size: 12, weight: .semibold))
                                        .lineLimit(1)
                                }
                                
                                // 数据遥测
                                HStack(spacing: 4) {
                                    Text("已采 \(session.sampleCount) 点")
                                    Text("•")
                                        .foregroundStyle(.tertiary)
                                    Text("已录 \(Int(Date().timeIntervalSince(session.startedAt) / 60)) 分钟")
                                }
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                            }
                            
                            Spacer(minLength: 4)
                            
                            // 操作按钮 (Icon Only)
                            HStack(spacing: 5) {
                                Button {
                                    store.selectSession(session)
                                    store.selectedSection = .sessions
                                } label: {
                                    Image(systemName: "chart.xyaxis.line")
                                        .font(.system(size: 11, weight: .medium))
                                }
                                .buttonStyle(CandyModernMiniButtonStyle(isIconOnly: true))
                                .help("查看曲线")
                                
                                SessionExportMenu(store: store, session: session, compact: true, style: .mini, iconOnly: true)
                                    .help("导出")
                            }
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 10)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                        }
                    }
                }
                
                if fillsHeight {
                    ScrollView(.vertical, showsIndicators: true) {
                        sessionsList
                            .padding(.trailing, 2)
                    }
                } else {
                    sessionsList
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text(recordingText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 2)
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
        let active = store.activeChargingSessions
        if active.count == 1, let session = active.first {
            let minutes = Int(Date().timeIntervalSince(session.startedAt) / 60)
            return "\(session.portName) 正在记录全程曲线，已采 \(session.sampleCount) 个点，持续 \(minutes) 分钟。"
        }
        if active.isEmpty == false {
            let totalSamples = active.reduce(0) { $0 + $1.sampleCount }
            let ports = active.map(\.portName).joined(separator: "、")
            return "\(ports) 正在分别记录全程曲线，合计已采 \(totalSamples) 个点。"
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
                    selectPortFilter(port.port.index)
                }
            }
        }
    }

    private func selectPortFilter(_ port: Int) {
        let modifiers = NSEvent.modifierFlags
        let availablePorts = store.livePorts.map(\.port.index)

        if modifiers.contains(.shift),
           let anchor = portFilterAnchor ?? selectedPortIDs.sorted().first,
           let anchorIndex = availablePorts.firstIndex(of: anchor),
           let currentIndex = availablePorts.firstIndex(of: port) {
            let range = anchorIndex <= currentIndex ? anchorIndex...currentIndex : currentIndex...anchorIndex
            let rangeSelection = Set(range.map { availablePorts[$0] })
            if modifiers.contains(.command) {
                selectedPortIDs.formUnion(rangeSelection)
            } else {
                selectedPortIDs = rangeSelection
            }
        } else if modifiers.contains(.command) {
            if selectedPortIDs.contains(port) {
                selectedPortIDs.remove(port)
            } else {
                selectedPortIDs.insert(port)
            }
        } else {
            selectedPortIDs = [port]
        }

        portFilterAnchor = port
    }

}

private struct MirrorDeviceHero: View {
    let deviceName: String
    let productFamily: String?
    let connectionState: ConnectionState
    let lastRefreshedAt: Date?
    let temperatureMode: String
    let activeSessions: Int
    let totalPowerW: Double

    private var displayFamilyName: String {
        let family = CandyProductFamily(productFamily)
        if family.is02S {
            return "02S"
        } else if family.isUltra {
            return "Ultra"
        } else {
            return "Mirror"
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text("CoCan")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                    Text(displayFamilyName)
                        .font(.system(size: 15, weight: .semibold, design: .rounded).italic())
                        .foregroundStyle(CandyTheme.syrup)
                }

                HStack(alignment: .center, spacing: 8) {
                    Text(deviceName)
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .lineLimit(1)
                    RotatingPowerBadge(powerW: totalPowerW)
                        .frame(width: 24, height: 24)
                        .offset(y: 1)
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
    let productFamily: String?
    let maxPowerBudget: Int

    private var maxPowerW: Double {
        let budget = Double(maxPowerBudget)
        return budget > 0 ? budget : 160.0
    }

    private var activeMaxPowerW: Double {
        ports
            .filter { $0.connected && $0.powerW > 0.5 }
            .map(\.powerW)
            .max() ?? 0
    }

    private var portsConfigLabel: String {
        let typeC = ports.filter { !$0.port.connectorType.lowercased().contains("a") }.count
        let usbA = ports.filter { $0.port.connectorType.lowercased().contains("a") }.count
        if typeC > 0 && usbA > 0 {
            return "\(typeC)C \(usbA)A"
        } else if typeC > 0 {
            return "\(typeC)C"
        } else if usbA > 0 {
            return "\(usbA)A"
        } else {
            return "\(ports.count)P"
        }
    }

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

            if ports.isEmpty {
                Spacer()
                HStack {
                    Spacer()
                    VStack(spacing: 16) {
                        ProgressView()
                            .controlSize(.regular)
                        Text("正在获取端口拓扑...")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                Spacer()
            } else {
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
                                .stroke(cableStrokeColor(for: port), style: cableStrokeStyle(for: port))
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
                        MirrorChargerIllustration(productFamily: productFamily)
                            .frame(width: MirrorTopologyLayout.chargerWidth, height: MirrorTopologyLayout.chargerHeight)
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, MirrorTopologyLayout.chargerBottomPadding)
                }
                .frame(height: 204)
            }
        }
        .padding(14)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(CandyTheme.separator, lineWidth: 1)
        }
    }

    private var capacityBadge: some View {
        HStack(spacing: 6) {
            Text(portsConfigLabel)
                .font(.caption.weight(.bold))
            Text("\(Int(maxPowerW))W")
                .font(.callout.weight(.bold).monospacedDigit())
            Text("\(Int(min(totalPowerW / maxPowerW, 1) * 100))%")
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

    private func cableStrokeColor(for port: PortViewState) -> Color {
        CandyTheme.syrup
    }

    private func cableStrokeStyle(for port: PortViewState) -> StrokeStyle {
        guard port.connected && port.powerW > 0.5 else {
            return StrokeStyle(lineWidth: 1.45, lineCap: .round, dash: [2.4, 6.2])
        }
        let ratio = min(max(port.powerW / max(activeMaxPowerW, 1), 0), 1)
        let width = 2.8 + pow(ratio, 0.82) * 3.8
        return StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
    }
}

private struct RotatingPowerBadge: View, Equatable {
    let powerW: Double
    @State private var referenceDate = Date()
    @State private var phaseAtReference = 0.0
    @State private var speedAtReference = 0.0

    static func == (lhs: RotatingPowerBadge, rhs: RotatingPowerBadge) -> Bool {
        lhs.powerW == rhs.powerW
    }

    private var isActive: Bool { powerW > 0.5 }

    private var targetDegreesPerSecond: Double {
        guard isActive else { return 0 }
        let normalized = min(max(powerW / 140.0, 0), 1)
        return 28 + normalized * 132
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isActive)) { timeline in
            Image(systemName: "seal.fill")
                .font(.system(size: 18, weight: .semibold))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(CandyTheme.syrup)
                .frame(width: 24, height: 24, alignment: .center)
                .rotationEffect(.degrees(phase(at: timeline.date)))
                .accessibilityHidden(true)
        }
        .onAppear {
            speedAtReference = targetDegreesPerSecond
        }
        .onChange(of: powerW) { _, _ in
            let now = Date()
            phaseAtReference = phase(at: now).truncatingRemainder(dividingBy: 360)
            referenceDate = now
            speedAtReference = targetDegreesPerSecond
        }
    }

    private func phase(at date: Date) -> Double {
        phaseAtReference + date.timeIntervalSince(referenceDate) * speedAtReference
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
    let productFamily: String?
    
    var body: some View {
        Image(assetName)
            .resizable()
            .scaledToFit()
            .shadow(color: .black.opacity(0.18), radius: 10, y: 5)
            .accessibilityLabel("小电拼 \(displayName) 图示")
    }
    
    private var assetName: String {
        let family = CandyProductFamily(productFamily)
        if family.is02S {
            return "Mirror02sDevice"
        } else if family.isUltra {
            return "Ultra02Device"
        } else {
            return "Mirror4C1ADevice"
        }
    }
    
    private var displayName: String {
        let family = CandyProductFamily(productFamily)
        if family.is02S {
            return "02S"
        } else if family.isUltra {
            return "02 Ultra"
        } else {
            return "4C1A"
        }
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

private struct ChartLinePoint: Identifiable, Equatable {
    let id: String
    let sample: ChartSamplePoint
    let seriesID: String
}



private func downsampleChartSamples(
    _ samples: [ChartSamplePoint],
    metric: ChartMetric,
    maxSamplesPerPort: Int = 120
) -> [ChartSamplePoint] {
    let grouped = Dictionary(grouping: samples) { $0.portIndex }
    var result: [ChartSamplePoint] = []

    for portIndex in grouped.keys.sorted() {
        let portSamples = grouped[portIndex] ?? []
        guard portSamples.count > maxSamplesPerPort else {
            result.append(contentsOf: portSamples)
            continue
        }

        let bucketSize = Int(ceil(Double(portSamples.count) / Double(maxSamplesPerPort)))
        var reduced: [ChartSamplePoint] = []
        reduced.reserveCapacity(maxSamplesPerPort * 3)

        for bucketStart in stride(from: 0, to: portSamples.count, by: bucketSize) {
            let bucketEnd = min(bucketStart + bucketSize, portSamples.count)
            let slice = portSamples[bucketStart..<bucketEnd]

            guard let first = slice.first else { continue }

            var extreme = first
            var extremeVal = metric.displayValue(first)
            for item in slice {
                let val = metric.displayValue(item)
                if val > extremeVal {
                    extremeVal = val
                    extreme = item
                }
            }

            let last = slice.last ?? first

            reduced.append(first)

            if extreme.id != first.id && extreme.id != last.id {
                reduced.append(extreme)
            }

            if last.id != first.id && last.id != extreme.id {
                reduced.append(last)
            }
        }
        result.append(contentsOf: reduced)
    }
    return result
}

private func segmentedChartPoints(from samples: [ChartSamplePoint]) -> [ChartLinePoint] {
    let grouped = Dictionary(grouping: samples) { $0.portIndex }
    var points: [ChartLinePoint] = []

    for portIndex in grouped.keys.sorted() {
        let portSamples = grouped[portIndex] ?? []
        var segment = 0
        var previous: ChartSamplePoint?

        for sample in portSamples {
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

private func nearestSamplesByPort(to date: Date, in samples: [ChartSamplePoint]) -> [ChartSamplePoint] {
    let grouped = Dictionary(grouping: samples) { $0.portIndex }
    let tolerance: TimeInterval = 10

    return grouped.keys.sorted().compactMap { portIndex in
        let nearest = grouped[portIndex]?.min {
            abs($0.timestamp.timeIntervalSince(date)) < abs($1.timestamp.timeIntervalSince(date))
        }
        guard let nearest,
              abs(nearest.timestamp.timeIntervalSince(date)) <= tolerance else {
            return nil
        }
        return nearest
    }
}

private struct StaticSessionChart: View, Equatable {
    let plottedSamples: [PortSample]

    static func == (lhs: StaticSessionChart, rhs: StaticSessionChart) -> Bool {
        lhs.plottedSamples.count == rhs.plottedSamples.count &&
        lhs.plottedSamples.last?.id == rhs.plottedSamples.last?.id
    }

    var body: some View {
        Chart(plottedSamples) { sample in
            LineMark(
                x: .value("时间", sample.timestamp),
                y: .value("功率", sample.powerW)
            )
            .foregroundStyle(CandyTheme.syrup)
            .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
            .interpolationMethod(.linear)
        }
        .chartYAxisLabel("W")
    }
}

private struct StaticLiveChart: View, Equatable {
    let lineSamplesCache: [ChartLinePoint]
    let metric: ChartMetric
    let plottedSamplesCache: [ChartSamplePoint]

    static func == (lhs: StaticLiveChart, rhs: StaticLiveChart) -> Bool {
        lhs.metric == rhs.metric &&
        lhs.lineSamplesCache.count == rhs.lineSamplesCache.count &&
        lhs.lineSamplesCache.last?.id == rhs.lineSamplesCache.last?.id &&
        lhs.metric.displayDomain(for: lhs.plottedSamplesCache) == rhs.metric.displayDomain(for: rhs.plottedSamplesCache)
    }

    var body: some View {
        Chart {
            ForEach(lineSamplesCache) { point in
                LineMark(
                    x: .value("Time", point.sample.timestamp),
                    y: .value(metric.title, metric.displayValue(point.sample)),
                    series: .value("Segment", point.seriesID)
                )
                .foregroundStyle(by: .value("Port", point.sample.portName))
                .lineStyle(StrokeStyle(lineWidth: 3.2, lineCap: .round, lineJoin: .round))
                .interpolationMethod(.catmullRom)
            }
        }
        .chartYAxisLabel(metric.axisLabel)
        .chartYScale(domain: metric.displayDomain(for: plottedSamplesCache))
    }
}

private struct LiveMonitorChartView: View {
    let lineSamplesCache: [ChartLinePoint]
    let plottedSamplesCache: [ChartSamplePoint]
    let metric: ChartMetric

    @State private var hoveredLiveSamples: [ChartSamplePoint] = []
    @State private var hoverX: CGFloat?
    @State private var hoverPoints: [CGPoint] = []
    @State private var hoverLocation: CGPoint?

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                StaticLiveChart(
                    lineSamplesCache: lineSamplesCache,
                    metric: metric,
                    plottedSamplesCache: plottedSamplesCache
                )
                .equatable()
                .frame(height: 220)
                .chartOverlay { proxy in
                    Color.clear
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                self.hoverLocation = location
                                updateHover(location: location, proxy: proxy, geometry: geometry)
                            case .ended:
                                hoveredLiveSamples = []
                                hoverX = nil
                                hoverPoints = []
                                self.hoverLocation = nil
                            }
                        }
                        .onChange(of: lineSamplesCache) { _, _ in
                            if let hoverLocation {
                                updateHover(location: hoverLocation, proxy: proxy, geometry: geometry)
                            }
                        }
                }

                if let hoverX {
                    Path { path in
                        path.move(to: CGPoint(x: hoverX, y: 0))
                        path.addLine(to: CGPoint(x: hoverX, y: 200))
                    }
                    .stroke(CandyTheme.syrup.opacity(0.42), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .allowsHitTesting(false)

                    ForEach(Array(hoverPoints.enumerated()), id: \.offset) { _, pt in
                        Circle()
                            .fill(CandyTheme.syrup)
                            .frame(width: 8, height: 8)
                            .overlay {
                                Circle()
                                    .stroke(Color.white, lineWidth: 1.5)
                            }
                            .shadow(radius: 1)
                            .position(pt)
                            .allowsHitTesting(false)
                    }
                }

                if hoveredLiveSamples.isEmpty == false {
                    ChartReadout(samples: hoveredLiveSamples, metric: metric)
                        .padding(14)
                }
            }
        }
        .frame(height: 220)
    }

    private func updateHover(location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) {
        guard let plotAnchor = proxy.plotFrame else {
            hoveredLiveSamples = []
            hoverX = nil
            hoverPoints = []
            return
        }
        let plotFrame = geometry[plotAnchor]
        guard plotFrame.contains(location),
              let date: Date = proxy.value(atX: location.x - plotFrame.origin.x) else {
            hoveredLiveSamples = []
            hoverX = nil
            hoverPoints = []
            return
        }

        let nearest = nearestSamplesByPort(to: date, in: plottedSamplesCache)
        hoveredLiveSamples = nearest

        if let firstSample = nearest.first,
           let firstX = proxy.position(forX: firstSample.timestamp) {
            self.hoverX = firstX + plotFrame.origin.x
            
            var points: [CGPoint] = []
            for sample in nearest {
                if let xPos = proxy.position(forX: sample.timestamp),
                   let yPos = proxy.position(forY: metric.displayValue(sample)) {
                    points.append(CGPoint(x: xPos + plotFrame.origin.x, y: yPos + plotFrame.origin.y))
                }
            }
            self.hoverPoints = points
        } else {
            self.hoverX = nil
            self.hoverPoints = []
        }
    }
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
    let samples: [ChartSamplePoint]
    let metric: ChartMetric

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(samples.first?.timestamp ?? Date(), format: .dateTime.hour().minute().second())
                .font(.caption2)
                .foregroundStyle(.secondary)
            ForEach(samples) { sample in
                HStack(spacing: 10) {
                    Text(sample.portName)
                        .font(.caption.weight(.semibold))
                        .frame(width: 30, alignment: .leading)
                    Text(metric.formattedValue(sample))
                        .font(.headline.monospacedDigit())
                }
            }
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
    static let menuCardBackground = adaptive(
        light: NSColor(calibratedWhite: 0.96, alpha: 0.96),
        dark: NSColor(calibratedWhite: 0.15, alpha: 0.96)
    )
    static let menuRowBackground = adaptive(
        light: NSColor(calibratedWhite: 0.92, alpha: 0.92),
        dark: NSColor(calibratedWhite: 0.11, alpha: 0.92)
    )
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

private struct CandyProductFamily {
    private let normalized: String

    init(_ value: String?) {
        normalized = (value ?? "").uppercased()
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: " ", with: "")
    }

    var is02S: Bool {
        normalized.contains("CP02S") || normalized.contains("02S")
    }

    var isUltra: Bool {
        normalized.contains("CP02") || normalized.contains("ULTRA")
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

                    if port.connected && hasPDDeviceInfo {
                        sectionHeader("\(portTitle) 在充设备")

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
                                if deviceBrand != "-" {
                                    PortDetailMetric(title: "品牌", value: deviceBrand)
                                }
                                if deviceModel != "-" && deviceModel != "未知设备型号" && deviceModel != "澎湃秒充" {
                                    PortDetailMetric(title: "型号", value: deviceModel)
                                }
                                if batteryCapacityText != "-" && !batteryCapacityText.contains("500") {
                                    PortDetailMetric(title: "电池设计容量", value: batteryCapacityText)
                                }
                                if batteryLastFullCapacityText != "-" && !batteryLastFullCapacityText.contains("500") {
                                    PortDetailMetric(title: "当前最大容量", value: batteryLastFullCapacityText)
                                }
                                if batteryHealthText != "-" {
                                    PortDetailMetric(title: "健康度", value: batteryHealthText)
                                }
                                if batteryPercentText != "-" {
                                    PortDetailMetric(title: "当前电量", value: batteryPercentText)
                                }
                                if estimatedFullText != "-" {
                                    PortDetailMetric(title: "预计充满时间", value: estimatedFullText)
                                }
                            }
                        }

                        Text("仅支持 PD 协议，且部分设备厂商信息不准，仅供参考")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

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
            await store.refreshPortStats(port: port.port.index)
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
        if let model = port.pdStatus?.modelName, model.isEmpty == false {
            return model
        }
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
        if hasPDDeviceInfo {
            return "已读取到标准 PD 设备与电池信息，电量和满电判断会优先使用这些数据。"
        }
        if port.connected {
            return "设备已接入，但当前 MCP 响应没有返回更多 PD 设备信息。"
        }
        return "当前端口没有检测到负载，接入设备后会自动刷新这里的信息。"
    }

    private var portStats: [String: String] {
        store.portStatsByPort[port.port.index] ?? [:]
    }

    private var hasPDDeviceInfo: Bool {
        let count = [
            deviceBrand != "-" ? 1 : 0,
            (deviceModel != "-" && deviceModel != "未知设备型号" && deviceModel != "澎湃秒充") ? 1 : 0,
            (batteryLastFullCapacityText != "-" && !batteryLastFullCapacityText.contains("500")) ? 1 : 0,
            batteryHealthText != "-" ? 1 : 0,
            batteryPercentText != "-" ? 1 : 0,
            estimatedFullText != "-" ? 1 : 0
        ].reduce(0, +)
        return count > 0
    }

    private var deviceBrand: String {
        if let manufacturer = port.pdStatus?.manufacturer, manufacturer.isEmpty == false {
            return manufacturer
        }
        if let stat = statValue(["manufacturer", "vendor", "brand", "device_manufacturer", "device_vendor"]) {
            return stat
        }
        if isAppleDevice {
            return "Apple"
        }
        if isXiaomiSurgeCharge {
            return "小米"
        }
        return "-"
    }

    private var deviceModel: String {
        port.pdStatus?.modelName ??
            statValue(["model", "model_name", "device_model", "product_name", "name"]) ??
            port.detail?.deviceNameZH ??
            port.detail?.deviceNameEN ??
            (isXiaomiSurgeCharge ? "澎湃秒充" : "-")
    }

    private var batteryCapacityText: String {
        formattedMWh(port.pdStatus?.batteryCapacityMWh) ??
            statValue(["batteryDesignCapacity", "battery_capacity_mwh", "capacity_mwh", "design_capacity_mwh"]) ??
            "-"
    }

    private var batteryLastFullCapacityText: String {
        formattedMWh(port.pdStatus?.batteryLastFullChargeCapacityMWh) ??
            statValue(["batteryLastFullChargeCapacity", "lastFullChargeCapacity", "full_charge_capacity_mwh", "current_max_capacity_mwh"]) ??
            "-"
    }

    private var batteryHealthText: String {
        formattedBatteryHealth(port.pdStatus?.batteryHealthPercent) ??
            statValue(["battery_health_percent", "battery_health", "health_percent", "health", "soh"]) ??
            "-"
    }

    private var batteryPercentText: String {
        formattedPresentCapacity() ??
            formattedPercent(port.batteryPercent) ??
            statValue(["capacityPercent", "battery_percent", "battery_level", "battery_soc", "soc", "state_of_charge"]) ??
            "-"
    }

    private var estimatedFullText: String {
        port.pdStatus?.remainingTimeText ??
            statValue(["remainingTimeStr", "remaining_time_str", "timeToFullText"]) ??
            formattedMinutes(port.pdStatus?.estimatedFullMinutes) ??
            statValue(["estimated_full_minutes", "time_to_full_minutes", "minutes_to_full", "remaining_charge_minutes"]) ??
            "-"
    }

    private var isAppleDevice: Bool {
        let text = [port.pdStatus?.manufacturer, port.pdStatus?.modelName, port.detail?.deviceNameZH, port.detail?.deviceNameEN, portStats.values.joined(separator: " ")]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
        return text.contains("apple") ||
            text.contains("iphone") ||
            text.contains("ipad") ||
            text.contains("macbook") ||
            text.contains("airpods")
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
        if let cycleCount = port.pdStatus?.cycleCount {
            items.append("循环 \(cycleCount) 次")
        }
        if port.detail?.sessionChargeMWh ?? 0 > 0 {
            items.append(String(format: "本次 %.2f Wh", Double(port.detail?.sessionChargeMWh ?? 0) / 1000))
        }
        return items
    }

    private func statValue(_ candidateKeys: [String]) -> String? {
        let normalizedCandidates = candidateKeys.map(normalizedStatKey)
        for (key, value) in portStats {
            let normalizedKey = normalizedStatKey(key)
            if normalizedCandidates.contains(where: { normalizedKey == $0 || normalizedKey.hasSuffix($0) }) {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    private func normalizedStatKey(_ key: String) -> String {
        key.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private func formattedPercent(_ value: Double?) -> String? {
        guard let value else { return nil }
        return "\(Int(value.rounded()))%"
    }

    private func formattedMWh(_ value: Double?) -> String? {
        guard let value else { return nil }
        return "\(Int(value.rounded())) mWh"
    }

    private func formattedPresentCapacity() -> String? {
        guard let present = port.pdStatus?.batteryPresentCapacityMWh else { return nil }
        let capacity = "\(Int(present.rounded())) mWh"
        if let percent = port.pdStatus?.batteryPercent {
            return "\(capacity) (\(Int(percent.rounded()))%)"
        }
        return capacity
    }

    private func formattedBatteryHealth(_ value: Double?) -> String? {
        guard let value else { return nil }
        if value.rounded() == 100 {
            return "正常"
        }
        if value < 75 {
            return "-"
        }
        return "\(Int(value.rounded()))%"
    }

    private func formattedMinutes(_ value: Double?) -> String? {
        guard let value else { return nil }
        let minutes = max(Int(value.rounded()), 0)
        if minutes >= 60 {
            return "\(minutes / 60)h \(minutes % 60)m"
        }
        return "\(minutes)m"
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
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(items, id: \.self) { item in
                    Text(item)
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                        .background(.secondary.opacity(0.08), in: Capsule())
                        .fixedSize()
                }
            }
        }
    }
}

private struct SessionsView: View {
    let store: MonitorStore
    @State private var selectedSessionIDs = Set<UUID>()
    @State private var selectionAnchorSessionID: UUID?
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
                                if selectedSessionIDs.count > 1 {
                                    Button("取消选择") {
                                        selectSingle(store.selectedSession ?? store.sessions.first)
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
                                    Button {
                                        selectSession(session)
                                    } label: {
                                        SessionRow(
                                            session: session,
                                            isSelected: selectedSessionIDs.contains(session.id)
                                        )
                                    }
                                    .buttonStyle(.plain)
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
        .onAppear {
            if selectedSessionIDs.isEmpty {
                selectSingle(store.selectedSession ?? store.sessions.first)
            }
        }
        .onChange(of: store.sessions.map(\.id)) { _, ids in
            selectedSessionIDs = selectedSessionIDs.intersection(Set(ids))
            if selectedSessionIDs.isEmpty {
                selectSingle(store.selectedSession ?? store.sessions.first)
            }
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

    private func selectSingle(_ session: ChargingSession?) {
        guard let session else { return }
        selectedSessionIDs = [session.id]
        selectionAnchorSessionID = session.id
        store.selectSession(session)
    }

    private func selectSession(_ session: ChargingSession) {
        let modifiers = NSEvent.modifierFlags

        if modifiers.contains(.shift),
           let anchor = selectionAnchorSessionID ?? selectedSessionIDs.sorted(by: sessionOrder).first,
           let anchorIndex = store.sessions.firstIndex(where: { $0.id == anchor }),
           let currentIndex = store.sessions.firstIndex(where: { $0.id == session.id }) {
            let range = anchorIndex <= currentIndex ? anchorIndex...currentIndex : currentIndex...anchorIndex
            let rangeSelection = Set(range.map { store.sessions[$0].id })
            if modifiers.contains(.command) {
                selectedSessionIDs.formUnion(rangeSelection)
            } else {
                selectedSessionIDs = rangeSelection
            }
        } else if modifiers.contains(.command) {
            if selectedSessionIDs.contains(session.id) {
                selectedSessionIDs.remove(session.id)
            } else {
                selectedSessionIDs.insert(session.id)
            }
        } else {
            selectedSessionIDs = [session.id]
        }

        selectionAnchorSessionID = session.id
        store.selectSession(session)
    }

    private func sessionOrder(_ lhs: UUID, _ rhs: UUID) -> Bool {
        let left = store.sessions.firstIndex { $0.id == lhs } ?? Int.max
        let right = store.sessions.firstIndex { $0.id == rhs } ?? Int.max
        return left < right
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

enum ExportMenuStyle {
    case prominent
    case mini
    case plain
}

private struct SessionExportMenu: View {
    let store: MonitorStore
    let session: ChargingSession
    var compact = false
    var style: ExportMenuStyle = .prominent
    var iconOnly = false

    var body: some View {
        switch style {
        case .prominent:
            menuView
                .buttonStyle(SoftButtonStyle(prominent: true))
        case .mini:
            menuView
                .buttonStyle(CandyModernMiniButtonStyle(isIconOnly: iconOnly))
        case .plain:
            menuView
        }
    }

    private var menuView: some View {
        Menu {
            Button {
                store.exportSessionCSV(session)
            } label: {
                Label("CSV", systemImage: "tablecells")
            }
            Button {
                store.exportSessionZIP(session)
            } label: {
                Label("ZIP", systemImage: "doc.zipper")
            }
            Divider()
            Button {
                store.exportSessionShareImage(session)
            } label: {
                Label("分享图", systemImage: "photo")
            }
        } label: {
            if iconOnly {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 11, weight: .medium))
            } else {
                Label("导出", systemImage: "square.and.arrow.up")
                    .labelStyle(.titleAndIcon)
                    .frame(minWidth: compact ? 70 : 76)
            }
        }
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
                    SessionExportMenu(store: store, session: session, style: .plain)
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
    @State private var hoverLocation: CGPoint?
    @State private var hoverX: CGFloat?
    @State private var hoverY: CGFloat?

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                StaticSessionChart(plottedSamples: samples)
                    .equatable()
                    .frame(height: 300)
                    .chartOverlay { proxy in
                        Color.clear
                            .contentShape(Rectangle())
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let location):
                                    self.hoverLocation = location
                                    updateHover(location: location, proxy: proxy, geometry: geometry)
                                case .ended:
                                    hoveredSample = nil
                                    hoverX = nil
                                    hoverY = nil
                                    self.hoverLocation = nil
                                }
                            }
                            .onChange(of: samples) { _, _ in
                                if let hoverLocation {
                                    updateHover(location: hoverLocation, proxy: proxy, geometry: geometry)
                                }
                            }
                    }

                // 顶层指示虚线
                if let hoverX, let hoverY {
                    Path { path in
                        path.move(to: CGPoint(x: hoverX, y: 0))
                        path.addLine(to: CGPoint(x: hoverX, y: 280))
                    }
                    .stroke(CandyTheme.berry.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .allowsHitTesting(false)

                    Circle()
                        .fill(CandyTheme.berry)
                        .frame(width: 8, height: 8)
                        .overlay {
                            Circle()
                                .stroke(Color.white, lineWidth: 2)
                        }
                        .shadow(radius: 2)
                        .position(x: hoverX, y: hoverY)
                        .allowsHitTesting(false)
                }

                if let hoveredSample {
                    SessionReadout(sample: hoveredSample)
                        .padding(14)
                }
            }
        }
        .frame(height: 300)
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func updateHover(location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) {
        guard let plotAnchor = proxy.plotFrame else {
            hoveredSample = nil
            hoverX = nil
            hoverY = nil
            return
        }
        let plotFrame = geometry[plotAnchor]
        guard plotFrame.contains(location),
              let date: Date = proxy.value(atX: location.x - plotFrame.origin.x) else {
            hoveredSample = nil
            hoverX = nil
            hoverY = nil
            return
        }

        if let nearest = samples.min(by: {
            abs($0.timestamp.timeIntervalSince(date)) < abs($1.timestamp.timeIntervalSince(date))
        }) {
            hoveredSample = nearest
            
            if let xPos = proxy.position(forX: nearest.timestamp),
               let yPos = proxy.position(forY: nearest.powerW) {
                self.hoverX = xPos + plotFrame.origin.x
                self.hoverY = yPos + plotFrame.origin.y
            }
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
    case lanURL
    case iotJWT
}

private struct SettingsView: View {
    let store: MonitorStore
    @AppStorage("showInDock") private var showInDock = true
    @State private var launchAtLogin = false
    @State private var editingName = ""
    @State private var editingURL = ""
    @State private var editingLAN = ""
    @State private var editingIOTJWT = ""
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
                    VStack(spacing: 20) {
                        SettingsCard(title: "设备身份", icon: "powerplug.portrait", subtitle: "这里决定侧栏里看到的名字；保存时会重新连接 MCP 并读取机器信息。") {
                            LabeledContent("显示名称") {
                                HStack(spacing: 8) {
                                    TextField("例如 Shawn’s Mirror", text: $editingName)
                                        .textFieldStyle(.roundedBorder)
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

                        SettingsCard(title: "网络连接地址", icon: "network", subtitle: "可分别或同时填写 MCP 与局域网（LAN）地址。同时填写时优先使用局域网数据源。") {
                            TextField("MCP SSE 地址，例如 https://.../sse（可选）", text: $editingURL)
                                .textFieldStyle(.roundedBorder)
                                .focused($focusedField, equals: .url)
                            TextField("局域网地址，例如 http://192.168.31.200/ 或 IP 地址（可选）", text: $editingLAN)
                                .textFieldStyle(.roundedBorder)
                                .focused($focusedField, equals: .lanURL)
                            SecureField("小程序 IOT WS JWT（可选）", text: $editingIOTJWT)
                                .textFieldStyle(.roundedBorder)
                                .focused($focusedField, equals: .iotJWT)
                            LabeledContent("PD status") {
                                Text(editingIOTJWT.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "MCP fallback" : "小程序 WS 优先")
                                    .foregroundStyle(.secondary)
                            }
                            HStack {
                                Button {
                                    Task { await save(device) }
                                } label: {
                                    Label(isSaving ? "校验中" : "保存并校验", systemImage: "checkmark.shield")
                                }
                                .buttonStyle(SoftButtonStyle(prominent: true))
                                .disabled(isSaving || (editingURL.isEmpty && editingLAN.isEmpty))

                                Button {
                                    Task { await store.refreshSelectedDeviceNow() }
                                } label: {
                                    Label("读取状态", systemImage: "arrow.clockwise")
                                }
                                .buttonStyle(SoftButtonStyle())
                            }
                        }

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

                        SettingsCard(title: "桌面集成", icon: "dock.rectangle", subtitle: "常驻菜单栏；开机自启；隐藏 Dock 图标后仍可从菜单栏打开主窗口。") {
                            Toggle("在 Dock 中显示", isOn: $showInDock)
                                .toggleStyle(.switch)
                            
                            Toggle("开机自动启动", isOn: Binding(
                                get: { launchAtLogin },
                                set: { newValue in
                                    launchAtLogin = newValue
                                    let service = SMAppService.mainApp
                                    if newValue {
                                        try? service.register()
                                    } else {
                                        try? service.unregister()
                                    }
                                }
                            ))
                            .toggleStyle(.switch)

                            LabeledContent("主窗口入口") {
                                Text(showInDock ? "Dock 与菜单栏" : "仅菜单栏")
                                    .foregroundStyle(.secondary)
                            }
                            LabeledContent("菜单栏状态") {
                                Text("始终显示")
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

                        SettingsCard(title: "应用版本", icon: "shippingbox", subtitle: "当前安装包信息与本地运行状态。") {
                            LabeledContent("版本") {
                                Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-")
                                    .foregroundStyle(.secondary)
                            }
                            LabeledContent("构建") {
                                Text(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "-")
                                    .foregroundStyle(.secondary)
                            }
                            
                            HStack {
                                Button {
                                    if let delegate = NSApp.delegate as? CandyMonitorAppDelegate {
                                        delegate.updaterController?.checkForUpdates(nil)
                                    }
                                } label: {
                                    Label("检查更新...", systemImage: "arrow.down.circle")
                                }
                                .buttonStyle(SoftButtonStyle())
                            }
                        }
                    }
                    .frame(maxWidth: 600)
                    .frame(maxWidth: .infinity, alignment: .top)
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
        editingLAN = store.lanURL(for: device)
        editingIOTJWT = store.iotGatewayJWT(for: device)
        launchAtLogin = (SMAppService.mainApp.status == .enabled)
    }

    private func save(_ device: MirrorDevice) async {
        isSaving = true
        defer { isSaving = false }
        try? await store.updateDevice(device, name: editingName, sseURLString: editingURL, lanURLString: editingLAN, iotJWTString: editingIOTJWT)
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
    @State private var lanURL = ""
    @State private var iotJWT = ""
    @State private var errorText: String?
    @State private var isSaving = false

    @State private var localDevices: [IonBridgeSnapshot] = []
    @State private var isScanning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("添加小电拼")
                    .font(.title2.weight(.semibold))
                Text("可分别或同时填写 MCP 与局域网（LAN）地址。保存时会优先通过局域网进行校验。")
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("局域网发现的小电拼", systemImage: "wifi")
                        .font(.headline)
                        .foregroundStyle(CandyTheme.syrup)
                    Spacer()
                    if isScanning {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Button {
                            scanLocalDevices()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.plain)
                        .help("重新扫描局域网")
                    }
                }
                
                if isScanning {
                    Text("正在扫描局域网中的小电拼...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else if localDevices.isEmpty {
                    Text("未发现局域网小电拼，你可以手动填写下方信息。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(localDevices, id: \.info.psn) { snapshot in
                                Button {
                                    selectLocalDevice(snapshot)
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(snapshot.info.deviceName ?? "小电拼 Mirror")
                                            .font(.subheadline.weight(.medium))
                                        Text("PSN: \(snapshot.info.psn ?? "未知")")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Text(snapshot.baseURL.host ?? "")
                                            .font(.caption)
                                            .foregroundStyle(CandyTheme.syrup)
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(Color.secondary.opacity(0.1))
                                    .cornerRadius(8)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke((lanURL.contains(snapshot.info.psn ?? "###") || lanURL.contains(snapshot.baseURL.host ?? "###")) ? CandyTheme.syrup : Color.clear, lineWidth: 1.5)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .padding(.bottom, 8)

            TextField("设备名称，例如 Shawn’s Mirror", text: $name)
                .textFieldStyle(.roundedBorder)
            TextField("MCP SSE 地址，例如 https://.../sse（可选）", text: $sseURL)
                .textFieldStyle(.roundedBorder)
            TextField("局域网地址，例如 http://192.168.31.200/ 或 IP 地址（可选）", text: $lanURL)
                .textFieldStyle(.roundedBorder)
            SecureField("小程序 IOT WS JWT（可选）", text: $iotJWT)
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
                .disabled(isSaving || (sseURL.isEmpty && lanURL.isEmpty))
            }
        }
        .padding(24)
        .frame(width: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            scanLocalDevices()
        }
    }

    private func scanLocalDevices() {
        isScanning = true
        localDevices.removeAll()
        Task {
            _ = await store.discoverLocalDevices { snapshot in
                Task { @MainActor in
                    if !self.localDevices.contains(where: { $0.info.psn == snapshot.info.psn }) {
                        self.localDevices.append(snapshot)
                    }
                }
            }
            await MainActor.run {
                self.isScanning = false
            }
        }
    }

    private func selectLocalDevice(_ snapshot: IonBridgeSnapshot) {
        let psn = snapshot.info.psn ?? ""
        let shortPSN = String(psn.suffix(4))
        name = "小电拼 cp02 - \(shortPSN)"
        lanURL = snapshot.baseURL.absoluteString
    }

    private func add() async {
        isSaving = true
        errorText = nil
        do {
            try await store.addDevice(name: name, sseURLString: sseURL, lanURLString: lanURL, iotJWTString: iotJWT)
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

private struct CandyModernMiniButtonStyle: ButtonStyle {
    @State private var isHovered = false
    var isIconOnly = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, isIconOnly ? 0 : 8)
            .frame(width: isIconOnly ? 24 : nil, height: 24)
            .foregroundStyle(CandyTheme.syrup)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHovered ? CandyTheme.syrup.opacity(0.08) : Color.primary.opacity(0.04))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(isHovered ? CandyTheme.syrup.opacity(0.16) : Color.primary.opacity(0.06), lineWidth: 0.8)
            }
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .onHover { hover in
                isHovered = hover
            }
            .animation(.easeOut(duration: 0.12), value: isHovered)
    }
}

private struct RecordingIndicator: View {
    @State private var recPulse = false

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(Color.red)
                .frame(width: 6, height: 6)
                .opacity(recPulse ? 0.35 : 1.0)
                .onAppear {
                    withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                        recPulse = true
                    }
                }
            Text("REC")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.red)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Color.red.opacity(0.08), in: Capsule())
    }
}

private struct IdleIndicator: View {
    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(CandyTheme.mint)
                .frame(width: 6, height: 6)
            Text("待命")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(CandyTheme.mint)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(CandyTheme.mint.opacity(0.08), in: Capsule())
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

struct MenuBarPowerLabel: View {
    let totalPowerW: Double
    let connectionState: ConnectionState

    var body: some View {
        Label {
            Text(powerText)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
        } icon: {
            Image("CandyMenuBarIconBlack")
                .renderingMode(.template)
        }
        .accessibilityLabel("CandyMonitor 当前功率 \(powerText)")
    }

    private var powerText: String {
        if totalPowerW >= 100 {
            return "\(Int(totalPowerW.rounded()))W"
        }
        return String(format: "%.1fW", totalPowerW)
    }
}

struct MenuBarStatusLabel: View {
    @Environment(\.openWindow) private var openWindow
    let store: MonitorStore

    var body: some View {
        Image(nsImage: renderedCandyPowerImage)
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("OpenMainWindowNotification"))) { _ in
                openWindow(id: "main")
                DispatchQueue.main.async {
                    if let window = NSApp.windows.first(where: { $0.canBecomeMain && $0.styleMask.contains(.titled) }) {
                        window.makeKeyAndOrderFront(nil)
                        NSApp.activate(ignoringOtherApps: true)
                    }
                }
            }
    }

    private var renderedCandyPowerImage: NSImage {
        let power = store.totalPowerW
        let iconSize = NSSize(width: 20, height: 12)
        let height: CGFloat = 22
        
        let iconImage: NSImage
        if let customIcon = NSImage(named: "CandyMenuBarIconBlack") {
            iconImage = customIcon
        } else if #available(macOS 11.0, *), let systemIcon = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil) {
            iconImage = systemIcon
        } else {
            iconImage = NSImage()
        }

        if power > 0.5 {
            let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.black
            ]
            let powerText: String
            if power >= 100 {
                powerText = "\(Int(power.rounded()))W"
            } else {
                powerText = String(format: "%.1fW", power)
            }
            let text = powerText as NSString
            let textSize = text.size(withAttributes: attributes)
            let spacing: CGFloat = 5
            let width = ceil(iconSize.width + spacing + textSize.width)
            
            let image = NSImage(size: NSSize(width: width, height: height))
            image.lockFocus()
            NSColor.clear.setFill()
            NSRect(origin: .zero, size: image.size).fill()
            
            iconImage.draw(in: NSRect(
                x: 0,
                y: floor((height - iconSize.height) / 2),
                width: iconSize.width,
                height: iconSize.height
            ))
            
            text.draw(at: NSPoint(
                x: iconSize.width + spacing,
                y: floor((height - textSize.height) / 2)
            ), withAttributes: attributes)
            
            image.unlockFocus()
            image.isTemplate = true
            return image
        } else {
            let width = iconSize.width
            let image = NSImage(size: NSSize(width: width, height: height))
            image.lockFocus()
            NSColor.clear.setFill()
            NSRect(origin: .zero, size: image.size).fill()
            
            iconImage.draw(in: NSRect(
                x: 0,
                y: floor((height - iconSize.height) / 2),
                width: iconSize.width,
                height: iconSize.height
            ))
            
            image.unlockFocus()
            image.isTemplate = true
            return image
        }
    }
}

struct CandyMenuBarView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openWindow) private var openWindow
    let store: MonitorStore
    @State private var hoveredPortID: Int?
    @State private var hoveredSessionID: UUID?
    @State private var hoverPreview: MenuBarChartPreview?
    @State private var hoverAnchorRect: CGRect?
    @State private var hoverTargetKey: String?
    @State private var hoverCloseGeneration = 0
    @State private var isHoveringPreviewWindow = false

    private var connectedPorts: Int {
        store.livePorts.filter(\.connected).count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if store.hasDevices {
                powerSummary
                portsSection
                activeSessionSection
                footer
            } else {
                emptyState
            }
        }
        .padding(16)
        .frame(width: 390)
        .background(MenuBarPanelBackground().ignoresSafeArea())
        .task {
            configureStore()
        }
        .onAppear {
            configureStore()
        }
        .tint(CandyTheme.syrup)
        .accentColor(CandyTheme.syrup)
        .background(MenuBarPreviewWindowHost(preview: $hoverPreview, anchorRect: $hoverAnchorRect, isHovering: $isHoveringPreviewWindow))
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image("CandyMenuBarIconWhite")
                .resizable()
                .interpolation(.high)
                .antialiased(true)
                .scaledToFit()
                .frame(width: 18, height: 18)
                .frame(width: 36, height: 36)
                .background(CandyTheme.syrup, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .shadow(color: CandyTheme.syrup.opacity(0.28), radius: 9, y: 4)

            VStack(alignment: .leading, spacing: 2) {
                Text(store.selectedDevice?.name ?? "CandyMonitor")
                    .font(.headline)
                    .lineLimit(1)
                Text(store.selectedDevice?.productFamily ?? "CoCan Mirror")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()
            MenuBarConnectionBadge(state: store.connectionState)
        }
    }

    private var powerSummary: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("实时总功率")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(String(format: "%.1f", store.totalPowerW))
                            .font(.system(size: 42, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(CandyTheme.syrup)
                        Text("W")
                            .font(.title3.weight(.bold))
                            .foregroundStyle(CandyTheme.syrup)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    StatusPill(text: "\(connectedPorts)/\(store.livePorts.count) 端口", color: connectedPorts > 0 ? CandyTheme.mint : .secondary)
                    StatusPill(text: "\(store.activeChargingSessions.count) 记录中", color: store.activeChargingSessions.isEmpty ? .secondary : CandyTheme.caramel)
                }
            }

            PowerCapacityBar(totalPowerW: store.totalPowerW, maxPowerW: max(store.selectedDevice?.maxPowerBudget ?? 160, 1))
        }
        .padding(14)
        .background(CandyTheme.menuCardBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(CandyTheme.separator, lineWidth: 1)
        }
    }

    private var portsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("端口详情", systemImage: "powerplug")
                    .font(.headline)
                Spacer()
                SyncStatusView(date: store.lastRefreshedAt, isRefreshing: store.isRefreshingNow)
            }

            if store.livePorts.isEmpty {
                Text("等待实时端口数据。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 72)
            } else {
                VStack(spacing: 8) {
                    ForEach(store.livePorts) { port in
                        MenuBarPortRow(port: port)
                            .background(HoverFrameReader { isHovering, rect in
                                let key = "port-\(port.id)"
                                if isHovering {
                                    hoverCloseGeneration += 1
                                    hoverTargetKey = key
                                    hoveredPortID = port.id
                                    hoveredSessionID = nil
                                    hoverAnchorRect = rect
                                    setHoverPreview(portPreview(for: port))
                                } else if hoverTargetKey == key {
                                    hoverTargetKey = nil
                                    hoveredPortID = nil
                                    if hoveredSessionID == nil {
                                        schedulePreviewClose()
                                    }
                                }
                            })
                    }
                }
            }
        }
    }

    private var activeSessionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("充电记录", systemImage: "waveform.path.ecg")
                .font(.headline)

            if store.activeChargingSessions.isEmpty == false {
                VStack(spacing: 8) {
                    ForEach(store.activeChargingSessions) { session in
                        HStack(spacing: 10) {
                            Image(systemName: "record.circle")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(CandyTheme.caramel)
                                .frame(width: 30, height: 30)
                                .background(CandyTheme.caramel.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(session.displayTitle)
                                    .font(.callout.weight(.semibold))
                                    .lineLimit(1)
                                Text("峰值 \(String(format: "%.1f W", session.peakPowerW)) · 已采 \(session.sampleCount) 点")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("记录中")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(CandyTheme.caramel)
                                .padding(.horizontal, 8)
                                .frame(height: 22)
                                .background(CandyTheme.caramel.opacity(0.12), in: Capsule())
                        }
                        .padding(10)
                        .background(CandyTheme.menuRowBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .background(HoverFrameReader { isHovering, rect in
                            let key = "session-\(session.id.uuidString)"
                            if isHovering {
                                hoverCloseGeneration += 1
                                hoverTargetKey = key
                                hoveredSessionID = session.id
                                hoveredPortID = nil
                                hoverAnchorRect = rect
                                setHoverPreview(sessionPreview(for: session))
                            } else if hoverTargetKey == key {
                                hoverTargetKey = nil
                                hoveredSessionID = nil
                                if hoveredPortID == nil {
                                    schedulePreviewClose()
                                }
                            }
                        })
                    }
                }
            } else {
                Text("接入负载并开始输出功率后会自动记录曲线。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(CandyTheme.menuRowBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                Task { await store.refreshSelectedDeviceNow() }
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }
            .buttonStyle(SoftButtonStyle())
            .disabled(store.isRefreshingNow)

            Spacer()

            Button {
                openMainWindow(section: .monitor)
            } label: {
                Label("打开监控", systemImage: "rectangle.on.rectangle")
            }
            .buttonStyle(SoftButtonStyle(prominent: true))
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "bolt.horizontal.icloud")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(CandyTheme.syrup)
            Text("还没有添加设备")
                .font(.headline)
            Text("打开主窗口填写 MCP SSE 地址后，菜单栏会开始显示实时功率。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                openMainWindow(section: .settings)
                store.isShowingAddDevice = true
            } label: {
                Label("添加设备", systemImage: "plus.circle.fill")
            }
            .buttonStyle(SoftButtonStyle(prominent: true))
        }
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity)
    }

    private func configureStore() {
        store.configure(modelContext: modelContext)
        if store.isRealtimeRefreshEnabled == false {
            store.isRealtimeRefreshEnabled = true
        }
    }

    private func openMainWindow(section: AppSection) {
        store.selectedSection = section
        if let window = NSApp.windows.first(where: { window in
            window.canBecomeMain && window.styleMask.contains(.titled)
        }) {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            openWindow(id: "main")
            DispatchQueue.main.async {
                NSApp.windows.first(where: { $0.canBecomeMain && $0.styleMask.contains(.titled) })?.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    private func portPreview(for port: PortViewState) -> MenuBarChartPreview? {
        let samples = store.recentSamples
            .filter { $0.portIndex == port.id }
            .map { MenuBarChartPoint(timestamp: $0.timestamp, powerW: $0.powerW) }
        return MenuBarChartPreview(
            key: "port-\(port.id)",
            title: port.port.displayName,
            subtitle: "最近 10 秒",
            value: String(format: "%.1f W", port.powerW),
            samples: samples
        )
    }

    private func sessionPreview(for session: ChargingSession) -> MenuBarChartPreview {
        var samples = store.previewSamples(for: session, limit: 360)
            .map { MenuBarChartPoint(timestamp: $0.timestamp, powerW: $0.powerW) }
        if samples.isEmpty, store.selectedSession?.id == session.id {
            samples = store.selectedSessionSamples
                .map { MenuBarChartPoint(timestamp: $0.timestamp, powerW: $0.powerW) }
        }
        if samples.isEmpty, session.endedAt == nil {
            samples = store.recentSamples
                .filter { $0.portIndex == session.portIndex && $0.timestamp >= session.startedAt }
                .map { MenuBarChartPoint(timestamp: $0.timestamp, powerW: $0.powerW) }
        }
        return MenuBarChartPreview(
            key: "session-\(session.id.uuidString)",
            title: session.portName,
            subtitle: "完整曲线",
            value: String(format: "%.1f W", session.peakPowerW),
            samples: samples
        )
    }

    private func schedulePreviewClose() {
        hoverCloseGeneration += 1
        let generation = hoverCloseGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.36) {
            if generation == hoverCloseGeneration &&
                hoverTargetKey == nil &&
                hoveredPortID == nil &&
                hoveredSessionID == nil &&
                isHoveringPreviewWindow == false {
                hoverPreview = nil
                hoverAnchorRect = nil
            }
        }
    }

    private func setHoverPreview(_ preview: MenuBarChartPreview?) {
        guard let preview else {
            hoverPreview = nil
            return
        }
        if hoverPreview?.key != preview.key {
            hoverPreview = preview
        }
    }

}

private struct MenuBarChartPoint: Identifiable {
    let id = UUID()
    let timestamp: Date
    let powerW: Double
}

private struct MenuBarChartPreview: Equatable {
    let key: String
    let title: String
    let subtitle: String
    let value: String
    let samples: [MenuBarChartPoint]

    static func == (lhs: MenuBarChartPreview, rhs: MenuBarChartPreview) -> Bool {
        lhs.key == rhs.key &&
        lhs.title == rhs.title &&
        lhs.subtitle == rhs.subtitle &&
        lhs.value == rhs.value &&
        lhs.samples.count == rhs.samples.count &&
        lhs.samples.last?.timestamp == rhs.samples.last?.timestamp
    }
}

private struct HoverFrameReader: NSViewRepresentable {
    let onHover: (Bool, CGRect) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = TrackingView()
        view.onHover = onHover
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? TrackingView else { return }
        view.onHover = onHover
        if view.isMouseInside {
            view.emitHover(true, deferred: true)
        }
    }

    private final class TrackingView: NSView {
        var onHover: ((Bool, CGRect) -> Void)?
        var isMouseInside = false

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach { removeTrackingArea($0) }
            addTrackingArea(NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self,
                userInfo: nil
            ))
        }

        override func mouseEntered(with event: NSEvent) {
            isMouseInside = true
            emitHover(true)
        }

        override func mouseExited(with event: NSEvent) {
            isMouseInside = false
            emitHover(false)
        }

        func emitHover(_ hovering: Bool, deferred: Bool = false) {
            guard let window else { return }
            let rectInWindow = convert(bounds, to: nil)
            let screenRect = window.convertToScreen(rectInWindow)
            let callback: () -> Void = { [weak self] in
                _ = self?.onHover?(hovering, screenRect)
            }
            if deferred {
                DispatchQueue.main.async(execute: callback)
            } else {
                callback()
            }
        }
    }
}

private struct MenuBarPreviewWindowHost: NSViewRepresentable {
    @Binding var preview: MenuBarChartPreview?
    @Binding var anchorRect: CGRect?
    @Binding var isHovering: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.update(preview: preview, sourceWindow: nsView.window, anchorRect: anchorRect, isHovering: $isHovering)
    }

    final class Coordinator {
        private var panel: NSPanel?
        private var hostingView: NSHostingView<AnyView>?
        private var currentPreview: MenuBarChartPreview?

        func update(preview: MenuBarChartPreview?, sourceWindow: NSWindow?, anchorRect: CGRect?, isHovering: Binding<Bool>) {
            guard let preview else {
                close()
                return
            }

            let panel = panel ?? makePanel()
            self.panel = panel
            if hostingView == nil {
                let hostingView = NSHostingView(rootView: AnyView(EmptyView()))
                self.hostingView = hostingView
                panel.contentView = hostingView
            }
            if currentPreview != preview {
                currentPreview = preview
                hostingView?.rootView = AnyView(
                    MenuBarChartPreviewPanel(preview: preview)
                        .onHover { hovering in
                            isHovering.wrappedValue = hovering
                        }
                )
            }
            position(panel, beside: sourceWindow, alignedTo: anchorRect)
            if panel.isVisible == false {
                panel.orderFront(nil)
            }
        }

        private func makePanel() -> NSPanel {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 278, height: 160),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            panel.level = .popUpMenu
            panel.ignoresMouseEvents = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            return panel
        }

        private func position(_ panel: NSPanel, beside sourceWindow: NSWindow?, alignedTo anchorRect: CGRect?) {
            let location = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { $0.frame.contains(location) } ?? NSScreen.main
            let visible = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
            let size = panel.contentView?.fittingSize ?? NSSize(width: 278, height: 160)
            let gap: CGFloat = 14
            let anchor = sourceWindow?.frame ?? NSRect(origin: location, size: .zero)
            let rowAnchor = anchorRect ?? anchor
            let rightSpace = visible.maxX - anchor.maxX
            let leftSpace = anchor.minX - visible.minX
            let x = rightSpace >= size.width + gap || rightSpace >= leftSpace
                ? min(anchor.maxX + gap, visible.maxX - size.width - 8)
                : max(anchor.minX - size.width - gap, visible.minX + 8)
            let preferredY = rowAnchor.midY - size.height / 2
            let y = min(max(preferredY, visible.minY + 8), visible.maxY - size.height - 8)
            panel.setFrame(NSRect(origin: CGPoint(x: x, y: y), size: size), display: true)
        }

        private func close() {
            currentPreview = nil
            panel?.orderOut(nil)
        }
    }
}

private struct MenuBarChartPreviewPanel: View {
    let preview: MenuBarChartPreview

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(preview.title)
                        .font(.callout.weight(.semibold))
                    Text(preview.subtitle)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(preview.value)
                    .font(.headline.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(CandyTheme.syrup)
            }

            MenuBarMiniPowerChart(samples: preview.samples)
                .frame(height: 116)
        }
        .padding(12)
        .frame(width: 278)
        .background(CandyTheme.menuCardBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.16), radius: 14, y: 8)
    }
}

private struct MenuBarMiniPowerChart: View {
    let samples: [MenuBarChartPoint]
    @State private var hoveredSample: MenuBarChartPoint?

    var body: some View {
        if samples.count > 1 {
            GeometryReader { proxy in
                let rect = proxy.size
                let plot = CGRect(x: 2, y: 8, width: max(rect.width - 4, 1), height: max(rect.height - 20, 1))
                let points = plottedPoints(in: plot)

                ZStack(alignment: .topLeading) {
                    Canvas { context, _ in
                        for index in 0...3 {
                            let y = plot.minY + plot.height * CGFloat(index) / 3
                            var grid = Path()
                            grid.move(to: CGPoint(x: plot.minX, y: y))
                            grid.addLine(to: CGPoint(x: plot.maxX, y: y))
                            context.stroke(grid, with: .color(.secondary.opacity(0.13)), lineWidth: 1)
                        }

                        var line = Path()
                        for (index, point) in points.enumerated() {
                            if index == 0 {
                                line.move(to: point)
                            } else {
                                line.addLine(to: point)
                            }
                        }
                        context.stroke(line, with: .color(CandyTheme.syrup), style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))

                        if let hoveredSample,
                           let point = point(for: hoveredSample, in: plot) {
                            var rule = Path()
                            rule.move(to: CGPoint(x: point.x, y: plot.minY))
                            rule.addLine(to: CGPoint(x: point.x, y: plot.maxY))
                            context.stroke(rule, with: .color(CandyTheme.syrup.opacity(0.22)), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                            context.fill(Path(ellipseIn: CGRect(x: point.x - 3.5, y: point.y - 3.5, width: 7, height: 7)), with: .color(CandyTheme.syrup))
                        }
                    }
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            hoveredSample = nearestSample(toX: location.x, in: plot)
                        case .ended:
                            hoveredSample = nil
                        }
                    }

                    if let first = samples.first?.timestamp,
                       let last = samples.last?.timestamp {
                        HStack {
                            Text(first, format: .dateTime.hour().minute().second())
                            Spacer()
                            Text(last, format: .dateTime.hour().minute().second())
                        }
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary.opacity(0.72))
                        .position(x: rect.width / 2, y: rect.height - 6)
                        .allowsHitTesting(false)
                    }

                    if let hoveredSample,
                       let point = point(for: hoveredSample, in: plot) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(hoveredSample.timestamp, format: .dateTime.hour().minute().second())
                            Text(String(format: "%.1f W", hoveredSample.powerW))
                                .font(.caption.weight(.bold))
                        }
                        .font(.caption2)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 5)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                        }
                        .position(
                            x: min(max(point.x + 42, 42), rect.width - 42),
                            y: min(max(point.y - 24, 22), rect.height - 24)
                        )
                        .allowsHitTesting(false)
                    }
                }
            }
        } else {
            VStack(spacing: 6) {
                Image(systemName: "chart.xyaxis.line")
                    .font(.title3)
                    .foregroundStyle(.secondary.opacity(0.7))
                Text("暂无曲线")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func plottedPoints(in rect: CGRect) -> [CGPoint] {
        samples.compactMap { point(for: $0, in: rect) }
    }

    private func point(for sample: MenuBarChartPoint, in rect: CGRect) -> CGPoint? {
        guard let first = samples.first?.timestamp,
              let last = samples.last?.timestamp else { return nil }
        let span = max(last.timeIntervalSince(first), 1)
        let maxPower = max(1, (samples.map(\.powerW).max() ?? 0) * 1.12)
        let x = rect.minX + rect.width * sample.timestamp.timeIntervalSince(first) / span
        let y = rect.maxY - rect.height * min(max(sample.powerW / maxPower, 0), 1)
        return CGPoint(x: x, y: y)
    }

    private func nearestSample(toX x: CGFloat, in rect: CGRect) -> MenuBarChartPoint? {
        guard let first = samples.first?.timestamp,
              let last = samples.last?.timestamp else { return nil }
        let span = max(last.timeIntervalSince(first), 1)
        let ratio = min(max((x - rect.minX) / max(rect.width, 1), 0), 1)
        let date = first.addingTimeInterval(span * ratio)
        return samples.min {
            abs($0.timestamp.timeIntervalSince(date)) < abs($1.timestamp.timeIntervalSince(date))
        }
    }
}

private struct MenuBarPanelBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = .popover
        nsView.blendingMode = .behindWindow
        nsView.state = .active
    }
}

private struct MenuBarConnectionBadge: View {
    let state: ConnectionState

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(state.color)
                .frame(width: 7, height: 7)
            Text(state == .connected ? "在线" : state.label)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .frame(height: 24)
        .background(state.color.opacity(0.12), in: Capsule())
    }
}

private struct PowerCapacityBar: View {
    let totalPowerW: Double
    let maxPowerW: Int

    private var ratio: Double {
        min(max(totalPowerW / Double(max(maxPowerW, 1)), 0), 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.secondary.opacity(0.12))
                    Capsule()
                        .fill(CandyTheme.syrup)
                        .frame(width: max(10, proxy.size.width * ratio))
                }
            }
            .frame(height: 9)

            HStack {
                Text("功率预算")
                Spacer()
                Text("\(Int((ratio * 100).rounded()))% / \(maxPowerW)W")
                    .monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

private struct MenuBarPortRow: View {
    let port: PortViewState

    var body: some View {
        HStack(spacing: 10) {
            MirrorConnectorGlyph(connectorType: port.port.connectorType, activeColor: port.connected ? CandyTheme.mint : CandyTheme.syrup)
                .frame(width: 36, height: 18)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(port.port.displayName)
                        .font(.callout.weight(.semibold))
                    Circle()
                        .fill(port.connected ? CandyTheme.mint : .secondary.opacity(0.45))
                        .frame(width: 6, height: 6)
                    Text(port.chargeStateLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(portDetailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(String(format: "%.1fW", port.powerW))
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(port.connected ? CandyTheme.mint : .secondary)
                Text(port.protocolLabel)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(port.connected ? CandyTheme.mint : CandyTheme.syrup.opacity(0.35))
                .frame(width: 3)
        }
    }

    private var portDetailText: String {
        let voltage = String(format: "%.2fV", Double(port.detail?.voutMV ?? 0) / 1000)
        let current = String(format: "%.2fA", Double(port.detail?.ioutMA ?? 0) / 1000)
        if let battery = port.batteryPercent {
            return "\(voltage) / \(current) · 电量 \(Int(battery.rounded()))%"
        }
        return "\(voltage) / \(current) · 温度 \(port.temperatureLabel)"
    }
}

#Preview {
    ContentView(store: MonitorStore())
        .modelContainer(for: [MirrorDevice.self, ChargingSession.self, PortSample.self, ControlEvent.self], inMemory: true)
}
