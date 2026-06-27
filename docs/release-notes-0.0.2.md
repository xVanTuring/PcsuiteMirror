## PcsuiteMirror 0.0.2

Second public build. Focuses on screen-mirror quality controls, a smoother
mirror window, and a device-centric menu.

### New
- **Mirror encoder settings** — pick resolution, **bitrate** (4 / 8 / 12 / 20 Mbps),
  and **frame rate** (30 / 60), or one-tap **presets** (Smooth / Quality / Balanced /
  Bandwidth saver). Changes apply live (the stream restarts). Bitrate was previously
  never sent, so the phone always fell back to ~4 Mbps — you can now go much higher.
- **Phone audio (experimental)** — request the phone's audio stream. The bytes are
  demuxed off the video path but **not decoded/played yet**; off by default.
- **FPS & latency HUD** — optional overlay in the mirror window (Settings toggle).
- **Device roster** — the menu is now device-centric: remembered phones, most-recent
  first, each expanding to its own actions, instead of a single "last connected".
- **Menu-bar status icon** + failure notifications; toggles now take effect instantly.

### Fixed
- **Mirror window smoothness** — eliminated the stutter when the window chrome
  expands/collapses (Core Animation growth, decode enqueue moved off the main thread,
  de-duplicated chrome triggers). Chrome now reveals only on edge hover.
- **Wi-Fi connect** — auto-fall back to `connectType=1` when no seed is stored.

### Requirements
- macOS 13 (Ventura) or later
- **Apple Silicon (arm64)** — this build is arm64-only
- USB: just plug in and authorize USB debugging. Wi-Fi: set your vivo-account
  `openID` once in the menu-bar identity settings (see the README).

### Install
Signed with a Developer ID certificate and **notarized by Apple**, so it opens
normally — no Gatekeeper right-click dance:

1. Open the `.dmg` and drag **PcsuiteMirror.app** to **Applications**.
2. Launch it from Applications. (It's a menu-bar app — look for its icon in the
   menu bar, not the Dock.)

The `.zip` is the same notarized app if you prefer that over the disk image.

### License
GPLv3 — Copyright (C) 2026 xVanTuring.
