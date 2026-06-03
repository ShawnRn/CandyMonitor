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
    @State private var store = MonitorStore()

    var body: some Scene {
        Window("CandyMonitor", id: "main") {
            ContentView(store: store)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 1180, height: 760)
        .modelContainer(for: [
            MirrorDevice.self,
            ChargingSession.self,
            PortSample.self,
            ControlEvent.self
        ])

        MenuBarExtra {
            CandyMenuBarView(store: store)
        } label: {
            MenuBarStatusLabel(store: store)
        }
        .menuBarExtraStyle(.window)
        .modelContainer(for: [
            MirrorDevice.self,
            ChargingSession.self,
            PortSample.self,
            ControlEvent.self
        ])
    }
}

final class CandyMonitorAppDelegate: NSObject, NSApplicationDelegate {
    private let showInDockKey = "showInDock"
    private var lastShowInDock: Bool?
    var updaterController: SPUStandardUpdaterController?
    private var isStartupPhase = true

    override init() {
        super.init()
        self.updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
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

        // 如果开启了 Dock 显示，就在启动时发送通知打开主窗口
        if UserDefaults.standard.bool(forKey: showInDockKey) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                NotificationCenter.default.post(name: NSNotification.Name("OpenMainWindow"), object: nil)
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
}
