import SwiftUI
import AppKit

// MARK: - Wireless ADB Status Bar (Compact Card for NativeMonitorView)

struct WirelessADBBar: View {
    let store: MonitorStore
    @State private var isShowingManagement = false
    @State private var isReconnecting = false

    private var adb: ADBService { store.adbService }

    private var primaryDevice: ADBDevice? {
        // 优先获取绑定了当前正在充电端口的设备，否则返回第一个在线设备
        for port in store.livePorts where port.connected {
            if let bound = adb.boundDevice(for: port.port.index) {
                return bound
            }
        }
        return adb.devices.first(where: { $0.isOnline }) ?? adb.devices.first
    }

    var body: some View {
        HStack(spacing: 12) {
            // Android 标志与在线小绿点
            HStack(spacing: 6) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(statusColor)

                Text("Android 无线调试")
                    .font(.system(size: 12, weight: .bold))
            }

            Divider()
                .frame(height: 14)

            // 设备状态信息
            if let device = primaryDevice, device.isOnline {
                HStack(spacing: 8) {
                    Circle()
                        .fill(.green)
                        .frame(width: 6, height: 6)

                    Text(device.displayName)
                        .font(.system(size: 12, weight: .semibold))

                    Text(device.shortAddress)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)

                    if let level = device.batteryPercent {
                        HStack(spacing: 3) {
                            Image(systemName: level > 20 ? "battery.75" : "battery.25")
                                .font(.system(size: 11))
                            Text("\(Int(round(level)))%")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                        }
                        .foregroundStyle(.green)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.green.opacity(0.12), in: Capsule())
                    }

                    if let temp = device.batteryTempC {
                        HStack(spacing: 3) {
                            Image(systemName: "thermometer.medium")
                                .font(.system(size: 10))
                            Text(String(format: "%.1f°C", temp))
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                        }
                        .foregroundStyle(temp > 40 ? .red : (temp > 35 ? .orange : .blue))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.12), in: Capsule())
                    }

                    if let volt = device.batteryVoltageMV {
                        Text("\(volt) mV")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }

                    if let boundPort = adb.boundPort(for: device.serial) {
                        Text("已绑定 \(LocalizedTelemetry.portName(boundPort)) 口")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(CandyTheme.syrup, in: Capsule())
                    }

                    if store.isRecordingStandaloneBattery(serial: device.serial) {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(.green)
                                .frame(width: 6, height: 6)
                            Text("独立记录中")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.green)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.green.opacity(0.12), in: Capsule())
                    }
                }
            } else if adb.serverState.isReady {
                HStack(spacing: 6) {
                    Circle()
                        .fill(.secondary.opacity(0.5))
                        .frame(width: 6, height: 6)

                    Text("未连接 Android 设备")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            } else {
                HStack(spacing: 6) {
                    Circle()
                        .fill(.orange)
                        .frame(width: 6, height: 6)

                    Text("ADB 服务未就绪 (\(adb.serverState.statusDescription))")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // 操作按扭
            HStack(spacing: 6) {
                if let device = primaryDevice, device.isWireless, let ip = device.ip, let port = device.port {
                    Button {
                        isReconnecting = true
                        Task {
                            _ = await adb.connect(host: ip, port: port)
                            isReconnecting = false
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: isReconnecting ? "arrow.clockwise" : "arrow.triangle.2.circlepath")
                            Text("重连")
                        }
                        .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                    .disabled(isReconnecting)
                }

                Button {
                    store.selectedSection = .wirelessADB
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "slider.horizontal.2.square")
                        Text("无线调试管理")
                    }
                    .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(CandyTheme.syrup.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                .foregroundStyle(CandyTheme.syrup)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(CandyTheme.separator, lineWidth: 1)
        }
    }

    private var statusColor: Color {
        if primaryDevice?.isOnline == true {
            return .green
        } else if adb.serverState.isReady {
            return .orange
        } else {
            return .secondary
        }
    }
}

// MARK: - Wireless ADB Management Sheet

struct WirelessADBManagementSheet: View {
    let store: MonitorStore
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab: ADBSheetTab = .pair

    private enum ADBSheetTab: String, CaseIterable, Identifiable {
        case pair = "配对与连接"
        case devices = "在线设备与绑定"
        case environment = "环境检测"

        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(CandyTheme.syrup)

                    Text("Android 无线调试管理")
                        .font(.title3.weight(.bold))
                }

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 22)
            .padding(.top, 18)
            .padding(.bottom, 12)

            // Tabs
            Picker("", selection: $selectedTab) {
                ForEach(ADBSheetTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 22)
            .padding(.bottom, 16)

            Divider()

            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch selectedTab {
                    case .pair:
                        ADBPairingTabView(store: store)
                    case .devices:
                        ADBDevicesTabView(store: store)
                    case .environment:
                        ADBEnvironmentTabView(store: store)
                    }
                }
                .padding(22)
            }
        }
        .frame(width: 620, height: 560)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - Tab 1: Pairing & Connecting

private struct ADBPairingTabView: View {
    let store: MonitorStore
    @State private var pairHost: String = ""
    @State private var pairPort: String = ""
    @State private var pairingCode: String = ""
    @State private var debugPort: String = ""

    @State private var directHost: String = ""
    @State private var directPort: String = "5555"

    @State private var isPairing: Bool = false
    @State private var isConnecting: Bool = false
    @State private var connectingTarget: String?
    @State private var statusMessage: String?
    @State private var isError: Bool = false

    private var adb: ADBService { store.adbService }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // 1. 局域网已发现的无线调试设备 (Bonjour / mDNS)
            discoveredLANDevicesCard

            // 2. 直接连接已配对设备
            directConnectCard

            // 3. 配对新手机
            pairingCard

            // 4. 最近连接记录
            recentConnectionsCard
        }
    }

    // MARK: - 1. Discovered LAN Devices Card (mDNS)

    private var discoveredLANDevicesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(CandyTheme.syrup)

                Text("局域网已发现的无线调试设备")
                    .font(.headline)

                if !adb.discoveredLANDevices.isEmpty {
                    Text("\(adb.discoveredLANDevices.count) 台在线")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(CandyTheme.syrup)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(CandyTheme.syrup.opacity(0.12), in: Capsule())
                }

                Spacer()

                Button {
                    adb.refreshLANDevices()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                        Text("重新扫描")
                    }
                    .font(.caption.weight(.medium))
                }
                .buttonStyle(SoftButtonStyle())
            }

            if adb.discoveredLANDevices.isEmpty {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("正在持续监听局域网中的 Android 无线调试广播...")
                            .font(.caption.weight(.medium))
                        Text("请确保手机与 Mac 处于同一 Wi-Fi，且手机已进入「开发者选项 → 无线调试」开启开关。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            } else {
                VStack(spacing: 8) {
                    ForEach(adb.discoveredLANDevices) { dev in
                        discoveredDeviceRow(dev)
                    }
                }
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12).stroke(CandyTheme.separator, lineWidth: 1)
        }
    }

    private func discoveredDeviceRow(_ dev: DiscoveredADBDevice) -> some View {
        let connected = isDeviceConnected(dev)
        let isThisConnecting = isConnecting && connectingTarget == "\(dev.host):\(dev.port)"

        return HStack(spacing: 12) {
            Image(systemName: "smartphone")
                .font(.system(size: 20))
                .foregroundStyle(connected ? .green : CandyTheme.syrup)
                .frame(width: 32, height: 32)
                .background((connected ? Color.green : CandyTheme.syrup).opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(dev.displayName)
                        .font(.system(size: 13, weight: .bold))

                    if connected {
                        HStack(spacing: 3) {
                            Circle().fill(.green).frame(width: 6, height: 6)
                            Text("已连接")
                        }
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.green)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.green.opacity(0.12), in: Capsule())
                    } else {
                        Text("就绪")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.1), in: Capsule())
                    }
                }

                HStack(spacing: 8) {
                    Text(verbatim: "\(dev.host):\(dev.port)")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)

                    if !dev.serial.isEmpty {
                        Text(verbatim: "S/N: \(dev.serial)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Spacer()

            if connected {
                Button("断开") {
                    disconnectDevice(dev)
                }
                .buttonStyle(SoftButtonStyle(destructive: true))
            } else {
                Button {
                    directHost = dev.host
                    directPort = String(dev.port)
                } label: {
                    Text("填入下方")
                        .font(.caption)
                }
                .buttonStyle(SoftButtonStyle())

                Button {
                    connectToDiscovered(dev)
                } label: {
                    if isThisConnecting {
                        ProgressView().controlSize(.small)
                    } else {
                        HStack(spacing: 4) {
                            Image(systemName: "bolt.fill")
                            Text("一键连接")
                        }
                        .font(.system(size: 11, weight: .semibold))
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(CandyTheme.syrup)
                .disabled(isConnecting)
            }
        }
        .padding(10)
        .background(.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - 2. Direct Connect Card

    private var directConnectCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("直接连接已配对设备", systemImage: "cable.connector")
                    .font(.headline)

                Spacer()

                Button {
                    adb.restartServer()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.clockwise")
                        Text("重启 ADB 服务")
                    }
                    .font(.caption2)
                }
                .buttonStyle(SoftButtonStyle())
                .help("若提示 No route to host 或端口被占用，点击重启底层 adb daemon 路由缓存")
            }

            Text("适用于已配对过的手机。若手机开启无线调试后端口发生变动，直接输入当前端口或从上方列表一键直连。")
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                TextField("IP 地址 (如 192.168.10.152)", text: $directHost)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: directHost) { _, newValue in
                        if let parsed = smartParseHostAndPort(from: newValue) {
                            directHost = parsed.host
                            if let p = parsed.port {
                                directPort = p
                            }
                        }
                    }

                TextField("调试端口", text: $directPort)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 110)
                    .onChange(of: directPort) { _, newValue in
                        let cleaned = newValue.filter { $0.isNumber }
                        if cleaned != newValue {
                            directPort = cleaned
                        }
                    }

                Button {
                    startDirectConnect()
                } label: {
                    if isConnecting && connectingTarget == nil {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("连接")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(CandyTheme.syrup)
                .disabled(isConnecting || directHost.isEmpty || directPort.isEmpty)
            }

            // 状态反馈与自愈提示
            if let msg = statusMessage {
                HStack(spacing: 6) {
                    Image(systemName: isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(isError ? .red : .green)
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(isError ? .red : .primary)

                    if isError && (msg.contains("No route") || msg.contains("Connection refused") || msg.contains("拒绝")) {
                        Spacer()
                        Button("一键重启 ADB 服务") {
                            adb.restartServer()
                        }
                        .buttonStyle(SoftButtonStyle())
                    }
                }
                .padding(.horizontal, 4)
                .padding(.top, 4)
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12).stroke(CandyTheme.separator, lineWidth: 1)
        }
    }

    // MARK: - 3. Pairing Card

    private var pairingCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("使用配对码配对新手机", systemImage: "qrcode")
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text("1. 手机连接与 Mac 相同的 Wi-Fi 局域网。")
                Text("2. 手机进入「设置 → 开发者选项 → 无线调试」。")
                Text("3. 点击「使用配对码配对设备」，查看显示的 IP、配对端口及 6 位配对码。")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))

            HStack(spacing: 10) {
                TextField("IP 地址 (如 192.168.10.152)", text: $pairHost)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: pairHost) { _, newValue in
                        if let parsed = smartParseHostAndPort(from: newValue) {
                            pairHost = parsed.host
                            if let p = parsed.port {
                                pairPort = p
                            }
                        }
                    }

                TextField("配对端口", text: $pairPort)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 110)
                    .onChange(of: pairPort) { _, newValue in
                        let cleaned = newValue.filter { $0.isNumber }
                        if cleaned != newValue {
                            pairPort = cleaned
                        }
                    }
            }

            HStack(spacing: 10) {
                TextField("6 位配对码 (如 123456)", text: $pairingCode)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: pairingCode) { _, newValue in
                        let cleaned = newValue.filter { $0.isNumber }
                        if cleaned != newValue {
                            pairingCode = cleaned
                        }
                    }

                TextField("调试端口 (选填)", text: $debugPort)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)
                    .onChange(of: debugPort) { _, newValue in
                        let cleaned = newValue.filter { $0.isNumber }
                        if cleaned != newValue {
                            debugPort = cleaned
                        }
                    }
            }

            HStack {
                if isPairing {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在配对与连接...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    startPairing()
                } label: {
                    Text("配对并自动连接")
                }
                .buttonStyle(.borderedProminent)
                .tint(CandyTheme.syrup)
                .disabled(isPairing || pairHost.isEmpty || pairPort.isEmpty || pairingCode.isEmpty)
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12).stroke(CandyTheme.separator, lineWidth: 1)
        }
    }

    // MARK: - 4. Recent Connections Card

    @ViewBuilder
    private var recentConnectionsCard: some View {
        if !adb.recentConnections.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("最近连接记录")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Spacer()

                    Text("\(adb.recentConnections.count) 条记录")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                ForEach(adb.recentConnections) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(verbatim: "\(item.host):\(item.port)")
                                    .font(.system(size: 12, weight: .medium, design: .monospaced))

                                if let name = item.displayName, !name.isEmpty {
                                    Text(name)
                                        .font(.caption2.weight(.medium))
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(.secondary.opacity(0.1), in: Capsule())
                                }
                            }

                            Text("最近连接: \(item.lastConnectedAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button("快速连接") {
                            directHost = item.host
                            directPort = String(item.port)
                            startDirectConnect()
                        }
                        .buttonStyle(SoftButtonStyle())

                        Button {
                            adb.removeRecentConnection(host: item.host, port: item.port)
                        } label: {
                            Image(systemName: "trash")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(10)
                    .background(.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    // MARK: - Helper Methods

    private func smartParseHostAndPort(from text: String) -> (host: String, port: String?)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains(":") {
            let parts = trimmed.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                let host = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                let portCleaned = parts[1].filter { $0.isNumber }
                return (host, portCleaned.isEmpty ? nil : portCleaned)
            }
        }
        return nil
    }

    private func isDeviceConnected(_ dev: DiscoveredADBDevice) -> Bool {
        adb.devices.contains { d in
            d.isOnline && (
                (d.ip == dev.host && d.port == dev.port) ||
                (!dev.serial.isEmpty && d.serial.contains(dev.serial)) ||
                (!dev.serviceName.isEmpty && d.serial.contains(dev.serviceName))
            )
        }
    }

    private func disconnectDevice(_ dev: DiscoveredADBDevice) {
        if let matching = adb.devices.first(where: { d in
            (d.ip == dev.host && d.port == dev.port) ||
            (!dev.serial.isEmpty && d.serial.contains(dev.serial)) ||
            (!dev.serviceName.isEmpty && d.serial.contains(dev.serviceName))
        }) {
            Task { _ = await adb.disconnect(serial: matching.serial) }
        } else {
            Task { _ = await adb.disconnect(serial: "\(dev.host):\(dev.port)") }
        }
    }

    private func connectToDiscovered(_ dev: DiscoveredADBDevice) {
        isConnecting = true
        connectingTarget = "\(dev.host):\(dev.port)"
        statusMessage = nil
        isError = false

        Task {
            let res = await adb.connect(host: dev.host, port: dev.port)
            isConnecting = false
            connectingTarget = nil
            switch res {
            case .success(let output):
                statusMessage = "连接成功: \(output)"
                isError = false
            case .failure(let error):
                statusMessage = "连接失败: \(error.localizedDescription)"
                isError = true
            }
        }
    }

    private func startPairing() {
        guard let pPort = Int(pairPort.trimmingCharacters(in: .whitespaces)) else {
            statusMessage = "配对端口必须为有效数字"
            isError = true
            return
        }
        let dPort = Int(debugPort.trimmingCharacters(in: .whitespaces))

        isPairing = true
        statusMessage = nil
        isError = false

        Task {
            let res = await adb.pair(host: pairHost, port: pPort, code: pairingCode, debugPort: dPort)
            isPairing = false
            switch res {
            case .success(let output):
                statusMessage = "配对成功: \(output)"
                isError = false
            case .failure(let error):
                statusMessage = "配对失败: \(error.localizedDescription)"
                isError = true
            }
        }
    }

    private func startDirectConnect() {
        guard let port = Int(directPort.trimmingCharacters(in: .whitespaces)) else {
            statusMessage = "端口必须为有效数字"
            isError = true
            return
        }

        isConnecting = true
        statusMessage = nil
        isError = false

        Task {
            let res = await adb.connect(host: directHost, port: port)
            isConnecting = false
            switch res {
            case .success(let output):
                statusMessage = "连接应答: \(output)"
                isError = false
            case .failure(let error):
                statusMessage = "连接失败: \(error.localizedDescription)"
                isError = true
            }
        }
    }
}

// MARK: - Tab 2: Devices & Port Binding

private struct ADBDevicesTabView: View {
    let store: MonitorStore
    private var adb: ADBService { store.adbService }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("已发现的 Android 设备 (\(adb.devices.count))")
                    .font(.headline)

                Spacer()

                Button {
                    Task { await adb.refreshOnce() }
                } label: {
                    Label("刷新设备", systemImage: "arrow.clockwise")
                }
                .buttonStyle(SoftButtonStyle())
            }

            if adb.devices.isEmpty {
                ContentUnavailableView(
                    "暂未发现在线设备",
                    systemImage: "antenna.radiowaves.left.and.right.slash",
                    description: Text("请前往「配对与连接」页面配对或连接 Android 手机，或者通过 USB 数据线连接并开启 USB 调试。")
                )
                .frame(maxWidth: .infinity, minHeight: 200)
            } else {
                ForEach(adb.devices) { device in
                    ADBDeviceCard(store: store, device: device)
                }
            }
        }
    }
}

private struct ADBDeviceCard: View {
    let store: MonitorStore
    let device: ADBDevice
    private var adb: ADBService { store.adbService }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(device.displayName)
                            .font(.system(size: 15, weight: .bold))

                        if device.isOnline {
                            Text("在线")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.green)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.green.opacity(0.12), in: Capsule())
                        } else {
                            Text("离线")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.12), in: Capsule())
                        }

                        if device.hasWirelessConnection {
                            HStack(spacing: 3) {
                                Image(systemName: "wifi")
                                    .font(.system(size: 9, weight: .bold))
                                Text(device.isMDNSWireless ? "Wi-Fi 无线调试" : "Wi-Fi 无线")
                                    .font(.system(size: 10, weight: .semibold))
                            }
                            .foregroundStyle(.blue)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.blue.opacity(0.12), in: Capsule())
                        }

                        if device.hasUSBConnection {
                            HStack(spacing: 3) {
                                Image(systemName: "cable.connector")
                                    .font(.system(size: 9, weight: .semibold))
                                Text("USB 有线")
                                    .font(.system(size: 10, weight: .medium))
                            }
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.12), in: Capsule())
                        }
                    }

                    if let hw = device.hardwareSerial, !hw.isEmpty, hw != device.serial {
                        Text("序列号: \(hw) (\(device.shortAddress))")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    } else {
                        Text(device.isMDNSWireless ? "无线服务名: \(device.serial)" : "序列号 / 地址: \(device.serial)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Button("断开") {
                    Task { _ = await adb.disconnect(serial: device.serial) }
                }
                .buttonStyle(SoftButtonStyle(destructive: true))
            }

            Divider()

            // 遥测数据
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("实时电量")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        Image(systemName: "bolt.batteryblock.fill")
                            .foregroundStyle(.green)
                        Text(device.batteryPercent.map { "\(Int(round($0)))%" } ?? "-")
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("电池温度")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        Image(systemName: "thermometer.medium")
                            .foregroundStyle(.orange)
                        Text(device.batteryTempC.map { String(format: "%.1f°C", $0) } ?? "-")
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("电池电压")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(device.batteryVoltageMV.map { "\($0) mV" } ?? "-")
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("状态")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(device.batteryStatus ?? "-")
                        .font(.system(size: 13, weight: .medium))
                }
            }

            if device.isOnline {
                Divider()
                ADBDeviceRecordingPanel(store: store, device: device)
            }

            Divider()

            // 端口绑定控制
            HStack {
                Label("绑定到小电拼端口:", systemImage: "link")
                    .font(.caption.weight(.semibold))

                Picker("", selection: Binding(
                    get: { adb.boundPort(for: device.serial) ?? 0 },
                    set: { newPort in
                        if newPort == 0 {
                            if let oldPort = adb.boundPort(for: device.serial) {
                                adb.bindPort(oldPort, to: nil)
                            }
                        } else {
                            adb.bindPort(newPort, to: device.serial)
                        }
                    }
                )) {
                    Text("未绑定").tag(0)
                    ForEach(store.livePorts) { port in
                        Text("端口 \(port.port.name) (\(port.port.displayName))").tag(port.port.index)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 180)

                Spacer()

                if adb.boundPort(for: device.serial) != nil {
                    Text("充电时数据将自动融合到该端口会话")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10).stroke(CandyTheme.separator, lineWidth: 1)
        }
    }
}

private struct ADBDeviceRecordingPanel: View {
    let store: MonitorStore
    let device: ADBDevice
    @State private var customTitle: String = ""
    @State private var isShowingTitleInput: Bool = false

    private var isRecording: Bool {
        store.isRecordingStandaloneBattery(serial: device.serial)
    }

    private var activeSession: ChargingSession? {
        store.activeStandaloneSession(for: device.serial)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isRecording, let session = activeSession {
                HStack(spacing: 12) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(.green)
                            .frame(width: 8, height: 8)
                        Text("独立电量曲线记录中")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.green)
                    }

                    Spacer()

                    // 已采集样本与时长
                    TimelineView(.periodic(from: .now, by: 1.0)) { timeline in
                        let elapsed = Int(timeline.date.timeIntervalSince(session.startedAt))
                        let mins = elapsed / 60
                        let secs = elapsed % 60
                        HStack(spacing: 4) {
                            Image(systemName: "timer")
                                .font(.caption2)
                            Text(String(format: "%02d:%02d", mins, secs))
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        }
                        .foregroundStyle(.secondary)
                    }

                    Text("已采 \(session.sampleCount) 点")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)

                    Button("查看曲线") {
                        store.selectedSection = .sessions
                        store.selectSession(session)
                    }
                    .buttonStyle(SoftButtonStyle())

                    Button("结束记录") {
                        store.stopStandaloneBatteryRecording(serial: device.serial)
                    }
                    .buttonStyle(SoftButtonStyle(destructive: true))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "bolt.badge.clock")
                        .font(.system(size: 13))
                        .foregroundStyle(CandyTheme.syrup)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("独立电量曲线记录")
                            .font(.system(size: 12, weight: .semibold))
                        Text("无需连接小电拼充电口，直接以 1Hz 记录该手机电量、电压与温度变化")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if isShowingTitleInput {
                        TextField("测试备注 (选填)", text: $customTitle)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 130)
                    } else {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                isShowingTitleInput = true
                            }
                        } label: {
                            Image(systemName: "pencil")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("添加测试备注")
                    }

                    Button {
                        store.startStandaloneBatteryRecording(device: device, customTitle: customTitle.isEmpty ? nil : customTitle)
                        customTitle = ""
                        isShowingTitleInput = false
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "record.circle")
                            Text("开始记录")
                        }
                        .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(CandyTheme.syrup)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}

// MARK: - Tab 3: Environment & Diagnostics

private struct ADBEnvironmentTabView: View {
    let store: MonitorStore
    @State private var customPathInput: String = ""
    @State private var copiedNotice: Bool = false
    @State private var copiedUpgradeNotice: Bool = false

    private var adb: ADBService { store.adbService }
    private var updateChecker: ADBUpdateChecker { adb.updateChecker }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // 1. Server Status Card
            serverStatusCard

            // 2. Version & Update Detection Card
            versionUpdateCard

            // 3. Tool Installation & Path Configuration Card
            toolInstallationCard
        }
        .onAppear {
            customPathInput = adb.customADBPath
            Task {
                await updateChecker.checkForUpdates(installedVersion: adb.detectedPlatformToolsVersion)
            }
        }
    }

    // MARK: - 1. Server Status Card

    private var serverStatusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("ADB 服务状态 (127.0.0.1:5037)", systemImage: "network")
                    .font(.headline)
                Spacer()
                StatusPill(
                    text: adb.serverState.statusDescription,
                    color: adb.serverState.isReady ? .green : .orange
                )
            }

            if adb.serverState.isReady {
                HStack {
                    Text("纯原生 Swift TCP 通信已就绪，App 已与系统 ADB 守护进程连接，轮询开销极低。")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button {
                        adb.restartServer()
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.clockwise")
                            Text("重启守护进程")
                        }
                        .font(.caption)
                    }
                    .buttonStyle(SoftButtonStyle())
                }
            } else {
                Text("未检测到 127.0.0.1:5037 处的 ADB Server 守护进程。")
                    .font(.caption)
                    .foregroundStyle(.red)

                HStack(spacing: 10) {
                    Button("尝试启动 ADB 服务") {
                        adb.tryStartServer()
                    }
                    .buttonStyle(.borderedProminent)

                    Button("重新检测") {
                        adb.checkEnvironment()
                    }
                    .buttonStyle(SoftButtonStyle())
                }
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12).stroke(CandyTheme.separator, lineWidth: 1)
        }
    }

    // MARK: - 2. Version & Update Detection Card

    private var versionUpdateCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header
            HStack(spacing: 10) {
                Label("ADB 版本与更新检测", systemImage: "arrow.triangle.2.circlepath.circle")
                    .font(.headline)

                Spacer()

                // 状态徽章
                switch updateChecker.status {
                case .checking:
                    HStack(spacing: 5) {
                        ProgressView()
                            .controlSize(.small)
                        Text("正在检测...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                case .upToDate(let ver):
                    StatusPill(text: "✓ 已是最新版本 (v\(ver))", color: .green)
                case .updateAvailable(_, let latest, _, _):
                    StatusPill(text: "发现新版本 v\(latest)", color: CandyTheme.syrup)
                case .failed:
                    StatusPill(text: "检测失败", color: .red)
                case .idle:
                    StatusPill(text: "就绪", color: .secondary)
                }

                // 检查更新按钮
                Button {
                    Task {
                        await updateChecker.checkForUpdates(
                            installedVersion: adb.detectedPlatformToolsVersion,
                            force: true
                        )
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                        Text("检查更新")
                    }
                    .font(.caption.weight(.medium))
                }
                .buttonStyle(SoftButtonStyle())
                .disabled(updateChecker.status.isChecking)
            }

            Divider()

            // 版本对照网格
            HStack(alignment: .top, spacing: 24) {
                // 本地当前版本
                VStack(alignment: .leading, spacing: 6) {
                    Text("当前已安装版本")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)

                    if let ver = adb.detectedPlatformToolsVersion {
                        HStack(spacing: 6) {
                            Text("Platform-Tools v\(ver)")
                                .font(.system(size: 14, weight: .bold, design: .monospaced))
                            StatusPill(text: "已定位", color: .blue)
                        }
                    } else if case .running(let proto) = adb.serverState {
                        HStack(spacing: 6) {
                            Text("ADB Server 协议 v\(proto)")
                                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            StatusPill(text: "1.0.\(proto)", color: .secondary)
                        }
                    } else {
                        Text("待指定可执行程序路径")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    if case .running(let proto) = adb.serverState, adb.detectedPlatformToolsVersion != nil {
                        Text("守护进程协议: 1.0.\(proto) (v\(proto))")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // 云端最新版本
                VStack(alignment: .leading, spacing: 6) {
                    Text("官方最新可用版本")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)

                    if let latest = updateChecker.latestVersion {
                        HStack(spacing: 6) {
                            Text("Platform-Tools v\(latest)")
                                .font(.system(size: 14, weight: .bold, design: .monospaced))
                                .foregroundStyle(CandyTheme.syrup)
                            Text("Google 官方发布")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    } else if updateChecker.status.isChecking {
                        Text("正在获取官方版本...")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("点击右上角「检查更新」拉取")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Text("来源: Google Developer / Homebrew Cask")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // 若检测到系统中另有已安装的更新版本，提示一键切换
            if let alt = adb.latestAlternativeInstallation {
                HStack(spacing: 12) {
                    Image(systemName: "sparkles")
                        .font(.title3)
                        .foregroundStyle(CandyTheme.syrup)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("检测到系统已安装更高版本的 ADB")
                            .font(.subheadline.weight(.bold))
                        Text("位置: \(alt.path)\(alt.version.map { " (v\($0))" } ?? "")")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button {
                        adb.switchToInstallation(alt)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                            Text("一键切换至此版本 (v\(alt.version ?? ""))")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(CandyTheme.syrup)
                }
                .padding(12)
                .background(CandyTheme.syrup.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            }

            // 更新提示与升级操作区
            if case .updateAvailable(let current, let latest, let notesURL, let dlURL) = updateChecker.status {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.up.circle.fill")
                            .foregroundStyle(CandyTheme.syrup)
                        Text(current != nil ? "检测到 Google 官方已发布更新版本的 Platform-Tools (当前 v\(current!) → 最新 v\(latest))" : "检测到 Google 官方已发布最新的 Platform-Tools v\(latest)，建议升级以获得最佳兼容性。")
                            .font(.caption.weight(.medium))
                    }

                    // 一键自动升级与命令操作条
                    HStack(spacing: 10) {
                        // 一键自动执行升级（主按钮）
                        Button {
                            adb.runOneClickUpgrade()
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "bolt.fill")
                                Text("一键自动执行升级")
                                    .font(.subheadline.weight(.semibold))
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(CandyTheme.syrup)

                        // 复制升级命令辅助按钮
                        Button(copiedUpgradeNotice ? "已复制升级命令" : "复制升级命令") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString("brew upgrade android-platform-tools", forType: .string)
                            copiedUpgradeNotice = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                copiedUpgradeNotice = false
                            }
                        }
                        .buttonStyle(SoftButtonStyle())

                        Spacer()

                        if let notes = notesURL {
                            Button {
                                NSWorkspace.shared.open(notes)
                            } label: {
                                Label("发行说明", systemImage: "arrow.up.right.square")
                                    .font(.caption)
                            }
                            .buttonStyle(SoftButtonStyle())
                        }

                        if let dl = dlURL {
                            Button {
                                NSWorkspace.shared.open(dl)
                            } label: {
                                Label("官方下载", systemImage: "arrow.down.circle")
                                    .font(.caption)
                            }
                            .buttonStyle(SoftButtonStyle())
                        }
                    }

                    Text("点击「一键自动执行升级」将自动唤起系统终端执行 Homebrew 升级并重启守护进程，无需手动输入。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(12)
                .background(CandyTheme.syrup.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            } else if case .upToDate = updateChecker.status {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                    Text("您的 ADB 工具组件已是最新版本，具备最优的无线调试与长时时序采样稳定性。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            } else if case .failed(let msg) = updateChecker.status {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("更新检测失败: \(msg)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // 底部元数据小注
            HStack {
                if let checked = updateChecker.lastCheckedAt {
                    Text("上次检测: \(checked.formatted(date: .omitted, time: .standard))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Link("Android SDK Platform-Tools 发行说明", destination: ADBUpdateChecker.officialReleaseNotesURL)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12).stroke(CandyTheme.separator, lineWidth: 1)
        }
    }

    // MARK: - 3. Tool Installation & Path Configuration Card

    private var toolInstallationCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("ADB 工具安装与路径配置", systemImage: "wrench.and.screwdriver")
                .font(.headline)

            if let path = adb.detectedADBPath {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("已定位 adb 可执行程序: \(path)")
                        .font(.caption.monospaced())

                    if let ver = adb.detectedPlatformToolsVersion {
                        StatusPill(text: "v\(ver)", color: .blue)
                    }
                }
            } else {
                Text("如果您的 Mac 尚未安装 Android 调试工具，可通过 Homebrew 快速安装：")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Text("brew install android-platform-tools")
                        .font(.system(size: 12, design: .monospaced))
                        .padding(8)
                        .background(.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))

                    Button(copiedNotice ? "已复制" : "复制命令") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("brew install android-platform-tools", forType: .string)
                        copiedNotice = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            copiedNotice = false
                        }
                    }
                    .buttonStyle(SoftButtonStyle())
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("自定义 ADB 执行程序路径 (选填)")
                    .font(.subheadline.weight(.semibold))

                HStack(spacing: 8) {
                    TextField("如 /opt/homebrew/bin/adb 或 ~/android-sdk/platform-tools/adb", text: $customPathInput)
                        .textFieldStyle(.roundedBorder)

                    Button("浏览选择...") {
                        selectExecutableFile()
                    }
                    .buttonStyle(SoftButtonStyle())

                    Button("保存并测试") {
                        adb.customADBPath = customPathInput.trimmingCharacters(in: .whitespacesAndNewlines)
                        adb.checkEnvironment()
                    }
                    .buttonStyle(.bordered)
                }

                Text("支持选择 adb 执行文件或软链接，沙盒将自动记忆读取权限。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12).stroke(CandyTheme.separator, lineWidth: 1)
        }
    }

    private func selectExecutableFile() {
        let panel = NSOpenPanel()
        panel.title = "选择 ADB 可执行程序"
        panel.prompt = "选择"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false

        if let window = NSApplication.shared.windows.first(where: { $0.isKeyWindow }) {
            panel.beginSheetModal(for: window) { response in
                if response == .OK, let selectedURL = panel.url {
                    customPathInput = selectedURL.path
                    adb.setCustomADBExecutableURL(selectedURL)
                }
            }
        } else {
            if panel.runModal() == .OK, let selectedURL = panel.url {
                customPathInput = selectedURL.path
                adb.setCustomADBExecutableURL(selectedURL)
            }
        }
    }
}

// MARK: - Wireless ADB Dedicated Console View (Full Page for AppSection)

struct WirelessADBConsoleView: View {
    let store: MonitorStore
    @State private var selectedTab: ADBSheetTab = .pair

    enum ADBSheetTab: String, CaseIterable, Identifiable {
        case pair = "配对与连接"
        case devices = "在线设备与绑定"
        case environment = "环境检测"

        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar(title: "无线调试", subtitle: "Android Wireless ADB · 电池电量与温度采样") {
                HStack(spacing: 8) {
                    Button {
                        store.adbService.restartServer()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.clockwise")
                            Text("重启 ADB 服务")
                        }
                        .font(.caption)
                    }
                    .buttonStyle(SoftButtonStyle())
                    .help("重启本地 ADB 守护进程并重置路由缓存")

                    SyncStatusView(date: store.lastRefreshedAt, isRefreshing: store.isRefreshingNow)
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // 顶部主控设备与电池概览卡片
                    topOverviewCard

                    // 分栏选择器
                    Picker("", selection: $selectedTab) {
                        ForEach(ADBSheetTab.allCases) { tab in
                            Text(tab.rawValue).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.vertical, 4)

                    // Tab 内容区
                    switch selectedTab {
                    case .pair:
                        ADBPairingTabView(store: store)
                    case .devices:
                        ADBDevicesTabView(store: store)
                    case .environment:
                        ADBEnvironmentTabView(store: store)
                    }
                }
                .padding(24)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var topOverviewCard: some View {
        let adb = store.adbService
        let devices = adb.devices

        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(devices.isEmpty ? .secondary : CandyTheme.syrup)
                    .frame(width: 40, height: 40)
                    .background((devices.isEmpty ? Color.secondary : CandyTheme.syrup).opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(devices.isEmpty ? "未连接 Android 调试设备" : "已连接 \(devices.count) 台 Android 调试设备")
                            .font(.title3.weight(.bold))

                        if !devices.isEmpty {
                            StatusPill(text: "1Hz 采样中", color: .green)
                            if devices.contains(where: { store.isRecordingStandaloneBattery(serial: $0.serial) }) {
                                StatusPill(text: "电量记录中", color: CandyTheme.syrup)
                            }
                        } else {
                            StatusPill(text: adb.serverState.statusDescription, color: adb.serverState.isReady ? .orange : .secondary)
                        }

                        if !adb.discoveredLANDevices.isEmpty {
                            StatusPill(text: "局域网发现 \(adb.discoveredLANDevices.count) 台", color: .blue)
                        }
                    }

                    Text(devices.isEmpty ? "通过 WiFi 局域网配对并连接手机后，可实时采集电量百分比、电池电压 (mV) 与温度 (℃)" : "已与小电拼采样系统共用时间基准，可直接在「在线设备与绑定」中将手机与充电口关联")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }

            if let firstDev = devices.first(where: { $0.isOnline }) ?? devices.first {
                Divider()

                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("当前主控设备")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(firstDev.displayName)
                            .font(.headline)
                    }

                    Spacer()

                    if let percent = firstDev.batteryPercent {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("电池电量")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(String(format: "%.0f%%", percent))
                                .font(.headline.weight(.bold).monospacedDigit())
                                .foregroundStyle(.green)
                        }
                    }

                    if let volt = firstDev.batteryVoltageMV {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("电池电压")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(String(format: "%.3f V", Double(volt) / 1000.0))
                                .font(.headline.monospacedDigit())
                        }
                    }

                    if let temp = firstDev.batteryTempC {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("电池温度")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(String(format: "%.1f ℃", temp))
                                .font(.headline.monospacedDigit())
                                .foregroundStyle(temp > 40 ? .red : (temp > 35 ? .orange : .primary))
                        }
                    }

                    if let bound = adb.boundPort(for: firstDev.serial) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("绑定端口")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(LocalizedTelemetry.portName(bound))
                                .font(.headline)
                                .foregroundStyle(CandyTheme.syrup)
                        }
                    }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        }
    }
}

