# Security policy

Navette handles credentials, connects to servers and can delete remote files for good, so security and safety reports are taken seriously.

## Supported versions

Only the [latest release](https://github.com/romainrg/Navette/releases/latest) receives security fixes.

## Reporting a vulnerability

**Please do not open a public issue.** Report the problem privately through GitHub: [report a vulnerability](https://github.com/romainrg/Navette/security/advisories/new) (Security tab > Advisories).

Please include:

- the Navette and macOS versions;
- the protocol and, if you can, the server software involved;
- a description of the problem and its impact;
- the steps to reproduce it, or a proof of concept;
- whether the problem is already public.

Navette is maintained on a volunteer basis. You can expect an acknowledgement within 7 days and an assessment within 30 days. You will be kept informed, credited in the release notes if you wish, and consulted on the disclosure date once a fix is available.

## Scope

In scope, for example:

- a password, passphrase or one-time code written to disk outside the Keychain, shown in a log, or sent to a server other than the one it belongs to;
- a changed SSH host key or an untrusted TLS certificate accepted without the user seeing it, or FTPS continuing in clear after TLS was refused;
- a hostile server making Navette write or delete outside the folder the user chose (names such as `..`, absolute paths, symlinks);
- a host name, user name or file name interpreted as an option or as code by `ssh` or any other command;
- a remote deletion or an overwrite that was not listed in the confirmation;
- a transfer reported as complete while the file is truncated or corrupt;
- any network request to a server the user did not configure.

Out of scope:

- attacks that require an already compromised user account or administrator access;
- the Gatekeeper warning shown on first launch of builds that are not notarized;
- weaknesses of the protocols themselves when the app warns about them (plain FTP and plain HTTP are not encrypted);
- the security of the server you connect to.

## Distribution

Release builds are signed **ad hoc** and are not notarized. Verify a download against the `SHA256SUMS` file published with each release (`shasum -a 256 -c SHA256SUMS`).

Because of the ad hoc signature, macOS asks once for access to Navette's Keychain item after each update. Developer ID signing and notarization are on the [roadmap](README.md#roadmap).
