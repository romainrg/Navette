# Changelog

All notable changes to Navette are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

First version of Navette, a file transfer client for macOS.

### Added

- **SFTP** through the system's `ssh`: `~/.ssh/config`, agents, jump hosts, FIDO keys and `known_hosts` work as in Terminal. Passwords, passphrases, one-time codes and new host keys are asked in the app. The connection sheet shows what the SSH configuration resolves to.
- **FTP and FTPS** (explicit TLS, implicit on port 990), with `MLSD` and Unix or DOS `LIST` listings and resume in both directions.
- **WebDAV** over http and https, with presets for Nextcloud and ownCloud.
- **File browser**: sortable columns, path bar, filter, hidden files, tabs, inspector, go to folder.
- **Transfers**: queue with progress, speed and time left; pause, resume, retry and cancel; speed limit; simultaneous transfers per server; conflict choices (overwrite, resume, rename, skip) for one file or the whole transfer.
- **Drag and drop** from Finder to upload, and from the list to Finder to download.
- **Bookmarks** with folders and colors, recent connections, and passwords stored in the Keychain.
- **Quick Connect** from a pasted address such as `sftp://user@host:2222/path`.
- **Quick Look** on remote files and **Open With**, which sends the file back at each save and asks when the server copy changed in the meantime.
- **Permissions** editor with checkboxes and octal, optionally applied to the content of a folder.
- **Remote deletion** always preceded by the list of items, their count and total size.
- **Certificate sheet** for TLS certificates the system does not trust, and an explanation instead of a connection when an SSH host key changed.
- **Demo mode** (`--demo`) with in-memory servers: no network and no disk access.
- English and French.

### Known limitations

- FTPS servers that require TLS session reuse on data connections are not supported.
- No column view, Bonjour discovery or Quick Open yet.
- WebDAV uploads cannot resume.
