<!-- Thanks for contributing to resolveRepackage! -->

## What does this PR do?

<!-- Briefly describe the change and why it is needed. -->

## Related issue

<!-- Link the public issue this addresses, for example: Closes #123. -->

## Validation

<!-- List the commands and manual checks you ran. -->

## Checklist

- [ ] `git ls-files '*.sh' | xargs -r shellcheck --severity=error` passes
- [ ] `bash -n repackageResolve.sh` passes
- [ ] gitleaks reports no secrets in Git history
- [ ] Scripts and programs include a GPL-3.0-or-later SPDX header
- [ ] No secrets, tokens, credentials, or private infrastructure details are committed
- [ ] Documentation is updated for user-visible or operational changes
- [ ] The PR title follows Conventional Commits
