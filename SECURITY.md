# Security Policy

## Reporting a vulnerability

**Do not report security vulnerabilities through public GitHub issues.**

Use GitHub's private vulnerability reporting instead:

1. Open the repository's **Security** tab.
2. Select **Report a vulnerability**.
3. Provide the details requested below.

If private reporting is unavailable, contact the maintainer through the
[iamteedoh GitHub profile](https://github.com/iamteedoh).

## What to include

- A description of the issue and its potential impact
- Reproduction steps or a minimal proof of concept
- The affected release, commit, platform, and component
- A suggested remediation, if known

Never include live tokens, passwords, SSH keys, private hostnames, or
unredacted logs in a report.

## Security-sensitive areas

resolveRepackage runs as root and builds a package that is installed
system-wide, so the most sensitive surfaces are:

- Root-privileged filesystem operations under `/opt`, `/usr/bin`, and
  `/usr/share/applications`, including the cleanup trap's recursive deletes
- Execution of the vendor `.run` installer and trust in its extracted contents
- The generated `DEBIAN/postinst` script, which runs as root at install time
- Dependency bundling via `apt-get` and the on-disk package cache under
  `${CACHE_ROOT:-$HOME/.cache/resolve-repackage}`
- The `LD_LIBRARY_PATH` launcher shim and the disabling of conflicting shared
  libraries, which shape the dynamic-loader search path for Resolve
- Temporary build directories created with `mktemp` under `/tmp`

## Supported versions

Security fixes land on `main` and ship in the next tagged source release. Test
against the latest release or `main` before reporting an issue.
