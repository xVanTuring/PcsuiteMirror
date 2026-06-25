#!/usr/bin/env bash
# scripts/release.sh
#
# Bump version → build Rust core → build Release .app → ad-hoc sign →
# zip + DMG → tag → publish a GitHub release.
#
# This app is NOT notarized and ships without a paid Developer-ID
# signature (Sparkle auto-update is intentionally absent). The bundle is
# only ad-hoc signed, so on first launch users must right-click → Open
# (or `xattr -dr com.apple.quarantine PcsuiteMirror.app`). The release
# notes spell this out.
#
# Usage:
#   ./scripts/release.sh <version> [--notes-file <path>] [--dry-run]
#
# Examples:
#   ./scripts/release.sh 0.0.1
#   ./scripts/release.sh 0.0.1 --notes-file docs/release-notes-0.0.1.md
#   ./scripts/release.sh 0.0.1 --dry-run
#
set -euo pipefail

# Resolve repo root from the script's own location so it runs from anywhere.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# ── Project constants ───────────────────────────────────────────────
SCHEME="PcsuiteMirror"
PROJECT="PcsuiteMirror.xcodeproj"
PRODUCT="PcsuiteMirror"
RUST_DIR="../pcsuite-rs"
RUST_BUILD="${RUST_DIR}/crates/pcsuite-ffi/build-macos.sh"
BUILD_DIR="build/DD"            # xcodebuild derivedData (gitignored)

# ── Args ────────────────────────────────────────────────────────────
usage() {
    cat <<EOF >&2
Usage: $(basename "$0") <version> [--notes-file <path>] [--dry-run]

  <version>          CFBundleShortVersionString, e.g. 0.0.1
  --notes-file PATH  File whose contents become the GitHub release body
                     (default: gh --generate-notes from commit messages).
  --dry-run          Bump version + build + package locally, but skip
                     commit / push / tag / GitHub release. Reverts the
                     version bump afterwards so the tree stays clean.
EOF
    exit 1
}

VERSION=""
NOTES_FILE=""
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --notes-file)  NOTES_FILE="${2:?--notes-file needs a path}"; shift 2 ;;
        --dry-run)     DRY_RUN=true; shift ;;
        -h|--help)     usage ;;
        -*)            echo "Unknown flag: $1" >&2; usage ;;
        *)
            if [[ -z "$VERSION" ]]; then VERSION="$1"; shift
            else echo "Unexpected positional: $1" >&2; usage; fi
            ;;
    esac
done

[[ -z "$VERSION" ]] && usage
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || { echo "ERROR: version must be X.Y.Z (got '$VERSION')" >&2; exit 1; }

TAG="v${VERSION}"
TITLE="v${VERSION}"
DIST_DIR="dist/${TAG}"
ZIP_ASSET="${PRODUCT}-${VERSION}.zip"
DMG_ASSET="${PRODUCT}-${VERSION}.dmg"
ZIP="${DIST_DIR}/${ZIP_ASSET}"
DMG="${DIST_DIR}/${DMG_ASSET}"
APP="${DIST_DIR}/${PRODUCT}.app"

echo "==> Version $VERSION  •  Tag $TAG  •  Assets $ZIP_ASSET + $DMG_ASSET"

# ── Pre-flight ──────────────────────────────────────────────────────
echo "==> Pre-flight checks"

[[ -f project.yml ]] || { echo "ERROR: run from repo root (no project.yml)" >&2; exit 1; }
[[ -x "$RUST_BUILD" ]] || { echo "ERROR: Rust build script not found/executable: $RUST_BUILD" >&2; exit 1; }

command -v xcodegen >/dev/null || { echo "ERROR: xcodegen not on PATH (brew install xcodegen)" >&2; exit 1; }
command -v xcodebuild >/dev/null || { echo "ERROR: xcodebuild not on PATH (install Xcode)" >&2; exit 1; }
command -v cargo >/dev/null || { echo "ERROR: cargo not on PATH (install Rust)" >&2; exit 1; }

if [[ "$DRY_RUN" == "false" ]]; then
    command -v gh >/dev/null || { echo "ERROR: gh CLI not on PATH (brew install gh)" >&2; exit 1; }
    gh auth status >/dev/null 2>&1 || { echo "ERROR: gh not authenticated. Run 'gh auth login'." >&2; exit 1; }

    [[ -z "$(git status --porcelain)" ]] \
        || { echo "ERROR: working tree dirty. Commit or stash first." >&2; git status --short >&2; exit 1; }

    if git rev-parse --verify "refs/tags/${TAG}" >/dev/null 2>&1; then
        echo "ERROR: tag ${TAG} already exists locally." >&2; exit 1
    fi
    if git ls-remote --tags origin "${TAG}" | grep -q "refs/tags/${TAG}$"; then
        echo "ERROR: tag ${TAG} already exists on origin." >&2; exit 1
    fi
fi

if [[ -n "$NOTES_FILE" ]]; then
    [[ -f "$NOTES_FILE" ]] || { echo "ERROR: --notes-file not found: $NOTES_FILE" >&2; exit 1; }
fi

# ── Build the Rust static lib + Swift glue ──────────────────────────
echo "==> Building Rust core ($RUST_BUILD)"
"$RUST_BUILD"

# ── Bump version in project.yml ─────────────────────────────────────
current_short=$(grep -E 'MARKETING_VERSION:' project.yml | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
current_build=$(grep -E 'CURRENT_PROJECT_VERSION:' project.yml | head -1 | sed -E 's/.*"([0-9]+)".*/\1/')
next_build=$((current_build + 1))

echo "==> Version bump  ${current_short} (build ${current_build}) → ${VERSION} (build ${next_build})"

# BSD sed (macOS) needs a backup suffix with -i; use ".bak" then rm it.
sed -i.bak -E "s/(MARKETING_VERSION: )\"[^\"]+\"/\\1\"${VERSION}\"/" project.yml
sed -i.bak -E "s/(CURRENT_PROJECT_VERSION: )\"[^\"]+\"/\\1\"${next_build}\"/" project.yml
rm -f project.yml.bak

xcodegen >/dev/null

# Revert the version bump (used on build failure and after a dry run).
revert_bump() {
    git checkout -- project.yml 2>/dev/null || true
    xcodegen >/dev/null 2>&1 || true
}

# ── Build the Release .app straight into DIST_DIR ───────────────────
# No Developer-ID export step — CODE_SIGNING_ALLOWED=NO yields an
# unsigned binary that we ad-hoc sign below.
echo "==> Cleaning ${DIST_DIR}"
rm -rf "${DIST_DIR}"
mkdir -p "${DIST_DIR}"

echo "==> Building Release ${PRODUCT}.app (this can take a minute)"
if ! xcodebuild \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -configuration Release \
        -derivedDataPath "$BUILD_DIR" \
        CONFIGURATION_BUILD_DIR="$ROOT/$DIST_DIR" \
        CODE_SIGNING_ALLOWED=NO \
        build 2>&1 | grep -E "(error:|BUILD SUCCEEDED|BUILD FAILED)"; then
    echo "ERROR: Release build failed. Reverting version bump." >&2
    revert_bump
    exit 1
fi

[[ -d "$APP" ]] || { echo "ERROR: built app missing at $APP" >&2; revert_bump; exit 1; }

# Strip the build's sidecar products so only the .app ships in the dir.
rm -rf "${DIST_DIR}/${PRODUCT}.swiftmodule" "${DIST_DIR}/${PRODUCT}.app.dSYM"

# ── Ad-hoc sign (best effort — bundle has no nested code) ────────────
echo "==> Ad-hoc signing ${PRODUCT}.app"
codesign --force --deep --sign - "$APP"
codesign --verify --verbose=2 "$APP" || { echo "ERROR: ad-hoc codesign verify failed" >&2; revert_bump; exit 1; }

echo "==> Built arch:"
lipo -info "$APP/Contents/MacOS/${PRODUCT}" 2>&1 || true

# ── Zip (ditto, Apple-correct form) ─────────────────────────────────
echo "==> Zipping ${ZIP_ASSET}"
# --sequesterRsrc/--keepParent keep the bundle structure intact so the
# extracted .app stays launchable (matches Apple's notarization form).
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

# ── DMG (hdiutil; create-dmg not required) ──────────────────────────
echo "==> Creating ${DMG_ASSET}"
DMG_STAGE="${DIST_DIR}/.dmg-stage"
rm -rf "$DMG_STAGE"
mkdir -p "$DMG_STAGE"
ditto "$APP" "${DMG_STAGE}/${PRODUCT}.app"
ln -s /Applications "${DMG_STAGE}/Applications"
hdiutil create \
    -volname "${PRODUCT} ${VERSION}" \
    -srcfolder "$DMG_STAGE" \
    -ov -format UDZO \
    "$DMG" >/dev/null
rm -rf "$DMG_STAGE"

echo "==> Artifacts:"
echo "    $ZIP  ($(du -h "$ZIP" | cut -f1))"
echo "    $DMG  ($(du -h "$DMG" | cut -f1))"

# ── Dry run stops here ──────────────────────────────────────────────
if [[ "$DRY_RUN" == "true" ]]; then
    echo "==> [dry-run] reverting version bump; skipping commit / tag / release."
    revert_bump
    echo "    Inspect artifacts under ${DIST_DIR}/ then re-run without --dry-run."
    exit 0
fi

# ── Commit version bump + push ──────────────────────────────────────
echo "==> Committing version bump"
git add project.yml
git commit -m "release: ${VERSION} (build ${next_build})"

if [[ -n "$(git status --porcelain)" ]]; then
    echo "ERROR: working tree dirty after version-bump commit. Resolve before push." >&2
    git status --short >&2; exit 1
fi

echo "==> Pushing main"
git push origin HEAD

# ── Tag + GitHub release ────────────────────────────────────────────
echo "==> Tagging ${TAG}"
git tag -a "$TAG" -m "$TAG"
git push origin "$TAG"

echo "==> Creating GitHub release"
if [[ -n "$NOTES_FILE" ]]; then
    gh release create "$TAG" \
        --title "$TITLE" \
        --notes-file "$NOTES_FILE" \
        "$ZIP" "$DMG"
else
    gh release create "$TAG" \
        --title "$TITLE" \
        --generate-notes \
        "$ZIP" "$DMG"
fi

REPO_SLUG="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || echo '<owner>/<repo>')"
echo
echo "================================================================"
echo "Release ${TAG} done"
echo "  .zip : ${ZIP}"
echo "  .dmg : ${DMG}"
echo "  URL  : https://github.com/${REPO_SLUG}/releases/tag/${TAG}"
echo "================================================================"
echo
echo "Unsigned build — first-launch instructions for users:"
echo "  Right-click PcsuiteMirror.app → Open  (then confirm), or:"
echo "  xattr -dr com.apple.quarantine /Applications/PcsuiteMirror.app"
