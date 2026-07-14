# Contributing to resolveRepackage

Thanks for helping improve resolveRepackage. This guide covers local setup,
validation, and the pull request process.

## Ways to contribute

- **Report a bug** using the repository's bug report form.
- **Request a feature** using the feature request form.
- **Send a pull request** after opening an issue for non-trivial changes.
- **Report a vulnerability privately** by following [SECURITY.md](SECURITY.md).

## Prerequisites

- Bash 5 or newer
- ShellCheck
- gitleaks 8.30.1 or newer
- A Debian, Ubuntu, or Pop!_OS machine (or VM) with `fakeroot`, `xz-utils`,
  `tar`, and `dpkg` only when exercising the repackaging script end-to-end
- An official DaVinci Resolve `.run` installer only when exercising the
  repackaging script end-to-end

## Set up from a clean clone

```bash
git clone https://github.com/iamteedoh/resolveRepackage.git
cd resolveRepackage
```

The script is self-contained; there is nothing to install for development
beyond the validation tools above. Never commit installer payloads, generated
`.deb` files, tokens, or credentials.

## Run the validation suite

Run the same checks that protect `main`:

```bash
git ls-files '*.sh' | xargs -r shellcheck --severity=error
bash -n repackageResolve.sh
gitleaks git . --config .gitleaks.toml --redact --no-banner
```

When changing repackaging behavior, run the script end-to-end on a Debian
derivative (ideally a VM or container you can throw away) and confirm the
generated `.deb` installs and Resolve launches. The script runs as root and
modifies `/opt` and `/usr/bin`, so do not test it on a machine you cannot
recover.

## Project layout

- `repackageResolve.sh` — the entire tool: prerequisite checks, dependency
  bundling, `.run` extraction, Debian packaging, and optional installation
- `.github/workflows/` — source validation and source-only release automation

## Pull request process

1. Create a branch from `main`.
2. Make the smallest complete change and update documentation.
3. Run the full validation suite above.
4. Use a [Conventional Commit](https://www.conventionalcommits.org/) PR title:
   `feat:`, `fix:`, `docs:`, `refactor:`, `ci:`, `test:`, or `chore:`.
5. Complete the pull request template and link the related public issue.
6. Wait for all required checks to pass, then squash-merge.

The PR title becomes the squash commit subject and drives release-please:
`fix:` creates a patch release, `feat:` creates a minor release, and a `!` or
`BREAKING CHANGE:` footer creates a breaking release.

## License

By contributing, you agree that your contributions are licensed under the
project's [GNU General Public License v3](LICENSE).
