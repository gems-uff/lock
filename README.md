# lock

[![CI](https://github.com/gems-uff/lock/actions/workflows/ci.yml/badge.svg)](https://github.com/gems-uff/lock/actions/workflows/ci.yml)

Exclusive reservations for people who measure running time on shared Linux servers.

Research labs share a few powerful machines. When someone needs to measure how long an experiment takes, anyone
else logging in and starting a job ruins the measurement. A shared calendar helps, but only if everybody checks it.
`lock` turns the calendar rule into something the machine enforces:

```console
$ sudo lock start --until "2026-11-03 18:00"
Reserva feita: Alice Silva (alice) até 03/11/2026 18:00 (hora de Brasília). Logins novos só para: admin alice.
```

While the reservation holds, new SSH logins are accepted only from the administrators and from the person who made
the reservation. Everyone else sees why they cannot get in:

```console
$ ssh bob@server
Alice Silva está medindo tempo em server até 03/11/2026 18:00 (hora de Brasília), conforme a agenda da máquina.
Em caso de urgência, fale com Alice Silva.
bob@server: Permission denied (publickey,password).
```

`lock` only manages the reservation. It knows nothing about the experiment: it does not touch CPU frequency,
cores, services or environment variables. Each experiment prepares what it needs after `lock start`.

User-facing messages are in Brazilian Portuguese, the language of the lab where `lock` was born (GEMS, Universidade
Federal Fluminense). Translations are welcome.

## How it works

`sudo lock start --until "YYYY-MM-DD HH:MM"`

1. **Checks, never kills.** It refuses (exit code 1, saying why) if a reservation is already active, or if other
   users are using the CPU right now (sampled over 2 seconds; default limit 10 % of one core), have processes on
   the GPU (`nvidia-smi`, when present), or have Docker containers running. It also reports the load and who has
   sessions open. Open sessions and other users' crontabs are only warnings.
2. **Logins.** It writes `/etc/ssh/sshd_config.d/00-lock.conf` with `AllowUsers <admins> <owner>` and a `Banner`,
   validates it with `sshd -t` and reloads sshd. Sessions already open keep running. It never uses `/etc/nologin`,
   which would lock out the administrators too.
3. **Notice.** The login message (`/etc/update-motd.d/05-lock`) shows the reservation, and `wall` announces it.
4. **Guaranteed undo.** A systemd timer runs `lock stop` at the end time; `lock-cleanup.service` ends any
   reservation at boot, before sshd starts, so no reservation survives a reboot.

`sudo lock stop` undoes all of that and is idempotent. Only the owner or an administrator can stop a reservation.
`lock status` (no sudo needed) shows whether there is a reservation, whose, and until when.

The owner is the user who ran `sudo` (`$SUDO_USER`), never a name typed on the command line; the banner shows the
full name from the GECOS field. `--until` is always read in the configured time zone (default
`America/Sao_Paulo`), whatever the machine's own time zone is.

## Requirements

- Linux with systemd (Ubuntu 26.04 is the target; the end-to-end test also runs on Ubuntu 24.04).
- OpenSSH with `Include /etc/ssh/sshd_config.d/*.conf` at the top of `sshd_config` (the default since Ubuntu
  20.04 and Debian 11), and no other `AllowUsers`, `AllowGroups`, `DenyUsers`, `DenyGroups`, `Banner` or `Match`.
- bash, GNU date (on Ubuntu 26.04 the uutils `date` is the default; `lock` uses `gnudate` when it exists), sudo or
  sudo-rs, `flock`, `loginctl`.
- Optional: `nvidia-smi`, `docker`, `update-motd` (Ubuntu's dynamic login message).

## Installation

```sh
git clone https://github.com/gems-uff/lock.git
cd lock
sudo ./install.sh --check                  # preflight only; changes nothing
sudo ./install.sh --admins "alice bob"     # first install
```

The installer checks the requirements and the sshd configuration, then installs:

| File | Purpose |
|---|---|
| `/usr/local/bin/lock` | the command |
| `/etc/lock.conf` | administrators and limits; written on the first install and never overwritten |
| `/etc/sudoers.d/80-lock` | lets every user run `lock` as root (validated with `visudo` before it is put in place) |
| `/etc/update-motd.d/05-lock` | shows an active reservation at login |
| `/etc/systemd/system/lock-cleanup.service` | ends any reservation at boot, before sshd |

Upgrade with `git pull && sudo ./install.sh` (keeps `/etc/lock.conf`). Remove with `sudo ./install.sh --uninstall`,
which ends an active reservation first; add `--purge` to remove `/etc/lock.conf` too. `--dry-run` prints what
would be done.

Keep at least one administrator: they can always log in to undo a reservation.

## Configuration

`/etc/lock.conf` is sourced by the script:

| Variable | Default | Meaning |
|---|---|---|
| `ADMINS` | set by `--admins` | always allowed to log in; may stop anyone's reservation |
| `CPU_LIMIT` | `10` | % of one core used by other users, summed, from which `start` refuses |
| `MAX_DAYS` | `14` | longer reservations are rejected as typos |
| `TIMEZONE` | `America/Sao_Paulo` | zone in which `--until` is read and shown |
| `TIMEZONE_LABEL` | `hora de Brasília` | how that zone is named in messages |

## What lock does not cover

- Sessions that were already open, their `tmux`/`screen` sessions, and crontabs keep running (`start` lists them).
- Processes started later by the owner or the administrators.
- Logins that do not go through sshd (local console, display managers).
- Containers or services started by root.
- Root can do anything; `lock` is a coordination tool, not a security boundary against administrators.

## Security notes

- The sudoers rule lets every user run `/usr/local/bin/lock` as root with any arguments. The script parses its
  arguments strictly, accepts `--until` only as `YYYY-MM-DD HH:MM`, and refuses the internal `stop --timer` and
  `stop --boot` modes when called through sudo.
- sudo resets the environment, and the test hook (`LOCK_TEST_ROOT`) is ignored whenever the script really runs as
  root.
- The sshd change is applied only if `sshd -t` accepts it; otherwise it is rolled back.

## Development

```sh
make test          # unit tests with bats, in a sandbox (regular user; no root, no real sshd)
make lint          # shellcheck
make docker-test   # both, inside an Ubuntu 26.04 container (UBUNTU=24.04 to try another release)
```

The unit tests (`tests/unit`) run `src/lock` against a fake root (`LOCK_TEST_ROOT`) with fake `/etc`, `/proc` and
`/run`, and with test doubles for `sshd`, `systemctl`, `systemd-run`, `docker`, `nvidia-smi`, `ps` and others
(`tests/stubs`). The end-to-end test (`tests/integration/run.sh`, `make e2e`) installs `lock` on a disposable VM,
creates users and keys, and checks real SSH logins, sudo, the timer, the boot cleanup and the uninstall. It refuses
to run unless `LOCK_E2E=1`: **never run it on a real server.** CI runs the unit tests on Ubuntu 26.04 and the end-to-end test on a 24.04 VM, on every push.

## License

MIT; see [LICENSE](LICENSE).
