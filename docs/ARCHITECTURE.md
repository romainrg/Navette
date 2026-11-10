# Architecture

This document explains how Navette is built: its layers, how a connection and a transfer flow through them, and the safety model. Read it before changing a driver, the transfer engine or anything that deletes. Commands and contribution rules are in [CONTRIBUTING.md](../CONTRIBUTING.md) and [AGENTS.md](../AGENTS.md).

## Overview

- **Platform**: macOS 14 or later, universal binary, not sandboxed (it runs `/usr/bin/ssh` and reads `~/.ssh`), hardened runtime, ad hoc signed, no entitlement.
- **Stack**: Swift in Swift 5 language mode, SwiftUI with AppKit where needed. Apple frameworks and tools shipped with macOS only, no third-party dependency.
- **Project**: `project.yml` (XcodeGen) generates `Navette.xcodeproj`. All logic lives in a local Swift package, `NavetteCore`, which has no SwiftUI or AppKit and is tested without a host app.
- **Pattern**: MVVM with `@Observable`. Services are reached through `AppEnvironment`, which has a live and a demo variant.

## Layers

| Layer | Location | Responsibility |
|---|---|---|
| Core model | `NavetteCore/.../Model` | `RemotePath`, `RemoteItem`, the `RemoteFileSystem` protocol, `RemoteError`, the in-memory driver |
| Drivers | `NavetteCore/.../SFTP`, `FTP`, `WebDAV` | One `RemoteFileSystem` per protocol |
| Transfers | `NavetteCore/.../Transfers` | `TransferEngine`, planning, recursive enumeration, deletion, the Mac side of transfers, edit sessions |
| Bookmarks | `NavetteCore/.../Bookmarks`, `Support` | Bookmark tree and file, URL parsing, credential store |
| App | `Navette/App` | `AppEnvironment`, `AppModel`, `Connector`, `PromptCenter`, window and menus |
| Features | `Navette/Browser`, `Connection`, `Sidebar`, `Transfers`, `Settings` | Views and view models |
| Shared views | `Navette/Shared` | `Theme`, formatting, Quick Look |
| Demo | `Navette/Demo` | Sample bookmarks, servers and transfers |
| Helper | `Tools/Askpass` | `navette-askpass`, run by `ssh` |
| Screenshots | `Tools/Screenshots` | Offscreen renderer for the README images; never shipped |

## The common protocol

Every driver implements `RemoteFileSystem`: `home`, `list`, `stat` (never following symlinks), `read(offset:)`, `write(offset:size:)`, `makeDirectory`, `rename(overwrite:)`, `removeFile`, `removeDirectory`, `setPermissions`, `disconnect`. A `Capabilities` value says what the server can do (permissions, ownership, atomic replace, resume in each direction); views hide what is missing.

`RemotePath` stores the **raw bytes** of a path. SFTP v3 and FTP guarantee no encoding, so decoding and re-encoding a name could change it. Names are decoded only for display. Comparison and sorting use an NFC-normalized key (`NameComparison`); the bytes sent back are always the original ones.

`DriverContract` in the tests is the behavior all drivers share: hostile names round-trip byte for byte, offsets, missing items, rename with and without overwrite, non-empty folder removal. It runs against the in-memory driver in unit tests and against real servers in `make integration`.

### SFTP

Navette does not implement SSH. It launches the system's `/usr/bin/ssh -s -- <host> sftp` and speaks SFTP version 3 over the process's stdin and stdout, as sshfs does. Everything `ssh` knows comes for free: `~/.ssh/config`, `ProxyJump`, agents, FIDO keys, certificates, `known_hosts`.

- `SSHCommand` builds the argument array. The host is validated and always follows `--`; no option touches the user's trust settings.
- `SFTPClient` matches replies to requests by id, so many requests are in flight at once. Reads and writes are pipelined (16 requests of the size the server advertises through `limits@openssh.com`), which bounds memory to a few megabytes per transfer.
- `ssh` asks its questions (new host key, password, passphrase, one-time code) through `SSH_ASKPASS`. The helper `navette-askpass` forwards each question over a private Unix socket to `AskpassServer`, which routes it by a per-connection token to the app's `PromptCenter`. `AskpassPrompt.classify` turns the text into a typed prompt; anything unrecognized is shown as is.
- When the user has no `ControlMaster` of their own, Navette adds a private control socket in `/tmp/navette-<uid>` so that the browsing and transfer channels share one login.
- When `ssh` exits, `SSHFailure.classify` turns its stderr into a `RemoteError` (changed host key, refused login, unreachable host).

### FTP and FTPS

Network.framework. Explicit TLS uses a protocol framer below TLS that reads the greeting, sends `AUTH TLS` and, on `234`, inserts TLS on the live connection; if the server refuses, the connection fails rather than continuing in clear. Then `PBSZ 0`, `PROT P`, `EPSV` with `PASV` fallback, `MLSD` when available and `LIST -a` or `LIST` otherwise (Unix and DOS parsers), `REST` and `APPE` for resume. The control connection does one thing at a time (`AsyncGate`), so transfers use a second login.

Servers that require the data connection to resume the control connection's TLS session (vsftpd's default) are not supported: the public API gives no way to do it. They get an error that names the server setting.

### WebDAV

URLSession: `PROPFIND` (parsed with `XMLParser`), `MKCOL`, `MOVE`, `DELETE`, ranged `GET` and streamed `PUT`. Downloads suspend the task while the reader is behind, so memory stays bounded. `DELETE` on a collection would remove everything inside, so `removeDirectory` first checks that it is empty.

## Connections and prompts

`AppModel.connect` creates a `BrowserModel` (one tab), which asks the environment's `ServerConnecting` for a `RemoteFileSystem`. `LiveConnector` opens SFTP through `ssh`, and FTP and WebDAV with a password taken from the caller, the Keychain or the user. Every question goes through `PromptCenter`, which shows one sheet at a time. A password is saved only after it worked.

`AppEnvironment.demo()` (launch argument `--demo`, `make demo`) wires `DemoConnector`, `SimulatedFiles`, an in-memory bookmark store and an in-memory credential store: no network, no disk, no Keychain.

## Transfers

`TransferPlanner` expands a selection into `TransferItem`s without following symlinks. `TransferEngine` (an actor) runs them with a limit per server, a shared rate limiter and a conflict policy.

- **Upload**: written to `.<name>.navette-part` next to the target, size verified, then renamed over the target. A name that only differs by Unicode normalization from an existing remote name is treated as the same file.
- **Download**: written to `<name>.navette-part`, size verified, then moved into place with the server's exact name; a local file it replaces goes to the Trash.
- **Pause and failure** keep the partial file; a retry resumes from it if the source's size and date are unchanged, and starts over otherwise.
- **Cancel** removes the partial file.
- **Conflicts** are asked one at a time so that "apply to all" reaches the transfers waiting behind. Without anyone to ask, the engine skips.

The Mac side goes through `LocalFiles`. Foundation hands out and writes file names in decomposed Unicode whatever the disk stores, so `DiskFiles` reads exact names with `readdir` and writes them with `rename` and `mkdir`.

## Safety model

- **Deletion.** `RemoteEnumerator` lists the selection recursively without following symlinks; the sheet shows every item, the count and the total size; `RemoteDeleter` deletes exactly that list, children first. A folder that received new content fails with `directoryNotEmpty` and is left in place.
- **Hostile servers.** Names from listings are filtered (`.`, `..`, slashes, NUL) in each driver, and again in `TransferPlanner.localURL` before they become local paths.
- **Trust.** `known_hosts` belongs to the user: only `ssh` writes to it. TLS trust is the system's, or exactly the certificate the user accepted for that bookmark.
- **Secrets.** `KeychainCredentialStore` keeps everything in one Keychain item, because the ad hoc signature makes macOS ask again after each update: one item means one question. A failed read never leads to an overwrite.

## Open With

`EditCoordinator` downloads the file to `~/Library/Caches/io.github.romainrg.Navette/<tab>/`, opens it and watches its folder (`FolderWatcher`), because editors save through a rename. `EditSession` decides at each save: upload when the server copy is the one that was downloaded or last uploaded, ask otherwise. When the tab closes, a copy with changes that never reached the server goes to the Trash; the rest of the cache is removed.

## Localization and screenshots

English is the source language; `Navette/Resources/Localizable.xcstrings` holds the French. `scripts/check-strings.sh` compares the strings the compiler extracted from the last Debug build with the catalog. `Tools/Screenshots` renders the real views offscreen from demo data, in light and dark and in any language, with no screen capture.
