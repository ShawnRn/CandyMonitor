# CandyMonitor Agent Notes

## Project Shape

- `CandyMonitor/CandyMonitor.xcodeproj` is the Xcode project.
- `CandyMonitor/CandyMonitor/ContentView.swift` currently contains the main SwiftUI surface, including sidebar, monitor dashboard, port detail sheet, sessions, control console, and settings.
- `CandyMonitor/CandyMonitor/Models/DomainModels.swift` contains SwiftData models, MCP response models, and UI view-state structs.
- `CandyMonitor/CandyMonitor/Services/` contains MCP networking, persistence orchestration, CSV export, and local encrypted credential storage.
- `CandyMonitor/CandyMonitor/Assets.xcassets/Mirror4C1ADevice.imageset/` contains the trimmed product render used in the topology panel.

## Build And Run

Use the project root as the working directory:

```bash
xcodebuild -project CandyMonitor/CandyMonitor.xcodeproj -scheme CandyMonitor -configuration Debug build
```

Run the latest Debug app:

```bash
APP_PATH=$(xcodebuild -showBuildSettings -project CandyMonitor/CandyMonitor.xcodeproj -scheme CandyMonitor -configuration Debug 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR = / {print $2; exit}')/CandyMonitor.app
open -n "$APP_PATH"
```

For release artifacts:

```bash
./scripts/build.sh release
```

The release script creates separate DMGs for `arm64` and `x86_64` under `releases/`.

## MCP State Semantics

- `PortDetail.connected` means a load/device is detected on the port.
- `ChargingStatus.status_bitmask` means ports currently charging, not whether a port is enabled.
- The mini-program uses `portsStatus[portId].enable` for the actual port switch. The current MCP wrapper does not expose that field. If MCP starts returning `enable` in `get_port_details`, `PortViewState.portSwitchState` will use it automatically.
- Do not infer port switch state from voltage, power, `connected`, or `status_bitmask`; Type-C ports can be enabled while idle and still show tiny VBUS readings.
- If `enable` is absent, keep port switch controls hidden in the UI instead of offering speculative open/close actions.
- Fast-charge protocol labels should match the mini-program's `FAST_CHARGE_PROTOCOL_MAP` display: strip the `FC_` prefix for standard enum names such as `PD_FIXHV` and `PD_PPS`, keep `NOT_CHARGING`/`NONE`, and only translate `FC_PD_MI_PPS`/value `21` to `小米澎湃秒充`.
- PD battery/device fields should accept the mini-program WebSocket key names where available, including `batteryDesignCapacity`, `batteryLastFullChargeCapacity`, `batteryPresentCapacity`, `capacityPercent`, `batteryHealth`, and `remainingTimeStr`.
- The mini-program same-origin PD status stream is `wss://iot-gateway.minapp.com/ws/cp-02/v2/stats/?t=<iot-jwt>` with service `130` / payload key `stream_port_pd_status`. The app connects to this stream through `CandyIOTPDStatusClient` when an IOT WS JWT is available, normalizes zero-based mini-program port ids to the app's one-based ports, then merges those fields over MCP `get_port_pd_status`.
- The short token in an MCP SSE URL is not the IOT WS JWT. The mini-program normally obtains the WS JWT from its BaaS `iotgw-jwt` endpoint after login. CandyMonitor stores an optional IOT WS JWT in the encrypted local vault next to the MCP URL and may auto-save one only if a future MCP wrapper exposes a JWT helper tool. If no JWT is present or the WS is unavailable, keep using MCP `get_port_pd_status` as a fallback instead of dropping PD UI data.
- Do not persist the IOT WS JWT in SwiftData, logs, release notes, screenshots, or GitHub issues. Do not delete the MCP/WS encrypted vault while debugging missing battery data unless the user explicitly asks to reset connection credentials.

## Charging Session Semantics

- At most one unfinished `ChargingSession` may exist for the same `(deviceID, portIndex)`. Do not rely only on the in-memory `activeSessions` dictionary for this invariant; app reloads, polling restarts, or old dirty data can leave multiple unfinished rows in SwiftData.
- Before creating a new charging session, check SwiftData for an existing unfinished session on that device and port. If duplicates are found, keep the earliest active session as canonical, move duplicate `PortSample.sessionID` values to it, recompute statistics from samples, then delete the duplicate session rows.
- When adding session recording logic, preserve the healing path in `MonitorStore.loadSessions()` and `recordSamples(...)` so existing duplicate rows are cleaned automatically instead of merely hidden in the UI.
- A duplicate active-session fix must not delete samples. Historical curves should be merged into the canonical session whenever possible.

## UI Conventions

- The app accent is `CandyTheme.syrup`, matching the orange used by the 小电拼 UI.
- The selected device row in the sidebar intentionally uses neutral gray, while selected functional navigation uses the orange accent.
- Keep topology compact and dashboard-like. Avoid large decorative cards that reduce useful density.
- The product topology should use the real `Mirror4C1ADevice` raster asset unless there is a specific reason to rebuild the illustration.

## Release Workflow

Follow the MotrixMac-style order:

1. Commit and push source changes first.
2. Build both architecture DMGs with `./scripts/build.sh release`.
3. Create a GitHub Release and upload both DMGs.

Do not commit local decompile caches, `.agent`, `releases/`, or DerivedData output.

## Persistence And Entitlement Safety

- CandyMonitor is a sandboxed macOS app. User data lives in the app container, especially `~/Library/Containers/com.shawnrain.CandyMonitor/Data/Library/Application Support/default.store` for SwiftData and `~/Library/Containers/com.shawnrain.CandyMonitor/Data/Library/Application Support/CandyMonitor/` for the device registry and encrypted MCP vault.
- The encrypted vault also stores the optional mini-program IOT WS JWT for PD status. Preserving sandbox entitlements preserves both the MCP URL and this WS credential path.
- Never re-sign a release app without `CandyMonitor/CandyMonitor/CandyMonitor.entitlements`. Dropping `com.apple.security.app-sandbox=true` makes the app read non-sandbox `~/Library/Application Support/default.store`, which looks like all devices and charging history disappeared even though the sandbox data still exists.
- `scripts/build.sh` must keep its post-signing entitlement verification. Do not remove the `codesign --verify` and `com.apple.security.app-sandbox` checks.
- Before publishing or locally installing a release build, verify the exact app bundle that will be shipped or copied:

```bash
codesign -d --entitlements :- .build/apps/CandyMonitor_arm64.app 2>/dev/null | grep -A1 com.apple.security.app-sandbox
codesign --verify --deep --strict --verbose=2 .build/apps/CandyMonitor_arm64.app
```

- If an installed build opens with an empty sidebar after an update, check entitlement state before touching data. The old data is usually still in the sandbox container; do not delete either `default.store` location while diagnosing.
