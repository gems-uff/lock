# Changelog

All notable changes are listed here. Versions follow [Semantic Versioning](https://semver.org/).

## 1.0.0 (2026-10-25)

First public release, in production on one lab server (Ubuntu 26.04) since 2026-10-25.

- `lock start --until`, `lock stop`, `lock status`, `lock --version`.
- Refuses to start when another reservation is active, or when other users are using CPU now, the GPU or Docker.
- sshd drop-in with `AllowUsers` and `Banner`, validated by `sshd -t`; motd and `wall` notices.
- Automatic end by a transient systemd timer (1 s accuracy) and cleanup at boot before sshd.
- Only the owner or an administrator may stop a reservation.
- `install.sh` with preflight checks, idempotent upgrades, `--uninstall`, `--purge` and `--dry-run`.
- Unit tests (bats, sandboxed), shellcheck, and an end-to-end test on the CI VM.
