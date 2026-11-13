#!/bin/zsh
# Builds, signs with Developer ID, notarizes, staples and publishes a GitHub release.
#   scripts/release.sh 1.0.0
#
# One-time setup:
#   1. A "Developer ID Application" certificate (Xcode → Settings → Accounts →
#      Manage Certificates → + → Developer ID Application).
#   2. Notarization credentials in the keychain:
#        xcrun notarytool store-credentials pulse-notary \
#          --apple-id you@example.com --team-id TEAMID --password <app-specific password>
set -euo pipefail
cd "${0:A:h}/.."

version=${1:?usage: scripts/release.sh <version>}
profile=${PULSE_NOTARY_PROFILE:-pulse-notary}
tag="v$version"

plist_version=$(plutil -extract CFBundleShortVersionString raw Support/Info.plist)
[[ $plist_version == "$version" ]] || { echo "Info.plist says $plist_version, not $version"; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "Commit your changes first."; exit 1; }
security find-identity -v -p codesigning | grep -q "Developer ID Application" \
  || { echo "No Developer ID Application certificate in the keychain."; exit 1; }

swift test
scripts/build-app.sh

mkdir -p dist
zip="dist/Pulse-$version.zip"
rm -f "$zip"
ditto -c -k --sequesterRsrc --keepParent build/Pulse.app "$zip"

echo "Notarizing…"
xcrun notarytool submit "$zip" --keychain-profile "$profile" --wait
xcrun stapler staple build/Pulse.app
xcrun stapler validate build/Pulse.app
spctl --assess --type execute --verbose build/Pulse.app

# Re-zip so the download carries the stapled ticket.
rm -f "$zip"
ditto -c -k --sequesterRsrc --keepParent build/Pulse.app "$zip"
shasum -a 256 "$zip" | tee "$zip.sha256"

git tag -a "$tag" -m "Pulse $version"
git push origin "$tag"
gh release create "$tag" "$zip" "$zip.sha256" \
  --title "Pulse $version" \
  --notes-file "${PULSE_RELEASE_NOTES:-/dev/stdin}"
