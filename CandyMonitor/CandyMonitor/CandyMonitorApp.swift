//
//  CandyMonitorApp.swift
//  CandyMonitor
//
//  Created by Shawn Rain on 2026/5/20.
//

import SwiftUI
import SwiftData
import AppKit
import Sparkle

@main
struct CandyMonitorApp: App {
    @NSApplicationDelegateAdaptor(CandyMonitorAppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("CandyMonitor", id: "main") {
            ContentView(store: appDelegate.store)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 1180, height: 760)
        .modelContainer(appDelegate.modelContainer)
    }
}

final class CandyMonitorAppDelegate: NSObject, NSApplicationDelegate {
    let store = MonitorStore()
    let modelContainer: ModelContainer
    private let showInDockKey = "showInDock"
    private var lastShowInDock: Bool?
    var updaterController: SPUStandardUpdaterController?
    private var isStartupPhase = true
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
 
    override init() {
        do {
            let container = try ModelContainer(for: MirrorDevice.self, ChargingSession.self, PortSample.self, ControlEvent.self)
            self.modelContainer = container
        } catch {
            fatalError("Failed to initialize SwiftData ModelContainer: \(error)")
        }
        
        super.init()
        self.updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        
        // Configure store immediately using the mainContext of the strongly held container
        store.configure(modelContext: modelContainer.mainContext)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        ProcessInfo.processInfo.disableSuddenTermination()
        if UserDefaults.standard.object(forKey: showInDockKey) == nil {
            UserDefaults.standard.set(true, forKey: showInDockKey)
        }
        
        updateDockPolicy(restoringVisibleWindows: false)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(dockPreferenceChanged),
            name: UserDefaults.didChangeNotification,
            object: nil
        )
        
        setupMenuBar()

        // 如果开启了 Dock 显示，就在启动时确保主窗口打开
        if UserDefaults.standard.bool(forKey: showInDockKey) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                self?.openMainWindow()
            }
        }

        // 启动 1 秒后结束启动阶段，允许后续正常的用户或系统级退出
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.isStartupPhase = false
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if isStartupPhase {
            return .terminateCancel
        }
        return .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            openMainWindow()
        }
        return true
    }

    private func openMainWindow() {
        if let window = NSApp.windows.first(where: { $0.title == "CandyMonitor" }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            // For SwiftUI Window scenes that were closed, use standard NSApp sendAction to reopen
            NSApp.sendAction(Selector(("showWindow:")), to: nil, from: nil)
        }
    }

    @objc private func dockPreferenceChanged() {
        DispatchQueue.main.async { [weak self] in
            self?.updateDockPolicy(restoringVisibleWindows: true)
        }
    }

    private func updateDockPolicy(restoringVisibleWindows shouldRestoreWindows: Bool) {
        let showInDock = UserDefaults.standard.bool(forKey: showInDockKey)
        let targetPolicy: NSApplication.ActivationPolicy = showInDock ? .regular : .accessory
        let policyNeedsChange = NSApp.activationPolicy() != targetPolicy
        let preferenceChanged = lastShowInDock != showInDock
        guard policyNeedsChange || preferenceChanged else { return }
        lastShowInDock = showInDock

        let visibleWindows = NSApp.windows.filter { window in
            window.isVisible && window.canBecomeMain && window.styleMask.contains(.titled)
        }

        if policyNeedsChange {
            NSApp.setActivationPolicy(targetPolicy)
        }

        DispatchQueue.main.async {
            if showInDock {
                NSApp.activate(ignoringOtherApps: true)
            } else if shouldRestoreWindows {
                self.restoreWindows(visibleWindows)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    self.restoreWindows(visibleWindows)
                }
            }
        }
    }

    private func restoreWindows(_ windows: [NSWindow]) {
        NSApp.unhide(nil)
        for window in windows {
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.image = renderedCandyPowerImage(totalPowerW: store.totalPowerW)
            button.action = #selector(togglePopover(_:))
            button.target = self
        }

        // 定时 1 秒更新菜单栏电量渲染图
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self, let button = self.statusItem?.button else { return }
            button.image = self.renderedCandyPowerImage(totalPowerW: self.store.totalPowerW)
        }
    }

    private func renderedCandyPowerImage(totalPowerW: Double) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black
        ]
        
        let iconSize = NSSize(width: 20, height: 12)
        let height: CGFloat = 18
        
        if totalPowerW > 0.0 {
            let powerText: String
            if totalPowerW >= 100 {
                powerText = "\(Int(totalPowerW.rounded()))W"
            } else {
                powerText = String(format: "%.1fW", totalPowerW)
            }
            
            let text = powerText as NSString
            let textSize = text.size(withAttributes: attributes)
            let spacing: CGFloat = 5
            let width = ceil(iconSize.width + spacing + textSize.width)
            let image = NSImage(size: NSSize(width: width, height: height))

            image.lockFocus()
            NSColor.clear.setFill()
            NSRect(origin: .zero, size: image.size).fill()

            if let icon = NSImage(named: "CandyMenuBarIconBlack") {
                icon.draw(in: NSRect(
                    x: 0,
                    y: floor((height - iconSize.height) / 2) + 1,
                    width: iconSize.width,
                    height: iconSize.height
                ))
            }

            text.draw(at: NSPoint(
                x: iconSize.width + spacing,
                y: floor((height - textSize.height) / 2) + 1
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

            if let icon = NSImage(named: "CandyMenuBarIconBlack") {
                icon.draw(in: NSRect(
                    x: 0,
                    y: floor((height - iconSize.height) / 2) + 1,
                    width: iconSize.width,
                    height: iconSize.height
                ))
            }

            image.unlockFocus()
            image.isTemplate = true
            return image
        }
    }

    @objc private func togglePopover(_ sender: AnyObject?) {
        guard let button = statusItem?.button else { return }
        if popover == nil {
            let view = CandyMenuBarView(store: store)
                .modelContainer(modelContainer)
            let popover = NSPopover()
            popover.contentSize = NSSize(width: 390, height: 500)
            popover.behavior = .transient
            popover.contentViewController = NSHostingController(rootView: view)
            self.popover = popover
        }
        
        if popover?.isShown == true {
            popover?.performClose(sender)
        } else {
            popover?.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
