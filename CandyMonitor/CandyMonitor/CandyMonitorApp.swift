//
//  CandyMonitorApp.swift
//  CandyMonitor
//
//  Created by Shawn Rain on 2026/5/20.
//

import SwiftUI
import SwiftData

@main
struct CandyMonitorApp: App {
    @State private var store = MonitorStore()

    var body: some Scene {
        WindowGroup("CandyMonitor", id: "main") {
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
            MenuBarPowerLabel(totalPowerW: store.totalPowerW, connectionState: store.connectionState)
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
