#!/usr/bin/env bash
# Prints the GitHub release notes: the CHANGELOG.md section for the requested version,
# followed by the install steps.
# Usage: scripts/release-notes.sh 0.1.0   (or Unreleased)
set -euo pipefail
cd "$(dirname "$0")/.."

version="${1:?usage: scripts/release-notes.sh <version|Unreleased>}"

notes=$(awk -v version="$version" '
  index($0, "## [" version "]") == 1 { found = 1; next }
  found && (/^## \[/ || /^\[[^]]+\]: /) { exit }
  found { print }
' CHANGELOG.md)

if [ -z "${notes//[[:space:]]/}" ]; then
  echo "No non-empty section \"## [$version]\" in CHANGELOG.md" >&2
  exit 1
fi

cat <<EOT
$notes

## Install

Pick one of the two installers below.

- **DMG**: download \`Navette-$version.dmg\`, open it and drag **Navette** onto the **Applications** folder.
- **PKG**: download \`Navette-$version.pkg\`, double-click it and follow the installer. It always installs into \`/Applications\`.

Navette is not notarized. On first open, macOS blocks it: open **System Settings › Privacy & Security** and click **Open Anyway**, or run \`xattr -dr com.apple.quarantine /Applications/Navette.app\` (for the PKG, run it on the downloaded \`.pkg\` file before opening it).

Verify the downloads with \`shasum -a 256 -c SHA256SUMS\`.
EOT
