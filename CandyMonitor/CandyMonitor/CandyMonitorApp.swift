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
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 1180, height: 760)
        .modelContainer(for: [
            MirrorDevice.self,
            ChargingSession.self,
            PortSample.self,
            ControlEvent.self
        ])
    }
}
