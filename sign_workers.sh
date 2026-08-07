#!/bin/bash
# Re-signs the two PyInstaller-frozen worker bundles (disturbance-worker,
# pipeline_v13) inside a built/archived JalanKita Mac.app with a REAL signing
# identity, then re-signs the outer .app itself (modifying Resources
# invalidates its existing seal).
#
# Why this exists: Xcode's own automatic signing only covers what it compiles
# and what a "Copy Files" build phase stages with Code Sign on Copy enabled.
# Both workers are staged by a plain Run Script phase (rsync), so Xcode never
# signs their ~450-470 bundled dylibs each -- PyInstaller leaves them
# ad-hoc-signed (`codesign -dv` shows `Signature=adhoc`, `TeamIdentifier=not
# set`), which `spctl`/Apple's notary service reject outright. This script is
# the fix, run once per archive, after `xcodebuild archive` and before
# `xcodebuild -exportArchive` / uploading to App Store Connect / notarytool.
#
# Usage:
#   ./sign_workers.sh "/path/to/JalanKita Mac.app" ["Signing Identity Name"]
#
# If the identity is omitted, this looks for exactly one "Developer ID
# Application" or "Apple Distribution" certificate in the login keychain and
# uses that -- an "Apple Development" certificate is NOT accepted (it cannot
# notarize; `spctl` will still reject a build signed with one, confirmed
# empirically against a real archive of this project).
set -euo pipefail

APP_PATH="${1:?Usage: $0 <path to JalanKita Mac.app> [signing identity]}"
ENTITLEMENTS="$(dirname "$0")/worker-signing.entitlements"

if [ -n "${2:-}" ]; then
    IDENTITY="$2"
else
    CANDIDATES=$(security find-identity -v -p codesigning | grep -E "Developer ID Application|Apple Distribution" || true)
    COUNT=$(echo "$CANDIDATES" | grep -c "^" || true)
    if [ -z "$CANDIDATES" ]; then
        echo "error: no 'Developer ID Application' or 'Apple Distribution' identity found in the" >&2
        echo "keychain (only an 'Apple Development' certificate does not count -- it cannot" >&2
        echo "notarize). Create one at developer.apple.com or via Xcode's Signing &" >&2
        echo "Capabilities (requires Admin/App Manager role on the Apple Developer team), then" >&2
        echo "re-run. Available identities:" >&2
        security find-identity -v -p codesigning >&2
        exit 1
    fi
    if [ "$COUNT" -gt 1 ]; then
        echo "error: multiple candidate identities found -- pass one explicitly as \$2:" >&2
        echo "$CANDIDATES" >&2
        exit 1
    fi
    IDENTITY=$(echo "$CANDIDATES" | sed -E 's/^[[:space:]]*[0-9]+\) [A-F0-9]+ "(.*)"$/\1/')
fi

echo "[sign_workers] app:      $APP_PATH"
echo "[sign_workers] identity: $IDENTITY"

for WORKER_DIR in "disturbance-worker" "pipeline_v13"; do
    DIR="$APP_PATH/Contents/Resources/$WORKER_DIR"
    if [ ! -d "$DIR" ]; then
        echo "warning: $DIR not found -- skipping (was it staged into this build?)"
        continue
    fi

    echo "[sign_workers] signing dylibs/so files under $WORKER_DIR/_internal ..."
    find "$DIR/_internal" \( -name "*.dylib" -o -name "*.so" \) -print0 2>/dev/null \
        | xargs -0 -n1 -P4 codesign --force --options runtime --timestamp \
            --entitlements "$ENTITLEMENTS" --sign "$IDENTITY"

    echo "[sign_workers] signing main executable $WORKER_DIR/$WORKER_DIR ..."
    codesign --force --options runtime --timestamp \
        --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$DIR/$WORKER_DIR"
done

echo "[sign_workers] re-signing the outer app bundle (staging invalidated its seal) ..."
codesign --force --options runtime --timestamp --deep --sign "$IDENTITY" "$APP_PATH"

echo "[sign_workers] verifying ..."
codesign --verify --deep --strict "$APP_PATH"
spctl --assess --type execute -vv "$APP_PATH" || {
    echo "note: spctl will still say 'rejected' until this build is notarized" \
         "(xcrun notarytool submit ... && xcrun stapler staple ...) -- that's expected here." >&2
}

echo "[sign_workers] done."
