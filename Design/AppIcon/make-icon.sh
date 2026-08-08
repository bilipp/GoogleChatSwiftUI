#!/bin/sh
# Draws the app icon.
#
#   Design/AppIcon/make-icon.sh [composition] [palette]
#       writes GoogleChatSwiftUI/AppIcon.icon, checks it compiles, and refreshes
#       Design/AppIcon/preview.png from what the system actually renders.
#
#   Design/AppIcon/make-icon.sh --baked [composition] [palette]
#       writes the old flat PNG ladder to Design/AppIcon/baked/ instead, for
#       anywhere the layered document cannot go.
#
# Compositions: dialogue (shipping), fan, hero.  Palettes: chat (shipping), even, teal.
set -e
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
bin=$(mktemp -d)/render
swiftc -O "$here/render.swift" -o "$bin"

if [ "$1" = "--baked" ]; then
    shift
    mkdir -p "$here/baked"
    "$bin" "$here/baked" "${1:-dialogue}" "${2:-chat}"
    exit 0
fi

"$bin" "$root/GoogleChatSwiftUI" "${1:-dialogue}" "${2:-chat}" --icon

# Compile it the way Xcode will, both to catch a bad document early and to grab
# a preview of the system's own rendering rather than a mock-up of it.
work=$(mktemp -d)
mkdir -p "$work/out"
xcrun actool "$root/GoogleChatSwiftUI/AppIcon.icon" --compile "$work/out" \
    --platform macosx --minimum-deployment-target 26.0 --app-icon AppIcon \
    --output-partial-info-plist "$work/p.plist" > "$work/log" 2>&1
if [ ! -f "$work/out/AppIcon.icns" ]; then
    echo "actool rejected the icon document:" >&2
    grep -oE '<string>[^<]*</string>' "$work/log" | head -5 >&2
    exit 1
fi
iconutil -c iconset -o "$work/i.iconset" "$work/out/AppIcon.icns"
cp "$work/i.iconset/icon_128x128@2x.png" "$here/preview.png"
echo "wrote GoogleChatSwiftUI/AppIcon.icon and Design/AppIcon/preview.png"
