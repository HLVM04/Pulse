#!/bin/zsh
# Builds Pulse.app (release) into ./build and signs it.
#   scripts/build-app.sh            build only
#   scripts/build-app.sh --install  also copy to /Applications and relaunch
#
# Signing: PULSE_SIGN_IDENTITY if set, else the first "Developer ID Application"
# identity, else the first "Apple Development" one, else ad hoc. A stable
# identity keeps Keychain from asking again for the stored keys after a rebuild.
set -euo pipefail
cd "${0:A:h}/.."

swift build -c release --product Pulse
bin="$(swift build -c release --show-bin-path)/Pulse"

app=build/Pulse.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/Pulse"
cp Support/Info.plist "$app/Contents/Info.plist"
cp Support/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"

identities="$(security find-identity -v -p codesigning)"
identity="${PULSE_SIGN_IDENTITY:-}"
[[ -z $identity ]] && identity="$(awk -F'"' '/Developer ID Application/ {print $2; exit}' <<<"$identities")"
[[ -z $identity ]] && identity="$(awk -F'"' '/Apple Development/ {print $2; exit}' <<<"$identities")"

if [[ $identity == "Developer ID Application"* ]]; then
  # Notarization needs the hardened runtime and a secure timestamp.
  codesign --force --options runtime --timestamp --sign "$identity" "$app"
else
  codesign --force --options runtime --timestamp=none --sign "${identity:--}" "$app"
fi
codesign --verify --strict "$app"
echo "Built $app (signed: ${identity:-ad hoc})"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x Pulse 2>/dev/null || true
  rm -rf /Applications/Pulse.app
  cp -R "$app" /Applications/Pulse.app
  open /Applications/Pulse.app
  echo "Installed /Applications/Pulse.app"
fi
