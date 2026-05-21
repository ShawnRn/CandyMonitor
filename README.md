# CandyMonitor

CandyMonitor is a native macOS monitor and control panel for CoCan Mirror / 小电拼 devices. It connects to the device MCP SSE endpoint, reads live port telemetry, records charging sessions locally, and presents a macOS-style dashboard inspired by the original mini-program experience.

> This repository is intended for internal analysis and native macOS workflow exploration.

## Highlights

- Native SwiftUI interface with macOS sidebar, toolbar, sheets, and segmented controls.
- Live power topology for 4C1A 小电拼 devices.
- Per-port voltage, current, power, protocol, temperature, and battery telemetry where available.
- Local SwiftData storage for charging sessions and samples.
- CSV export for charging records.
- Control console for charging strategy, temperature mode, port operations, temporary power allocation, and cable compensation.
- Real product imagery extracted and prepared for the topology panel.

## Requirements

- macOS 14.0 or later
- Xcode 16 or later recommended
- A reachable CandySign MCP SSE endpoint for the target device

## Build

From the repository root:

```bash
xcodebuild -project CandyMonitor/CandyMonitor.xcodeproj -scheme CandyMonitor -configuration Debug build
```

Release DMGs for both architectures:

```bash
./scripts/build.sh release
```

Artifacts are written to:

```text
releases/CandyMonitor_<version>_arm64.dmg
releases/CandyMonitor_<version>_x86_64.dmg
```

## Device Setup

1. Launch CandyMonitor.
2. Click the add button in the toolbar.
3. Enter a device name and MCP SSE URL.
4. Optionally paste the mini-program IOT WS JWT to enable same-origin `stream_port_pd_status` PD battery data.
5. CandyMonitor validates the endpoint before saving it to the local encrypted app store.

CandyMonitor is sandboxed. MCP URLs are stored under the app container's `Library/Application Support/CandyMonitor/mcp-vault/` directory as AES-GCM encrypted, lightly obfuscated files. They are not written to SwiftData or the macOS keychain.

PD status uses two sources. MCP `get_port_pd_status` is always the fallback. When an IOT WS JWT is configured, CandyMonitor also connects to the mini-program source stream at `wss://iot-gateway.minapp.com/ws/cp-02/v2/stats/`, listens for service `130` / `stream_port_pd_status`, normalizes its port ids, and prefers those battery fields over MCP values.

Charging sessions are unique by device and port while they are active. If a previous build or a polling restart leaves multiple unfinished rows for the same port, CandyMonitor keeps the earliest active session, moves duplicate samples into it, recomputes the summary, and removes the duplicate rows without deleting curve data.

## Release Workflow

This project follows the same high-level flow as MotrixMac:

1. Commit and push source code.
2. Build release DMGs:
   ```bash
   ./scripts/build.sh release
   ```
3. Verify the packaged app still has the sandbox entitlement before uploading. A release signed without `com.apple.security.app-sandbox=true` will read a different data container and appear to lose all local devices and history:
   ```bash
   codesign -d --entitlements :- .build/apps/CandyMonitor_arm64.app 2>/dev/null | grep -A1 com.apple.security.app-sandbox
   codesign --verify --deep --strict --verbose=2 .build/apps/CandyMonitor_arm64.app
   ```
4. Create a GitHub Release and upload both DMGs:
   ```bash
   VERSION=1.0
   gh release create "v$VERSION" \
     "releases/CandyMonitor_${VERSION}_arm64.dmg" \
     "releases/CandyMonitor_${VERSION}_x86_64.dmg" \
     --title "CandyMonitor $VERSION" \
     --notes-file RELEASE_NOTES.md
   ```

## Notes

- `connected` means a device/load is detected on a port.
- `status_bitmask` from MCP means a port is currently charging.
- Port switch state requires an `enable` field from the device status stream. If the MCP endpoint does not expose it, CandyMonitor hides port switch controls and only shows live telemetry.
