#!/usr/bin/env bash
# Wrap the built executable in HeadsUp.app and zip it for a release.
#
#   ./scripts/package-release.sh
#
# Signing and notarisation are optional and automatic: with a Developer ID in
# the keychain the bundle is signed, and with a notarytool profile named
# HeadsUp it is notarised and stapled. Without them you still get a working
# .app, and the script says plainly what is missing and what that costs the
# people who download it.
#
#   xcrun notarytool store-credentials HeadsUp \
#       --apple-id you@example.com --team-id TEAMID --password APP-SPECIFIC-PASSWORD
set -euo pipefail
cd "$(dirname "$0")/.."

version=$(tr -d '[:space:]' < VERSION)
[ -n "$version" ] || { echo "VERSION is empty" >&2; exit 1; }

./build.sh >/dev/null
bin=$(swift build -c release --show-bin-path)/HeadsUp
[ -x "$bin" ] || { echo "no binary at $bin" >&2; exit 1; }

out=dist
app="$out/HeadsUp.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

cp "$bin" "$app/Contents/MacOS/HeadsUp"
# The bundled resources sit beside the binary in the SwiftPM layout.
for bundle in "$(dirname "$bin")"/*.bundle; do
  [ -e "$bundle" ] && cp -R "$bundle" "$app/Contents/Resources/"
done

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>HeadsUp</string>
  <key>CFBundleDisplayName</key><string>HeadsUp</string>
  <key>CFBundleIdentifier</key><string>com.sudarshantechlabs.headsup</string>
  <key>CFBundleExecutable</key><string>HeadsUp</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$version</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <!-- No Dock icon: the head and the menu bar are the whole interface. -->
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>© 2026 SudarshanTechLabs. MIT.</string>
</dict>
</plist>
PLIST

identity=$(security find-identity -v -p codesigning 2>/dev/null \
  | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)

if [ -n "$identity" ]; then
  echo "signing as: $identity"
  codesign --force --options runtime --timestamp \
    --sign "$identity" "$app"
  codesign --verify --strict --verbose=2 "$app"
else
  echo "no Developer ID Application certificate in the keychain: shipping unsigned."
  echo "Gatekeeper will refuse this build on another Mac until it is signed and notarised."
fi

zip="$out/HeadsUp-$version-macOS.zip"
rm -f "$zip"
# ditto keeps the bundle's symlinks and metadata; plain zip does not.
/usr/bin/ditto -c -k --keepParent "$app" "$zip"

if [ -n "$identity" ] && xcrun notarytool history --keychain-profile HeadsUp >/dev/null 2>&1; then
  echo "notarising…"
  xcrun notarytool submit "$zip" --keychain-profile HeadsUp --wait
  xcrun stapler staple "$app"
  rm -f "$zip"
  /usr/bin/ditto -c -k --keepParent "$app" "$zip"
  echo "stapled."
elif [ -n "$identity" ]; then
  echo "no notarytool profile named HeadsUp: signed but not notarised."
  echo "See the header of this script for how to store one."
fi

echo "built: $zip"
echo "attach it with: gh release upload v$version $zip"
