#!/bin/zsh
# Builds Pulse.app (release) into ./build and signs it.
#   scripts/build-app.sh            build only
#   scripts/build-app.sh --install  also copy to /Applications and relaunch
#
# Signing uses the first "Apple Development" identity when there is one, so the
# signature stays stable across rebuilds and Keychain doesn't ask again for the
# stored keys. Without one it falls back to ad-hoc signing.
set -euo pipefail
cd "${0:A:h}/.."

swift build -c release --product Pulse
bin="$(swift build -c release --show-bin-path)/Pulse"

app=build/Pulse.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/Pulse"
cp Support/Info.plist "$app/Contents/Info.plist"
[[ -f Support/AppIcon.icns ]] && cp Support/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"

identity="$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')"
codesign --force --options runtime --timestamp=none --sign "${identity:--}" "$app"
echo "Built $app (signed: ${identity:-ad-hoc})"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x Pulse 2>/dev/null || true
  rm -rf /Applications/Pulse.app
  cp -R "$app" /Applications/Pulse.app
  open /Applications/Pulse.app
  echo "Installed /Applications/Pulse.app"
fi
