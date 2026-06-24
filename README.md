# PcsuiteMirror

A SwiftUI macOS menu-bar app that mirrors and controls an Android phone over USB
or Wi-Fi. It wraps the pure-Rust `pcsuite` core (via the `pcsuite-ffi` swift-bridge
binding) and adds the native frontend: VideoToolbox HEVC decode, an
`AVSampleBufferDisplayLayer` mirror window with trackpad/keyboard input, two-way
clipboard, SMS verify-code relay, phone notification relay, and a device panel
(storage capacity, model).

## Build

```bash
# 1. Build the Rust static lib + Swift glue:
(cd ../pcsuite-rs && ./crates/pcsuite-ffi/build-macos.sh)
# 2. Generate the Xcode project and build:
xcodegen generate
xcodebuild -scheme PcsuiteMirror -configuration Debug build CODE_SIGNING_ALLOWED=NO
```

The `.xcodeproj` is generated from `project.yml` by [xcodegen] and is not checked
in. The app links `../pcsuite-rs/target/release/libpcsuite_ffi.a` and compiles the
generated Swift glue under `../pcsuite-rs/crates/pcsuite-ffi/generated/`.

[xcodegen]: https://github.com/yonaskolb/XcodeGen

## Configuration

The app gets your pairing identity and per-IP seed from the Rust core's config,
**not** from any in-app UI. Because the bundled app launches without a shell
environment and with CWD `/`, the only config source it reads is
**`~/.config/pcsuite/config.json`** (the app is unsandboxed, so this is your real
home). Create it from
[`../pcsuite-rs/pcsuite.example.json`](../pcsuite-rs/pcsuite.example.json):

```jsonc
// ~/.config/pcsuite/config.json
{
  "open_id": "your-account-openid",
  "pc_mac": "001122334455",
  "device_name": "My MacBook Pro",
  "seeds": { "192.168.1.42": "per-ip-pairing-seed-uuid" }
}
```

Without it, the core uses placeholder values that will not pair with a real phone.

## License

Copyright (C) 2026 xVanTuring

This program is free software: you can redistribute it and/or modify it under the
terms of the GNU General Public License as published by the Free Software
Foundation, either version 3 of the License, or (at your option) any later
version.

This program is distributed in the hope that it will be useful, but WITHOUT ANY
WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A
PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with this
program. If not, see <https://www.gnu.org/licenses/>. The full text is in
[`LICENSE`](LICENSE).
