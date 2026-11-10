#!/usr/bin/env bash
# Builds Navette in Release (universal binary, ad hoc signed with hardened runtime) and writes
# build/release/Navette-<version>.dmg, Navette-<version>.pkg and SHA256SUMS. Used by CI and `make release`.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ -z "${DEVELOPER_DIR:-}" ] && [ "$(xcode-select -p)" = /Library/Developer/CommandLineTools ]; then
  xcode=$(ls -d /Applications/Xcode*.app 2>/dev/null | sort -V | tail -1)
  [ -n "$xcode" ] && export DEVELOPER_DIR="$xcode/Contents/Developer"
fi

version=$(sed -n 's/^ *MARKETING_VERSION: *"\(.*\)"/\1/p' project.yml)
if [ -z "$version" ]; then
  echo "MARKETING_VERSION not found in project.yml" >&2
  exit 1
fi

# MARK: - Build

xcodegen generate --quiet
xcodebuild -project Navette.xcodeproj -scheme Navette -configuration Release \
  -derivedDataPath build -destination 'generic/platform=macOS' -quiet build

app=build/Build/Products/Release/Navette.app
archs=$(lipo -archs "$app/Contents/MacOS/Navette")
if [[ "$archs" != *arm64* || "$archs" != *x86_64* ]]; then
  echo "Binary is not universal: $archs" >&2
  exit 1
fi

# Xcode drops the hardened runtime when signing ad hoc, so sign again with it.
codesign --force --options runtime --sign - "$app"
signature=$(codesign -dv "$app" 2>&1)
if ! grep -Eq 'flags=0x[0-9a-f]+\([^)]*runtime' <<<"$signature"; then
  echo "Hardened runtime flag missing from the signature" >&2
  exit 1
fi
codesign --verify --strict "$app"

out=build/release
dmg="Navette-$version.dmg"
pkg="Navette-$version.pkg"
mkdir -p "$out"
rm -rf "$out/dmg" "$out/pkgroot" "$out/pkgs" "$out/pkgres" "$out/$dmg" "$out/$pkg" "$out/SHA256SUMS" "$out/distribution.xml"

# MARK: - DMG

staging="$out/dmg"
mkdir "$staging"
ditto "$app" "$staging/Navette.app"
ln -s /Applications "$staging/Applications"

# On GitHub runners hdiutil sometimes fails with "Resource busy": retry.
create_dmg() {
  hdiutil create -quiet -volname Navette -srcfolder "$staging" -fs HFS+ \
    -format UDZO -imagekey zlib-level=9 -ov "$out/$dmg"
}
create_dmg || { echo "DMG creation failed, retrying in 5 s" >&2; sleep 5; create_dmg; } \
  || { echo "DMG creation failed again, retrying in 15 s" >&2; sleep 15; create_dmg; }
rm -rf "$staging"

hdiutil verify -quiet "$out/$dmg"
mountpoint=$(mktemp -d)
detach_image() {
  local attempt
  for attempt in 1 2 3; do
    hdiutil detach -quiet "$mountpoint" 2>/dev/null && return 0
    sleep 2
  done
  hdiutil detach -quiet -force "$mountpoint"
}
trap 'detach_image 2>/dev/null || true; rmdir "$mountpoint" 2>/dev/null || true' EXIT
hdiutil attach -quiet -readonly -nobrowse -mountpoint "$mountpoint" "$out/$dmg"
codesign --verify --strict "$mountpoint/Navette.app"
if [ "$(readlink "$mountpoint/Applications")" != /Applications ]; then
  echo "Applications link missing from the disk image" >&2
  exit 1
fi
detach_image

# MARK: - PKG (unsigned)

mkdir "$out/pkgroot" "$out/pkgs" "$out/pkgres"
# Stage without resource forks, extended attributes or quarantine flags.
ditto --norsrc --noextattr --noqtn "$app" "$out/pkgroot/Navette.app"
codesign --verify --strict "$out/pkgroot/Navette.app"
cp LICENSE "$out/pkgres/LICENSE.txt"
sed "s/@VERSION@/$version/g" packaging/distribution.xml > "$out/distribution.xml"

COPYFILE_DISABLE=1 pkgbuild --quiet --root "$out/pkgroot" --component-plist packaging/component.plist \
  --install-location /Applications --identifier io.github.romainrg.Navette.pkg \
  --version "$version" "$out/pkgs/Navette-component.pkg"
productbuild --quiet --distribution "$out/distribution.xml" --package-path "$out/pkgs" \
  --resources "$out/pkgres" "$out/$pkg"
rm -rf "$out/pkgroot" "$out/pkgs" "$out/pkgres" "$out/distribution.xml"

# MARK: - Checksums

(cd "$out" && shasum -a 256 "$dmg" "$pkg" > SHA256SUMS)

echo "$out/$dmg $out/$pkg ($archs)"
