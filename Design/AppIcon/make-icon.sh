#!/bin/sh
# Draws the app icon and writes it into the asset catalogue.
#   Design/AppIcon/make-icon.sh [composition] [palette]
# Compositions: dialogue (shipping), fan, hero.
# Palettes: chat (shipping), even, teal. See render.swift.
set -e
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
out="$root/GoogleChatSwiftUI/Assets.xcassets/AppIcon.appiconset"
bin=$(mktemp -d)/render
swiftc -O "$here/render.swift" -o "$bin"
"$bin" "$out" "${1:-dialogue}" "${2:-chat}"
