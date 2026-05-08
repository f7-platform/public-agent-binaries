# Contributing

This repository distributes pre-built installers and binaries for fseven.
The source code for the controller and agent is maintained in private
repositories; contributions to the distribution scripts and documentation are
welcome here.

## What belongs here

- `install.sh` / `install.ps1` — community self-host installer scripts
- `docker-compose.yml` — the unified deployment compose file
- `README.md` — user-facing installation documentation

## How to contribute

1. **Open an issue first** — describe the problem or improvement so we can
   discuss before you write code.
2. **Fork and branch** — create a feature branch from `main`.
3. **Test your changes** — run `bash tests/smoke.sh` to verify the installer
   scripts (requires Docker).
4. **Open a pull request** — fill in the PR template; link the related issue.

## Code of conduct

Be respectful and constructive. We follow the
[Contributor Covenant v2.1](https://www.contributor-covenant.org/version/2/1/code_of_conduct/).

## Security

Do **not** report security vulnerabilities via a GitHub issue.
See [SECURITY.md](SECURITY.md) for the responsible-disclosure process.

## License

By contributing you agree that your contributions are licensed under the
[MIT License](LICENSE).
