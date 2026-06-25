## PcsuiteMirror 0.0.1

First public build. A SwiftUI macOS menu-bar app that mirrors and controls an
Android (vivo) phone over USB or Wi-Fi, wrapping the pure-Rust `pcsuite` core.

### Features
- **Screen mirroring** — VideoToolbox HEVC decode into an `AVSampleBufferDisplayLayer` window
- **Input control** — trackpad cursor / scroll, keyboard typing, Android navigation keys
- **Two-way clipboard** — text and images, both directions
- **SMS verify-code relay** and **phone notification relay**
- **Device panel** — model and storage capacity
- **USB and Wi-Fi (LAN)** transports; QR pairing for first-time wireless setup

### Requirements
- macOS 13 (Ventura) or later
- **Apple Silicon (arm64)** — this build is arm64-only
- USB: just plug in and authorize USB debugging. Wi-Fi: set your vivo-account
  `openID` once in the menu-bar **"Wi-Fi identity…"** item (see the README).

### Install — unsigned build, please read
This build is **ad-hoc signed and not notarized** (no paid Apple Developer ID).
macOS Gatekeeper will block it on first launch. To open it:

1. Open the `.dmg` and drag **PcsuiteMirror.app** to **Applications**.
2. **Right-click the app → Open**, then confirm in the dialog (only needed once).

If macOS still refuses ("damaged / cannot be opened"), clear the quarantine flag:

```sh
xattr -dr com.apple.quarantine /Applications/PcsuiteMirror.app
```

### License
GPLv3 — Copyright (C) 2026 xVanTuring.
