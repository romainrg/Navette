# Releasing

How a version of Navette is built and published. Nothing here happens without the author's explicit decision: no tag, no push and no GitHub release are created by tools or agents on their own.

## What a release contains

`make release` (or `scripts/build-release.sh`) builds the app in Release for Apple Silicon and Intel, signs it ad hoc with the hardened runtime, and writes into `build/release/`:

- `Navette-<version>.dmg`: the app and a link to `/Applications`;
- `Navette-<version>.pkg`: an unsigned installer that puts the app in `/Applications`;
- `SHA256SUMS`: the checksums of both.

The script checks along the way that the app and its `navette-askpass` helper are universal, that both carry the hardened runtime flag, that the signature verifies, and that the disk image mounts and contains what it should.

## Steps

1. Make sure `main` is green: `make test`, then `make integration` on a Mac with the local servers available.
2. Set the version: `MARKETING_VERSION` in `project.yml` (and `CURRENT_PROJECT_VERSION` when rebuilding the same version).
3. Move the entries of **Unreleased** in `CHANGELOG.md` under a new heading for the version, with the date.
4. Refresh the README images if the interface changed: `make screenshots`.
5. Commit, then run `make release` locally and go through the manual checklist below with the files it produced.
6. Tag `v<version>` and push the tag. The `Release` workflow checks that the tag matches `MARKETING_VERSION`, runs the tests, builds the DMG and the PKG, and publishes the GitHub release with the notes taken from the changelog (`scripts/release-notes.sh`).

## Signing

Release builds are signed **ad hoc** with the hardened runtime and are not notarized. The app has no entitlement; the helper inside it is signed with the same settings. Two consequences for users, both explained in the README:

- Gatekeeper blocks the first launch until the user clicks **Open Anyway** in System Settings > Privacy & Security.
- macOS ties Keychain access to the exact build, so it asks once for access to Navette's Keychain item after each update. Navette keeps all its secrets in a single item to keep this to one question.

## Verified for 0.1.0

Checked on 2026-11-10 on an Apple Silicon Mac with macOS 27.0.1 and Xcode 16.2, on the output of `make release`:

- `Navette-0.1.0.dmg` and `Navette-0.1.0.pkg` are produced (about 3.6 MB each); the app is about 10 MB.
- `lipo -archs` gives `x86_64 arm64` for the app and for `navette-askpass`.
- `codesign -dv` shows `flags=0x10002(adhoc,runtime)` for both; `codesign --verify --strict --deep` passes; the app has no entitlement.
- `Info.plist` has version `0.1.0`, the Local Network usage description and the App Transport Security exception that plain `http://` WebDAV needs.
- The askpass integration tests pass with the helper from the Release build (hardened runtime).
- The Release app launched with `--demo` stays up; it was quit after a few seconds.

Not verified by a person yet: everything in the checklist below.

## Manual checklist (before publishing)

Installation:

- [ ] Install from the DMG (drag `Navette.app` to `/Applications`) and launch it; Gatekeeper **Open Anyway** on a downloaded copy.
- [ ] Install the PKG over it (`sudo installer -pkg build/release/Navette-<version>.pkg -target /`) and check the version.
- [ ] After the PKG install, `find /Applications/Navette.app -name '._*'` prints nothing.

SFTP:

- [ ] Connect to a host defined in `~/.ssh/config` (alias, non-standard port, `ProxyJump`); the connection sheet shows the resolved values.
- [ ] First connection to an unknown host: the fingerprint sheet appears; accepting adds the key to `known_hosts`; refusing connects to nothing.
- [ ] A key with a passphrase: the sheet appears, "Remember in the Keychain" works on the next connection.
- [ ] A server with password login, and one with a one-time code.
- [ ] A FIDO key ("touch your key" banner), the 1Password or Secretive agent.
- [ ] A host whose key changed: Navette refuses and explains; nothing is written to `known_hosts`.
- [ ] macOS shows its Local Network question on the first LAN server.

FTP, FTPS and WebDAV:

- [ ] Plain FTP shows the "not encrypted" warnings. FTPS with a valid certificate; FTPS with a self-signed one (certificate sheet, then remembered for the bookmark).
- [ ] An FTPS server that requires session reuse shows the explanation.
- [ ] Nextcloud or ownCloud over https; a NAS over plain http.
- [ ] A wrong password asks again and is not saved.

Browser and transfers:

- [ ] Sort, filter, hidden files, back, forward, go to folder, a folder with several thousand entries.
- [ ] Drag a folder from Finder to the list; drag files and a folder from the list to Finder.
- [ ] Each conflict choice (overwrite, resume, rename, skip), with and without "apply to all".
- [ ] Pause, resume, cancel; cut the network during a large transfer, then Retry.
- [ ] Remote deletion: the sheet lists everything; the count and total match; Cancel deletes nothing.
- [ ] Rename, new folder, permissions (single file, then a folder with "apply to enclosed items").
- [ ] Names with accents, emoji, spaces and quotes, uploaded and downloaded, keep their exact spelling on both sides.

Quick Look and Open With:

- [ ] Space bar on an image, a PDF and a text file; the size question above 50 MB.
- [ ] Open With an editor: each save is uploaded; modify the file on the server in between and check the question.
- [ ] Close the tab: the cache folder is gone.

General:

- [ ] The French interface, light and dark.
- [ ] Bookmarks: folders, colors, move, duplicate, remove (the saved password is forgotten).
- [ ] After installing a new build over an old one, macOS asks once for the Keychain item, then passwords work.
- [ ] Quit during a transfer: no crash, the partial file is left for a manual cleanup or removed on cancel.

## Planned distribution channels

None of these is set up yet; each requires a paid Apple Developer Program membership.

- **Developer ID signing and notarization** of the GitHub releases, which removes the Gatekeeper warning and keeps Keychain access across updates.
- **Homebrew cask**, once releases are notarized.
