#!/usr/bin/env bash
# Bundle the web head with bun, copy it into the Swift target, build the app.
set -euo pipefail
cd "$(dirname "$0")"

command -v bun >/dev/null || { echo "bun not found: https://bun.sh" >&2; exit 1; }

out=Sources/HeadsUp/Resources/web
mkdir -p "$out"
# No --minify: the page is loaded from disk inside the app, so the 25 KB it
# saves buys nothing, and bun's minifier has been seen to emit colliding
# variable names for this bundle.
bun build web/src/main.ts --outfile "$out/app.js"
cp web/index.html "$out/index.html"
bin=$(swift build -c release --show-bin-path)
swift build -c release
echo "Built: $bin/HeadsUp"
