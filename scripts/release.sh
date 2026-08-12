#!/bin/bash
#
# Builds a release copy of the app, installs it here, and hands it to the team over
# Drive.
#
#     scripts/release.sh               build, zip, install, upload
#     scripts/release.sh --no-upload   everything but the upload
#     scripts/release.sh --no-install  leave /Applications alone
#
# Each run raises CURRENT_PROJECT_VERSION by one and stamps that number into the zip
# name, so two builds of the same marketing version never arrive as the same file. The
# bump is left uncommitted in the working tree; commit it with whatever it shipped.

set -euo pipefail

PROJECT_ROOT=$(cd "$(dirname "$0")/.." && pwd)
PBXPROJ="$PROJECT_ROOT/GoogleChatSwiftUI.xcodeproj/project.pbxproj"
SCHEME=GoogleChatSwiftUI
OUT_DIR="$PROJECT_ROOT/build/release"

# https://drive.google.com/drive/u/0/folders/1bDGSBfPJhGNwrVSAmrCta-Hs4tjyj9WK
#
# Addressed by ID rather than by path: the folder is shared rather than owned, so its
# name is not a path under the remote's root and `gdrive:Some/Folder` would not find it.
DRIVE_FOLDER_ID=1bDGSBfPJhGNwrVSAmrCta-Hs4tjyj9WK
DRIVE_REMOTE=gdrive

UPLOAD=yes
INSTALL=yes

while [ $# -gt 0 ]; do
    case $1 in
        --no-upload) UPLOAD=no ;;
        --no-install) INSTALL=no ;;
        *)
            echo "usage: $(basename "$0") [--no-upload] [--no-install]" >&2
            exit 64
            ;;
    esac
    shift
done

for tool in xcodebuild ditto rclone; do
    if ! command -v "$tool" >/dev/null; then
        echo "error: $tool is not installed" >&2
        exit 69
    fi
done

if [ "$UPLOAD" = yes ] && ! rclone listremotes | grep -qx "$DRIVE_REMOTE:"; then
    echo "error: no rclone remote named '$DRIVE_REMOTE' — run: rclone config" >&2
    exit 69
fi

# ---------------------------------------------------------------------------------
# Build number
# ---------------------------------------------------------------------------------

# The version lives in the four build-setting blocks of project.pbxproj (app and tests
# target, Debug and Release each) rather than in Config/Info.plist, which leaves
# CFBundleVersion to GENERATE_INFOPLIST_FILE. Highest wins, so a block someone edited
# by hand cannot drag the next build backwards, and all four are then written together
# to keep the two targets' versions from drifting apart.
CURRENT=$(sed -nE 's/^[[:space:]]*CURRENT_PROJECT_VERSION = ([0-9]+);$/\1/p' "$PBXPROJ" \
    | sort -n | tail -1)

if [ -z "$CURRENT" ]; then
    echo "error: no CURRENT_PROJECT_VERSION found in $PBXPROJ" >&2
    exit 65
fi

BUILD=$((CURRENT + 1))

MARKETING=$(sed -nE 's/^[[:space:]]*MARKETING_VERSION = (.+);$/\1/p' "$PBXPROJ" \
    | sort -u | head -1)
MARKETING=${MARKETING:-0}

sed -i '' -E "s/^([[:space:]]*CURRENT_PROJECT_VERSION = )[0-9]+;$/\1$BUILD;/" "$PBXPROJ"

echo "==> Build $CURRENT -> $BUILD (version $MARKETING)"

# ---------------------------------------------------------------------------------
# Archive and export
# ---------------------------------------------------------------------------------

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

ARCHIVE="$OUT_DIR/$SCHEME.xcarchive"
EXPORT_DIR="$OUT_DIR/export"

echo "==> Archiving"
xcodebuild archive \
    -project "$PROJECT_ROOT/GoogleChatSwiftUI.xcodeproj" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -archivePath "$ARCHIVE" \
    -derivedDataPath "$OUT_DIR/DerivedData" \
    | tail -20

# Exporting rather than reaching into the archive: the app inside an archive still
# carries the development signature the build used, and only the export re-signs it
# with the Developer ID certificate that lets the app open on a machine that is not
# this one. DEVELOPMENT_TEAM comes from Config/Secrets.xcconfig, which is per-person.
TEAM=$(xcodebuild -project "$PROJECT_ROOT/GoogleChatSwiftUI.xcodeproj" \
    -scheme "$SCHEME" -configuration Release -showBuildSettings 2>/dev/null \
    | sed -nE 's/^[[:space:]]*DEVELOPMENT_TEAM = (.+)$/\1/p' | head -1)

if [ -z "$TEAM" ]; then
    echo "error: DEVELOPMENT_TEAM is empty — see Config/Secrets.example.xcconfig" >&2
    exit 78
fi

EXPORT_OPTIONS=$(mktemp -t release-export)
trap 'rm -f "$EXPORT_OPTIONS"' EXIT

cat >"$EXPORT_OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>$TEAM</string>
    <key>signingStyle</key>
    <string>automatic</string>
</dict>
</plist>
PLIST

echo "==> Exporting with Developer ID (team $TEAM)"
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportOptionsPlist "$EXPORT_OPTIONS" \
    -exportPath "$EXPORT_DIR" \
    | tail -10

APP=$(find "$EXPORT_DIR" -maxdepth 1 -name '*.app' -print -quit)

if [ -z "$APP" ]; then
    echo "error: export produced no .app in $EXPORT_DIR" >&2
    exit 70
fi

BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Contents/Info.plist")

# ---------------------------------------------------------------------------------
# Notarize, when there are credentials for it
# ---------------------------------------------------------------------------------

# Gatekeeper on someone else's Mac refuses a downloaded app that Apple has not seen,
# whatever it is signed with. Notarizing needs an App Store Connect credential this
# script has no way to invent, so it is opt-in: store one with
#
#     xcrun notarytool store-credentials <name> --key ... --key-id ... --issuer ...
#
# and pass the name as NOTARY_PROFILE. Without it the build still works, but whoever
# downloads it has to clear the quarantine flag by hand.
if [ -n "${NOTARY_PROFILE:-}" ]; then
    echo "==> Notarizing as $NOTARY_PROFILE"
    NOTARIZE_ZIP="$OUT_DIR/notarize.zip"
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$NOTARIZE_ZIP"
    xcrun notarytool submit "$NOTARIZE_ZIP" \
        --keychain-profile "$NOTARY_PROFILE" --wait
    # Stapling writes the ticket into the bundle, so the copy that gets zipped below
    # passes Gatekeeper even on a Mac that cannot reach Apple to ask.
    xcrun stapler staple "$APP"
    rm -f "$NOTARIZE_ZIP"
else
    echo "==> Not notarized (NOTARY_PROFILE unset); recipients must clear quarantine:"
    echo "    xattr -d com.apple.quarantine '/Applications/$(basename "$APP")'"
fi

# ---------------------------------------------------------------------------------
# Zip
# ---------------------------------------------------------------------------------

# The product name has a space in it; the zip's does not, so nobody has to quote the
# name to talk about a build. ditto rather than zip(1), which flattens the symlinks
# inside a bundle's Contents and breaks the signature along with them.
ZIP="$OUT_DIR/GoogleChat-$MARKETING-b$BUILD.zip"

echo "==> Zipping $(basename "$ZIP")"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

# ---------------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------------

# The copy in /Applications is replaced from the export rather than by unzipping, so
# the zip stays untouched evidence of what went out.
if [ "$INSTALL" = yes ]; then
    INSTALLED="/Applications/$(basename "$APP")"

    # A running app cannot be replaced under itself: the old executable stays mapped and
    # the new bundle's signature no longer matches what the process was launched from,
    # which shows up later as an app that refuses to relaunch. Ask first, insist after
    # ten seconds — by bundle ID, so a stale binary somewhere else is not what quits.
    if pgrep -f "$INSTALLED/Contents/MacOS/" >/dev/null; then
        echo "==> Quitting the running copy"
        osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true

        for _ in $(seq 20); do
            pgrep -f "$INSTALLED/Contents/MacOS/" >/dev/null || break
            sleep 0.5
        done

        if pgrep -f "$INSTALLED/Contents/MacOS/" >/dev/null; then
            echo "    still running after 10s, killing it"
            pkill -f "$INSTALLED/Contents/MacOS/" || true
            sleep 1
        fi
    fi

    # Staged beside the destination and swapped in, so a copy that fails halfway leaves
    # the working app in place instead of a half-written bundle.
    STAGED="/Applications/.$(basename "$APP").new"
    rm -rf "$STAGED"
    ditto "$APP" "$STAGED"
    rm -rf "$INSTALLED"
    mv "$STAGED" "$INSTALLED"

    echo "==> Installed $INSTALLED"
fi

if [ "$UPLOAD" = no ]; then
    echo "==> Done: $ZIP"
    exit 0
fi

# ---------------------------------------------------------------------------------
# Upload
# ---------------------------------------------------------------------------------

echo "==> Uploading to Drive"
rclone copy "$ZIP" "$DRIVE_REMOTE:" \
    --drive-root-folder-id="$DRIVE_FOLDER_ID" \
    --progress

# Link to the file itself rather than the folder, so the message announcing a build can
# point straight at it. This reads back the ID Drive assigned; it grants nobody access
# the folder had not already granted.
FILE_ID=$(rclone lsjson "$DRIVE_REMOTE:$(basename "$ZIP")" \
    --drive-root-folder-id="$DRIVE_FOLDER_ID" 2>/dev/null \
    | sed -nE 's/.*"ID":"([^"]+)".*/\1/p' | head -1)

echo
echo "==> Build $BUILD uploaded: $(basename "$ZIP")"
if [ -n "$FILE_ID" ]; then
    echo "    https://drive.google.com/file/d/$FILE_ID/view"
else
    echo "    https://drive.google.com/drive/folders/$DRIVE_FOLDER_ID"
fi
