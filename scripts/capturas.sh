#!/bin/zsh
# capturas.sh: draws the pictures of the manuals (docs/img) with the app itself.
#
# Copyright (C) 2026 Gabriel Castiglia. Licensed under the GNU GPL, version 2 only.
# Date: November 10, 2026
# SPDX-License-Identifier: GPL-2.0-only
#
# This program is free software: you can redistribute it and/or modify it under the terms of
# the GNU General Public License, version 2, as published by the Free Software Foundation.
# It is distributed WITHOUT ANY WARRANTY. See the LICENSE file for details.
#
# Uses build/Vigia.app (scripts/compilar.sh) and the sample document. The screenshot mode
# never reads or writes the app's settings.

set -euo pipefail
RAIZ="${0:A:h:h}"
cd "$RAIZ"
B=build/Vigia.app/Contents/MacOS/Vigia
[[ -x $B ]] || { echo "build the app first: scripts/compilar.sh" >&2; exit 1 }
mkdir -p docs/img
for idioma in en es ja; do
    $B --screenshot docs/img/visual-$idioma.png --lang $idioma --theme light --mode visual
    $B --screenshot docs/img/github-$idioma.png --lang $idioma --theme dark --mode preview
    $B --screenshot docs/img/theme-$idioma.png --view theme --lang $idioma --theme light
    # the panes on both sides of the text, and the layout button's panel (3.1.0)
    $B --screenshot docs/img/layout-$idioma.png --lang $idioma --theme light --mode visual --layout LayoutSplitFiles --folder "$RAIZ/samples"
    $B --screenshot docs/img/layouts-$idioma.png --view layouts --lang $idioma --theme light --layout LayoutSplitFiles
done
