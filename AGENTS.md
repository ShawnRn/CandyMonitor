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
- Never re-sign a release app without `CandyMonitor/CandyMonitor/CandyMonitor.entitlements`. Dropping `com.apple.security.app-sandbox=true` makes the app read non-sandbox `~/Library/Application Support/default.store`, which looks like all devices and charging history disappeared even though the sandbox data still exists.
- `scripts/build.sh` must keep its post-signing entitlement verification. Do not remove the `codesign --verify` and `com.apple.security.app-sandbox` checks.
- Before publishing or locally installing a release build, verify the exact app bundle that will be shipped or copied:

```bash
codesign -d --entitlements :- .build/apps/CandyMonitor_arm64.app 2>/dev/null | grep -A1 com.apple.security.app-sandbox
codesign --verify --deep --strict --verbose=2 .build/apps/CandyMonitor_arm64.app
```

- If an installed build opens with an empty sidebar after an update, check entitlement state before touching data. The old data is usually still in the sandbox container; do not delete either `default.store` location while diagnosing.
