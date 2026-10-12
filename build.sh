#!/usr/bin/env bash
# Bundle the web head with bun, copy it into the Swift target, build the app.
set -euo pipefail
cd "$(dirname "$0")"

command -v bun >/dev/null || { echo "bun not found: https://bun.sh" >&2; exit 1; }

out=Sources/HeadsUp/Resources/web
mkdir -p "$out"
bun build web/src/main.ts --outfile "$out/app.js" --minify
cp web/index.html "$out/index.html"
swift build -c release
echo "Built: $(swift build -c release --show-bin-path)/HeadsUp"
