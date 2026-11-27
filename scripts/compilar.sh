#!/bin/zsh
# compilar.sh: builds Vigia and produces a signed build/Vigia.app.
#
# Copyright (C) 2026 Gabriel Castiglia. Licensed under the GNU GPL, version 2 only.
# Date: November 10, 2026
# SPDX-License-Identifier: GPL-2.0-only
#
# This program is free software: you can redistribute it and/or modify it under the terms of
# the GNU General Public License, version 2, as published by the Free Software Foundation.
# It is distributed WITHOUT ANY WARRANTY. See the LICENSE file for details.
#
# Requires Apple's Command Line Tools (xcode-select --install); Xcode is not needed. The web
# page and its bundle (web/, web/lib/) are in the repository; scripts/web.sh rebuilds the bundle.
# The version is written here and nowhere else.

set -euo pipefail
RAIZ="${0:A:h:h}"
cd "$RAIZ"

# Spotlight must not list the copies built here (21-nov-2026: Citadel and Vigía showed twice, and old Gryphmark
# copies from expanded packages): build is a link to build.noindex, a folder Spotlight leaves out.
if [[ ! -L build ]]; then
    mkdir -p build.noindex
    if [[ -d build ]]; then rsync -a build/ build.noindex/ && rm -rf build; fi
    ln -s build.noindex build
fi
[[ "${FIRMA:-}" == adhoc ]] || source scripts/firma.sh

VERSION="3.6.1"
COMPILACION="1"
APP="build/Vigia.app"

# 0. @State needs SwiftUI's macro plugin, which only comes with Xcode: with the Command Line Tools it fails as
#    "SwiftUIMacros.StateMacro could not be found". Use @StateObject of an ObservableObject instead.
if grep -nE '^[^/]*@State([^O]|$)' Sources/*.swift; then echo "@State does not build without Xcode: use @StateObject (see DragState)" >&2; exit 1; fi

# 0. Every text the code asks for must exist in Sources/Strings.swift.
faltan=$(grep -ohE '\bL\("[A-Za-z]+"' Sources/*.swift | sed -E 's/L\("([A-Za-z]+)"/\1/' | sort -u | while read k; do
    grep -q "^    \"$k\": \[" Sources/Strings.swift || echo "$k"
done)
if [[ -n "$faltan" ]]; then echo "texts missing in Strings.swift: $faltan" >&2; exit 1; fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# 1. The app
swiftc -O -swift-version 5 -target arm64-apple-macos15.0 -module-name Vigia \
    Sources/*.swift -o "$APP/Contents/MacOS/Vigia"

# 2. Icon, the twelve colours, the page, samples and manuals
SET="$(mktemp -d)/Vigia.iconset"
mkdir -p "$SET"
for t in 16 32 128 256 512; do
    sips -z $t $t icono/icono-1024.png --out "$SET/icon_${t}x${t}.png" >/dev/null
    sips -z $((t * 2)) $((t * 2)) icono/icono-1024.png --out "$SET/icon_${t}x${t}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o "$APP/Contents/Resources/Vigia.icns"
rm -rf "${SET:h}"
R="$APP/Contents/Resources"
cp -R icono/accents "$R/accents"
rsync -a --exclude '.DS_Store' web/ "$R/web/"
mkdir -p "$R/samples" "$R/docs" "$R/licenses"
cp samples/sample_en.md samples/sample_es.md samples/sample_ja.md "$R/samples/"
cp docs/Vigia-manual-en.pdf docs/Vigia-manual-es.pdf docs/Vigia-manual-ja.pdf "$R/docs/" 2>/dev/null || true
cp LICENSE "$R/licenses/Vigia-LICENSE"

# 3. Info.plist: opens Markdown files (as an alternative, never taking them over)
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Vigía</string>
    <key>CFBundleDisplayName</key><string>Vigía</string>
    <key>CFBundleIdentifier</key><string>io.github.gabriel-castiglia.vigia</string>
    <key>CFBundleExecutable</key><string>Vigia</string>
    <key>CFBundleIconFile</key><string>Vigia</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$COMPILACION</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleLocalizations</key><array><string>en</string><string>es</string></array>
    <key>NSHumanReadableCopyright</key><string>© 2026 Gabriel Castiglia · GPL-2.0-only</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>Markdown document</string>
            <key>CFBundleTypeRole</key><string>Editor</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>LSItemContentTypes</key><array><string>net.daringfireball.markdown</string></array>
            <key>CFBundleTypeExtensions</key><array><string>md</string><string>markdown</string><string>mdown</string><string>mkd</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST

# 4. Sign with the stable identity (see scripts/firma.sh). FIRMA=adhoc signs without it, for a
#    quick local test: macOS then asks again for folder permissions on every build.
if [[ "${FIRMA:-}" == adhoc ]]; then
    codesign --force --sign - --timestamp=none "$APP"
else
    preparar_firma
    codesign --force --sign "$IDENTIDAD" --keychain "$LLAVERO" --timestamp=none "$APP"
fi

echo "Built: $RAIZ/$APP (version $VERSION)"
# The copy built here stays out of the app registry, or Spotlight lists it next to the installed one (21-nov-2026).
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "${${:-$RAIZ/$APP}:A}" 2>/dev/null || true
