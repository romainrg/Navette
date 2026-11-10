# AGENTS.md

Instructions for AI coding agents (Claude Code, Codex, GitHub Copilot, Cursor, Gemini...) working on Navette. Humans should read [CONTRIBUTING.md](CONTRIBUTING.md); this file summarizes the same rules in an actionable form.

## Project

Navette is a free, open-source file transfer client for macOS: SFTP, FTP, FTPS and WebDAV in 0.1, with a file browser, a transfer queue, bookmarks, Quick Look and "Open With". Swift and SwiftUI (AppKit where needed), macOS 14+, universal binary, not sandboxed, no third-party dependencies, English and French. It is the third app of the `romainrg` family after Mopster and Copicol, and shares their conventions.

Scope and decisions are in [docs/specs/0.1.md](docs/specs/0.1.md), the increments in [docs/plans/0.1.md](docs/plans/0.1.md), and what the spikes found in [docs/spikes/0.1-findings.md](docs/spikes/0.1-findings.md).

## Commands

Run them from the repository root. The `Makefile` finds Xcode even when `xcode-select` points to the Command Line Tools. XcodeGen is required (`brew install xcodegen`).

```sh
make generate                              # xcodegen generate; after adding, removing or renaming a file, or editing project.yml
make build                                 # Debug build
make test                                  # all unit tests through xcodebuild, then make check-strings
make core-test                             # NavetteCore tests only, with swift test (faster)
make core-test FILTER=TransferEngineTests  # one test class
make integration                           # tests against local development servers (see below); never part of make test or CI
make integration FILTER=IntegrationTests/testFTPDriverContract
make check-strings                         # every string the compiler extracted has a French translation in the catalog
make run                                   # build and open the app
make demo                                  # launch with --demo: in-memory servers, no network, no disk
make screenshots                           # render the README scenes offscreen into docs/images
make release                               # universal build; writes build/release/Navette-<v>.dmg, .pkg and SHA256SUMS
make clean
```

`make check-strings` reads the compiler output of the last Debug build: run `make build` first (`make test` does it for you).

`scripts/screenshots.sh build/screenshots [filter] [--language fr]` renders every scene (or those matching the filter) for review.

### Integration servers

`make integration` starts servers as the current user, on high ports, in a temporary folder removed at the end. It changes no system setting.

- SFTP: `/usr/sbin/sshd` with a temporary host key. The askpass tests need the helper built by `make build`.
- WebDAV: `/usr/sbin/httpd` with `mod_dav`.
- FTP: `vsftpd` from Homebrew (`brew install vsftpd`), which is built without TLS. FTPS tests run only when `NAVETTE_IT_VSFTPD_TLS` points to a TLS-enabled build of vsftpd (see the spike findings for how to make one).

## Map

- `project.yml`: XcodeGen spec and source of truth. `Navette.xcodeproj` and `Navette/Resources/Info.plist` are generated and git-ignored.
- `NavetteCore/Sources/NavetteCore/`: all the logic, with no SwiftUI or AppKit.
  - `Model/`: `RemotePath` (raw bytes), `RemoteItem`, `PermissionSet`, the `RemoteFileSystem` protocol, `Capabilities`, `RemoteError`, `InMemoryFileSystem`.
  - `SFTP/`: SFTP v3 codec and client, `SSHCommand` (argument arrays), `SSHTransport`, `SSHFailure`, `SSHConfigResolver` (`ssh -G`), `AskpassPrompt` and `AskpassServer`.
  - `FTP/`: reply and listing parsers (`MLSD`, Unix and DOS `LIST`), `FTPStream` (Network.framework, explicit TLS framer), `FTPFileSystem`.
  - `WebDAV/`: PROPFIND parser, URL encoding, `WebDAVFileSystem` (URLSession), `CertificateInspector`.
  - `Transfers/`: `TransferEngine`, `TransferPlanner`, `RemoteEnumerator`, `RemoteDeleter`, `PermissionChanger`, `LocalFiles` (`DiskFiles`, `SimulatedFiles`), `EditSession`, `FolderWatcher`.
  - `Bookmarks/`: `Bookmark`, `BookmarkLibrary`, `BookmarkStore`, `ConnectionURL`, `ServerProtocol`.
  - `Support/`: `CredentialStore` (Keychain, one item), `ProcessRunner`, `RuntimeDirectory`.
- `NavetteCore/Tests/NavetteCoreTests/`: XCTest suites. `TestSupport.swift` holds `HostileNames` and `DriverContract`, the behavior every driver must share. `IntegrationTests.swift` is skipped unless `make integration` set its environment.
- `Navette/`: app target.
  - `App/`: `AppEnvironment` (live and demo services), `AppModel`, `Connector` (opens connections), `PromptCenter` (password, host key and certificate questions), `AppSettings`, `ContentView`, `Commands`.
  - `Browser/`: `BrowserModel` (one tab), `BrowserView`, `FileTableView` (`NSTableView`), `InspectorView`, `DeletionSheet`, `EditCoordinator` (Quick Look, Open With).
  - `Connection/`: `ConnectionSheet`, `PromptSheet`. `Sidebar/`, `Transfers/`, `Settings/`.
  - `Shared/`: `Theme` (`ThemeGround`, `glassPanel` and `themeCard`, `Tint` for protocols, `FileKind` tiles and transfer states, `ProgressRing`, `GradientBar`, `.gradient`, `.soft` and `.toolbarIcon` buttons, `PermissionToggleStyle`), `Formatting` (sizes, dates, `RemoteError.message`), `QuickLook`.
  - `Demo/`: sample bookmarks, servers and transfers.
  - `Resources/`: `Localizable.xcstrings`, `Assets.xcassets`.
- `Tools/Askpass/`: `navette-askpass`, the helper `ssh` runs to ask questions. It ships inside the app, next to its executable.
- `Tools/Screenshots/`: offscreen renderer for the README images (development only, never shipped); scenes in `Scenes.swift`.
- `scripts/`: release build, release notes, strings check, screenshots, integration servers, icon.
- `docs/ARCHITECTURE.md`: layers, data flow, safety model. Read it before touching a driver, the transfer engine or anything that deletes.

## Invariants

Never break these. If a task seems to require it, stop and ask the human.

1. **Nothing destructive unseen.** A remote deletion (permanent: servers have no Trash) or an overwrite is confirmed with the list of items and their total. `RemoteDeleter` deletes exactly the listed tree: a folder that received new content is left in place and reported. WebDAV `DELETE` on a collection is only sent after checking it is empty.
2. **On the Mac, deleting means the Trash** (`LocalFiles.trash`, backed by `FileManager.trashItem`), including a local file replaced by a download. The only direct removals are Navette's own `.navette-part` files and its cache folder.
3. **Explicit trust.** A changed SSH host key is never accepted: Navette shows the fingerprint and how to fix it, and never edits `known_hosts` (only `ssh` appends to it, when the user accepts a new host). A TLS certificate the system does not trust is refused until the user has seen it and trusted exactly that certificate (`trustedCertificateSHA256`). FTPS never falls back to clear text.
4. **Secrets.** Passwords and passphrases live only in the Keychain (`KeychainCredentialStore`, a single item) and in memory. They never appear in a log, an error message, a bookmark file or a URL shown to the user. One-time codes are never stored.
5. **Network.** Navette contacts only the servers the user configured. No telemetry, no analytics, no update check.
6. **Safe transfers.** Uploads go to `.<name>.navette-part` and are renamed over the target once the size is verified; downloads go to `<name>.navette-part`. Resume only happens when the source is unchanged. A cancelled transfer leaves no partial file. `TransferEngineTests` encodes these rules: extend it, never weaken it.
7. **Paths are data.**
   - `Process` arguments are always an array, never a shell string. Hosts and users are validated (`ConnectionURL.isValidHost`) and the host always follows `--`.
   - Names are raw bytes end to end (`RemotePath`). Unicode normalization is used to compare and sort (`NameComparison`), never to rewrite: on the Mac side exact names go through `LocalFiles.exactName`/`entries` and `move(exactName:)`, because Foundation decomposes file names on its own.
   - Recursive enumeration never follows a symlink. Names a server sends are filtered (`..`, slashes, NUL) before they become local paths (`TransferPlanner.isSafeName`).
8. **No third-party dependency, no new entitlement, no signing change** without the author's approval. Apple frameworks and tools shipped with macOS only (`/usr/bin/ssh`). `NavetteCore` imports Foundation, Network, Security, CryptoKit and Darwin, never SwiftUI or AppKit. Only public API: the two non-public TLS functions found by the FTPS spike are not used.
9. **Not sandboxed, hardened runtime on, ad hoc signed.** The bundle identifier is `io.github.romainrg.Navette`. The app has no entitlement. The askpass helper is signed with the same settings by `scripts/build-release.sh`.
10. **Localization.** English is the source language and French is complete. Every user-facing string goes through `Localizable.xcstrings`.
11. **Author hygiene.** Nothing in code, metadata, docs, screenshots or commits mentions an employer or any company. Only "Romain Gallien" and the `romainrg` account appear. The repository's local git identity is the `romainrg` noreply address: never commit with another one.
12. **Demo isolation.** Demo mode goes through `AppEnvironment.demo()` only: no network, no disk, no Keychain.
13. **Both READMEs stay in sync**: `README.md` and `README.fr.md` have the same sections in the same order.

## Conventions

- Code comments and documentation in **English**, identifiers in English. Keep comments minimal: code should explain itself.
- Logic and rules in `NavetteCore`; views, view models and macOS integration in `Navette/`. View models are `@MainActor @Observable`, with no new singletons.
- A protocol driver implements `RemoteFileSystem` and must pass `DriverContract.run` in the integration tests. Errors are mapped to `RemoteError` cases the app can explain; server text goes in the associated value.
- **Strings are added by hand.** xcodebuild does not add new keys to `Localizable.xcstrings`. Add each key in the exact format the compiler extracts (for example `%lld items`, `Rename “%@”`) with a complete French value, then run `make build && make check-strings`. Counts use plural variations. Text that must not be translated uses `Text(verbatim:)` or a non-literal `String`.
- French uses non-breaking spaces inside « » and before `:`, `?` and `!`.
- Put `#Preview` blocks **last** in a file: `check-strings` ignores strings after the first `#Preview`.
- Zero build warnings. 4-space indentation, `// MARK: -` sections (see `.editorconfig`). Swift 5 language mode: regular expression literals are written `#/.../#`.
- Conventional Commits: `feat:`, `fix:`, `build:`, `ci:`, `docs:`, `test:`, `chore:`. One branch and one pull request per increment.

## Add a protocol driver

1. **Core.** Implement `RemoteFileSystem` in `NavetteCore/Sources/NavetteCore/<Protocol>/`, with parsers as pure functions tested on fixtures. Declare honest `Capabilities`: the views hide what a protocol cannot do.
2. **Integration.** Add a server to `scripts/integration.sh` and a `DriverContract.run` test in `IntegrationTests.swift`, plus a transfer through `TransferEngine`.
3. **Connector.** Add the case to `ServerProtocol` (default port, schemes, tint and symbol in `Theme.swift`) and open it in `LiveConnector`; `DemoConnector` needs nothing.
4. **Strings, scenes, docs.** French strings, a connection sheet scene in `Tools/Screenshots/Scenes.swift`, both READMEs, `CHANGELOG.md`, `docs/ARCHITECTURE.md`.

## Definition of done

- `make test` passes (unit tests and `make check-strings`) with no new warnings. Driver changes also pass `make integration`.
- Logic changes have unit tests in `NavetteCoreTests`; bug fixes include a regression test that fails without the fix.
- New strings exist in French. UI changes were rendered with `scripts/screenshots.sh` and the PNGs were opened and checked in light, dark and French.
- Never test against a server you do not own, and never delete on a real server while testing: use `make integration` or `make demo`.
- Do not trigger permission prompts (Keychain, Local Network) or drive the UI through automation; list manual test steps for the human.
- User-visible changes have an entry under **Unreleased** in `CHANGELOG.md`. Documentation (both READMEs, `docs/`, this file) is updated when commands, behavior or rules change.
- Do not push, create tags, releases or the GitHub repository, bump versions, or edit the release workflow or signing settings unless explicitly asked, each time.
- Pull requests follow `.github/PULL_REQUEST_TEMPLATE.md`, including the *AI assistance* section.
