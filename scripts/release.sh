#!/usr/bin/env bash
# scripts/release.sh
#
# Bump version → build Rust core → build Release .app → Developer-ID sign
# (hardened runtime) → notarize + staple → zip + DMG → tag → publish a
# GitHub release.
#
# The app is signed with a Developer ID Application certificate (team
# $TEAM_ID), hardened-runtime enabled, then submitted to Apple's notary
# service and the ticket stapled onto both the .app and the .dmg. Result:
# Gatekeeper opens it with no right-click dance and no quarantine prompt,
# even offline. (Sparkle auto-update is still intentionally absent.)
#
# One-time machine setup (already done for Noticky on this Mac):
#   • Developer ID Application cert for team $TEAM_ID in the login keychain
#       (Xcode → Settings → Accounts → Manage Certificates → + → Developer ID).
#   • A notarytool credential profile, stored once with:
#       xcrun notarytool store-credentials "$NOTARY_PROFILE" \
#           --apple-id <you@apple> --team-id $TEAM_ID --password <app-specific-pw>
#   • The team's Apple Developer Program License Agreement must be current —
#       if notarytool returns 403 "a required agreement is missing or has
#       expired", accept the updated agreement at developer.apple.com /
#       App Store Connect before releasing.
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

# Developer ID / notarization. TEAM_ID + NOTARY_PROFILE are shared with the
# author's other notarized apps; override NOTARY_PROFILE via env if you stored
# the credentials under a different name.
TEAM_ID="T8F5T6HKG8"
NOTARY_PROFILE="${NOTARY_PROFILE:-noticky-notary}"

# ── Args ────────────────────────────────────────────────────────────
usage() {
    cat <<EOF >&2
Usage: $(basename "$0") <version> [--notes-file <path>] [--dry-run]

  <version>          CFBundleShortVersionString, e.g. 0.0.1
  --notes-file PATH  File whose contents become the GitHub release body
                     (default: gh --generate-notes from commit messages).
  --dry-run          Bump version + build + Developer-ID sign + package
                     locally, but SKIP notarization, commit, push, tag and
                     the GitHub release. Reverts the version bump afterwards
                     so the tree stays clean.
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

# Developer ID Application signing identity for our team (needed for both real
# and dry runs, since we sign in both). Resolve to the SHA-1 hash so codesign
# can't pick the wrong cert when several are installed.
DEV_ID_HASH="$(security find-identity -v -p codesigning \
    | grep "Developer ID Application" | grep "(${TEAM_ID})" | head -1 | awk '{print $2}')"
if [[ -z "$DEV_ID_HASH" ]]; then
    echo "ERROR: no 'Developer ID Application' cert for team ${TEAM_ID} in the login keychain." >&2
    echo "       Xcode → Settings → Accounts → Manage Certificates → + → Developer ID Application." >&2
    exit 1
fi
DEV_ID_NAME="$(security find-identity -v -p codesigning \
    | grep "$DEV_ID_HASH" | head -1 | sed -E 's/.*"(.+)"$/\1/')"
echo "    signing identity: ${DEV_ID_NAME}"

if [[ "$DRY_RUN" == "false" ]]; then
    command -v gh >/dev/null || { echo "ERROR: gh CLI not on PATH (brew install gh)" >&2; exit 1; }
    gh auth status >/dev/null 2>&1 || { echo "ERROR: gh not authenticated. Run 'gh auth login'." >&2; exit 1; }

    # Notary credentials must work AND the team's agreement must be current.
    # `notarytool history` surfaces a 403 agreement error before we build.
    echo "    checking notary profile '${NOTARY_PROFILE}'…"
    if ! NOTARY_CHECK="$(xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" 2>&1)"; then
        echo "ERROR: notarytool profile '${NOTARY_PROFILE}' is unusable:" >&2
        echo "$NOTARY_CHECK" | sed 's/^/       /' >&2
        echo "       If this is a 403 'required agreement' error, sign in at" >&2
        echo "       https://developer.apple.com/account and accept the updated" >&2
        echo "       Program License Agreement, then retry." >&2
        echo "       If credentials are missing, set them up once with:" >&2
        echo "         xcrun notarytool store-credentials ${NOTARY_PROFILE} \\" >&2
        echo "             --apple-id <id> --team-id ${TEAM_ID} --password <app-specific-pw>" >&2
        exit 1
    fi

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
# Build unsigned (CODE_SIGNING_ALLOWED=NO), then Developer-ID sign below with
# hardened runtime — simpler than an archive/exportArchive round-trip and the
# bundle has no nested code to re-sign.
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

# ── Developer-ID sign with hardened runtime ─────────────────────────
# --options runtime → hardened runtime (required for notarization).
# --timestamp       → secure Apple timestamp (also required).
# No --entitlements: the app needs no hardened-runtime exceptions (Rust is
# statically linked; only Apple system frameworks are dynamically loaded).
echo "==> Developer-ID signing ${PRODUCT}.app"
codesign --force --options runtime --timestamp --sign "$DEV_ID_HASH" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP" \
    || { echo "ERROR: codesign verify failed" >&2; revert_bump; exit 1; }
codesign -d --verbose=2 "$APP" 2>&1 | grep -E "TeamIdentifier|Authority=Developer ID|flags=.*runtime" || true

echo "==> Built arch:"
lipo -info "$APP/Contents/MacOS/${PRODUCT}" 2>&1 || true

# ── Notarize the .app (submit a zip; staple the ticket onto the bundle) ──
if [[ "$DRY_RUN" == "false" ]]; then
    echo "==> Zipping app for notarization"
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

    echo "==> Submitting .app to Apple notary (--wait blocks until verdict)"
    NOTARY_LOG="${DIST_DIR}/notary-app.log"
    if ! xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1 | tee "$NOTARY_LOG"; then
        echo "ERROR: app notarization failed. See $NOTARY_LOG" >&2
        echo "       Pull details: xcrun notarytool log <id> --keychain-profile $NOTARY_PROFILE" >&2
        revert_bump
        exit 1
    fi

    echo "==> Stapling ticket onto ${PRODUCT}.app"
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
fi

# ── Final zip (must contain the STAPLED app) ────────────────────────
echo "==> Zipping ${ZIP_ASSET}"
rm -f "$ZIP"
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

# ── Notarize + staple the DMG too ───────────────────────────────────
if [[ "$DRY_RUN" == "false" ]]; then
    echo "==> Submitting .dmg to Apple notary"
    NOTARY_LOG_DMG="${DIST_DIR}/notary-dmg.log"
    if ! xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1 | tee "$NOTARY_LOG_DMG"; then
        echo "ERROR: DMG notarization failed. See $NOTARY_LOG_DMG" >&2
        revert_bump
        exit 1
    fi
    echo "==> Stapling DMG"
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"

    echo "==> Gatekeeper assessment (should PASS now):"
    spctl -a -t exec -vv "$APP" 2>&1 || true
fi

echo "==> Artifacts:"
echo "    $ZIP  ($(du -h "$ZIP" | cut -f1))"
echo "    $DMG  ($(du -h "$DMG" | cut -f1))"

# ── Dry run stops here ──────────────────────────────────────────────
if [[ "$DRY_RUN" == "true" ]]; then
    echo "==> [dry-run] reverting version bump; skipping notarize / commit / tag / release."
    revert_bump
    echo "    Artifacts under ${DIST_DIR}/ are signed but NOT notarized."
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
echo "Release ${TAG} done — Developer-ID signed + notarized + stapled"
echo "  .zip : ${ZIP}"
echo "  .dmg : ${DMG}"
echo "  URL  : https://github.com/${REPO_SLUG}/releases/tag/${TAG}"
echo "================================================================"
