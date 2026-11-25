#!/bin/zsh
# web.sh: rebuilds the web bundle (web/lib) from _npm, as the Windows version does.
#
# Copyright (C) 2026 Gabriel Castiglia. Licensed under the GNU GPL, version 2 only.
# Date: November 10, 2026
# SPDX-License-Identifier: GPL-2.0-only
#
# This program is free software: you can redistribute it and/or modify it under the terms of
# the GNU General Public License, version 2, as published by the Free Software Foundation.
# It is distributed WITHOUT ANY WARRANTY. See the LICENSE file for details.
#
# Needs Node.js with npm. The bundle in the repository was made this way, with the exact
# versions of _npm/package-lock.json; the app only needs web/, so building it is optional.

set -euo pipefail
RAIZ="${0:A:h:h}"
cd "$RAIZ/_npm"
command -v npm >/dev/null || { echo "npm is missing (Node.js)" >&2; exit 1 }
npm ci --silent
W="$RAIZ/web/lib"
mkdir -p "$W/fonts"
npx esbuild entry.js --bundle --minify --format=iife --outfile="$W/bundle.js"
# every highlight.js language, loaded only when a code block needs one bundle.js lacks (app.js runRareCode; 3.3.0)
npx esbuild hljs-all.js --bundle --minify --format=iife --outfile="$W/hljs-all.js"
# TOAST UI 3.2.2 reads the first row of a <tbody> without checking that there is one, so a table with an
# empty <tbody> (pandoc writes one for every one-row table) threw and left the page blank. Patched here;
# the build stops if the code it fixes is not found exactly once.
perl -0777 -pi -e '$n += s/var (\w+)=(\w+)\.querySelectorAll\("tr"\),(\w+)=\1\[0\]\.children\.length/var ${1}=${2}.querySelectorAll("tr"),${3}=${1}.length?${1}[0].children.length:0/g; END { exit($n == 1 ? 0 : 3) }' "$W/bundle.js" \
    || { echo "TOAST UI <tbody> patch: the code to fix was not found once in bundle.js" >&2; exit 1 }
# Properties at the top: TOAST UI takes a first line --- (+++ or ;;;) as the start of a front matter block even when
# nothing closes it, and the whole document went into one hidden block. The rule also asks window.gmFrontMatter,
# which app.js sets from its own test (closed, and with a key); same stop as above (build.ps1 does the same).
perl -0777 -pi -e '$n += s/(\w+)\.type==="document"&&(\w+)\.test\((\w+)\)\)\{(\w+)\.closeUnmatchedBlocks\(\);var (\w+)=\4\.addChild\("frontMatter"/window.gmFrontMatter!==false&&$&/g; END { exit($n == 1 ? 0 : 3) }' "$W/bundle.js" \
    || { echo "TOAST UI front matter patch: the code to fix was not found once in bundle.js" >&2; exit 1 }
nm=node_modules
cp $nm/@toast-ui/editor/dist/toastui-editor.css $nm/@toast-ui/editor/dist/theme/toastui-editor-dark.css \
   $nm/@toast-ui/editor-plugin-code-syntax-highlight/dist/toastui-editor-plugin-code-syntax-highlight.css \
   $nm/github-markdown-css/github-markdown-light.css $nm/github-markdown-css/github-markdown-dark.css "$W/"
cp $nm/highlight.js/styles/github.min.css "$W/hljs-light.css"
cp $nm/highlight.js/styles/github-dark.min.css "$W/hljs-dark.css"
cp $nm/mermaid/dist/mermaid.min.js $nm/katex/dist/katex.min.css "$W/"
cp $nm/katex/dist/fonts/*.woff2 "$W/fonts/"
echo "web bundle rebuilt in web/lib"
