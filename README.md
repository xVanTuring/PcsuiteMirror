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
