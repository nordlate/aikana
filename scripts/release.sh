#!/bin/bash
# Builds a signed, notarized disk image of Aikana.
#
#   scripts/release.sh 0.2.0
#
# Output: build/release/<version>/Aikana-<version>.dmg, plus the archive and
# the exported app beside it, and appcast.xml in the repo updated with the new
# version, ready for its own PR. Stops at the first error.
#
# Needs, on this Mac (see RELEASING.md):
# - the team's Developer ID Application certificate in the Keychain,
# - a notarytool Keychain profile, named aikana-notary unless
#   AIKANA_NOTARY_PROFILE names another,
# - Sparkle's private signing key in the Keychain, under the account aikana
#   unless AIKANA_SPARKLE_ACCOUNT names another.
set -euo pipefail

version="${1:-}"
if [ -z "$version" ]; then
    echo "usage: scripts/release.sh <version>   (for example 0.2.0)" >&2
    exit 64
fi

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

profile="${AIKANA_NOTARY_PROFILE:-aikana-notary}"
sparkle_account="${AIKANA_SPARKLE_ACCOUNT:-aikana}"
repository="https://github.com/nordlate/aikana"
project="Aikana.xcodeproj"
packages="build/SourcePackages"
sparkle_bin="$packages/artifacts/sparkle/Sparkle/bin"
team="$(sed -n 's/^[[:space:]]*DEVELOPMENT_TEAM = \([A-Z0-9]*\);$/\1/p' "$project/project.pbxproj" | sort -u)"
out="build/release/$version"
archive="$out/Aikana.xcarchive"
export_dir="$out/export"
app="$export_dir/Aikana.app"
dmg="$out/Aikana-$version.dmg"

step() {
    echo
    echo "==> $*"
}

# Sends a file to Apple's notary service, waits, and fails unless it was accepted.
notarize() {
    local file="$1" result status id
    result="$(xcrun notarytool submit "$file" --keychain-profile "$profile" --wait --output-format json)"
    status="$(printf '%s' "$result" | plutil -extract status raw -o - - 2>/dev/null || true)"
    id="$(printf '%s' "$result" | plutil -extract id raw -o - - 2>/dev/null || true)"
    echo "notarization of $(basename "$file"): ${status:-no status} (${id:-no id})"
    if [ "$status" != "Accepted" ]; then
        if [ -n "$id" ]; then
            xcrun notarytool log "$id" --keychain-profile "$profile" >&2 || true
        else
            echo "$result" >&2
        fi
        echo "error: notarization of $file was not accepted" >&2
        exit 1
    fi
}

step "Checking versions"
scripts/check-version.sh "v$version"

if [ "$(printf '%s\n' "$team" | wc -l)" -ne 1 ] || [ -z "$team" ]; then
    echo "error: expected one DEVELOPMENT_TEAM in $project, found: $(echo $team)" >&2
    exit 1
fi

# The Developer ID identity of the project's team, by its SHA-1, so no name is written down here.
identity="$(security find-identity -v -p codesigning \
    | grep "\"Developer ID Application: .*($team)\"" \
    | awk '{ print $2 }' | head -n 1 || true)"
if [ -z "$identity" ]; then
    echo "error: no Developer ID Application certificate for team $team in the Keychain" >&2
    exit 1
fi

if ! xcrun notarytool history --keychain-profile "$profile" > /dev/null 2>&1; then
    echo "error: notarytool profile \"$profile\" does not work; see RELEASING.md" >&2
    exit 1
fi

step "Checking the update signing key"
xcodebuild -resolvePackageDependencies -project "$project" -scheme Aikana \
    -clonedSourcePackagesDirPath "$packages" -quiet
# generate_keys -p prints the public half of the key in the Keychain; it must be the one the app trusts.
signing_key="$("$sparkle_bin/generate_keys" --account "$sparkle_account" -p 2>/dev/null || true)"
trusted_key="$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" Aikana/Info.plist)"
if [ -z "$signing_key" ]; then
    echo "error: no Sparkle signing key for account \"$sparkle_account\" in the Keychain; see RELEASING.md" >&2
    exit 1
fi
if [ "$signing_key" != "$trusted_key" ]; then
    echo "error: the Sparkle key in the Keychain does not match SUPublicEDKey in Aikana/Info.plist" >&2
    exit 1
fi

rm -rf "$out"
mkdir -p "$out"

step "Archiving"
xcodebuild archive \
    -project "$project" -scheme Aikana -configuration Release \
    -destination 'generic/platform=macOS' \
    -clonedSourcePackagesDirPath "$packages" \
    -archivePath "$archive" \
    -quiet

step "Exporting with Developer ID"
xcodebuild -exportArchive \
    -archivePath "$archive" \
    -exportPath "$export_dir" \
    -exportOptionsPlist scripts/ExportOptions.plist \
    -quiet

step "Notarizing the app"
ditto -c -k --keepParent "$app" "$out/Aikana-app.zip"
notarize "$out/Aikana-app.zip"
rm "$out/Aikana-app.zip"
xcrun stapler staple "$app"

step "Building the disk image"
staging="$out/dmg"
mkdir -p "$staging"
ditto "$app" "$staging/Aikana.app"
ln -s /Applications "$staging/Applications"
hdiutil create -volname "Aikana" -srcfolder "$staging" -fs HFS+ -format UDZO -ov "$dmg" -quiet
rm -rf "$staging"
codesign --sign "$identity" --timestamp "$dmg"

step "Notarizing the disk image"
notarize "$dmg"
xcrun stapler staple "$dmg"

step "Verifying"
codesign --verify --deep --strict --verbose=2 "$app"
codesign --verify --strict --verbose=2 "$app/Contents/Helpers/aikana"
spctl --assess --type exec --verbose=2 "$app"
xcrun stapler validate "$app"
codesign --verify --verbose=2 "$dmg"
spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"
xcrun stapler validate "$dmg"

helper_version="$("$app/Contents/Helpers/aikana" --version)"
if [ "$helper_version" != "aikana $version" ]; then
    echo "error: the bundled tool reports \"$helper_version\", expected \"aikana $version\"" >&2
    exit 1
fi

# After stapling: stapling changes the image, and the signature in the appcast is over its final bytes.
step "Adding the version to appcast.xml"
feed="$out/appcast"
mkdir -p "$feed"
cp appcast.xml "$feed/appcast.xml"
cp "$dmg" "$feed/"
"$sparkle_bin/generate_appcast" \
    --account "$sparkle_account" \
    --download-url-prefix "$repository/releases/download/v$version/" \
    --link "$repository" \
    --maximum-deltas 0 \
    -o "$feed/appcast.xml" \
    "$feed"
cp "$feed/appcast.xml" appcast.xml

step "Done"
shasum -a 256 "$dmg"
echo
echo "Next: attach $dmg to the v$version release and publish it, then open a PR with the change to appcast.xml."
