## DISCLAIMER

This projects source code will not be released until the app I'm currently developing is released. DO NOT ASK FOR IT.

This is a fan-made project with original source code. I am not affiliated with Toys-For-Bob, Activision, or any other parties involved with
making the hardware, software, or anything else related to the Skylanders franchise.

# SkylandersPortalSDK

This is a Swift 6 SDK for communicating with the official **Skylanders Trap Team Bluetooth Portal** on iOS and iPadOS 18+.

Built by Vinny "PAK-VIN" Stark with AI tools to help future Skylanders reverse-engineering work.

# Future development plans

* I am going to eventually add support for Disney Infinity figures.
* I also plan on adding support for writing back to figures.

## Features

- **Layered architecture** — Bluetooth, Protocol, Figure, and Public API layers
- **Swift 6** with strict concurrency (`async`/`await`, actors, `@MainActor`)
- **SwiftUI integration** — `ObservableObject` portal manager and sample views
- **Figure dump engine** — Read all 64 memory blocks (0x00–0x3F) with JSON, hex, and text export
- **Extensible packet parser** — Pluggable handlers for unknown protocol behavior
- **Debug utilities** — Packet inspector, BLE event logger, live console, diagnostic reports

## Installation

Add the package to your Xcode project or `Package.swift`:

```swift
dependencies: [
    .package(path: "../SkylandersPortalSDK")
]
```

## Quick Start

```swift
import SkylandersPortalSDK

@MainActor
final class PortalViewModel: ObservableObject {
    let portal = Portal()

    func connect() async {
        await portal.scanForPortal()
        try? await portal.connect()
    }

    func setRed() async throws {
        try await portal.setColor(.red)
    }
}
```

## SwiftUI Views

Import `SkylandersPortalSDKUI` for pre-built views:

```swift
import SkylandersPortalSDKUI

struct ContentView: View {
    @StateObject private var portal = Portal()

    var body: some View {
        NavigationStack {
            PortalDashboardView(portal: portal)
        }
    }
}
```

## Bluetooth Details

| Property | UUID |
|----------|------|
| Service | `1D283B8B-F2E0-94A0-EC5D-EEEA6C0C7DDD` |
| Characteristic | `533E1542-3ABE-F33F-CD00-594E8B0A8EA3` |

## Commands

| Command | Format | Example |
|---------|--------|---------|
| Color | `43 R G B 00 00` | Red: `43 FF 00 00 00 00` |
| Read Block | `51 10 [index]` | Block 0: `51 10 00` |

## Architecture

```
SkylandersPortalSDK/
├── Bluetooth/     CoreBluetooth scanning, connection, read/write/notify
├── Protocol/      Packet encoding/decoding, parser, statistics, logging
├── Figure/        Block models, session assembly, dump engine, memory map
├── Public/        Portal API, export, debug utilities
└── Internal/      Coordinator wiring layers together
```

## Requirements

- iOS 18.0+ / iPadOS 18.0+
- Swift 6.0+
- Xcode 16.0+
- Bluetooth permission in `Info.plist`: `NSBluetoothAlwaysUsageDescription`

## License

MIT
