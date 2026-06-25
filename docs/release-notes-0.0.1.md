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

### Install
Signed with a Developer ID certificate and **notarized by Apple**, so it opens
normally — no Gatekeeper right-click dance:

1. Open the `.dmg` and drag **PcsuiteMirror.app** to **Applications**.
2. Launch it from Applications. (It's a menu-bar app — look for its icon in the
   menu bar, not the Dock.)

The `.zip` is the same notarized app if you prefer that over the disk image.

### License
GPLv3 — Copyright (C) 2026 xVanTuring.
