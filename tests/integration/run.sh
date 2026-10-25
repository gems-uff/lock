#!/bin/bash
# End-to-end test on a disposable machine (the GitHub Actions VM): real sshd, systemd, sudo, users and keys.
# It creates users and changes /etc, so it refuses to run unless LOCK_E2E=1 and it runs as root.
# NEVER run it on a real server.
# shellcheck disable=SC2015  # "check1 && check2 || fail" is meant: fail when either check fails
set -euo pipefail

if [ "${LOCK_E2E:-}" != 1 ] || [ "$EUID" != 0 ]; then
    echo "refusing: this test creates users and edits /etc; run it only on a disposable VM as root with LOCK_E2E=1" >&2
    exit 1
fi

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
K=$(mktemp -d)
N=0
ok() { N=$((N + 1)); echo "ok $N - $*"; }
fail() { echo "not ok - $*" >&2; exit 1; }
gdate() { if command -v gnudate >/dev/null 2>&1; then gnudate "$@"; else date "$@"; fi; }
brt() { TZ=America/Sao_Paulo gdate "$@"; }
as() { local u=$1; shift; sudo -u "$u" -- "$@"; }
ssh_as() {
    local u=$1; shift
    ssh -i "$K/$u" -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR -o ConnectTimeout=10 "$u@127.0.0.1" "$@"
}
login_ok() { ssh_as "$1" true 2>"$K/err"; }
login_refused_with_banner() { ! ssh_as "$1" true 2>"$K/err" && grep -q "está medindo tempo" "$K/err"; }
wait_until_gone() { local _; for _ in $(seq "$2"); do [ -e "$1" ] || return 0; sleep 2; done; return 1; }

echo "# setup: sshd, users ada (admin), alice (owner) and bob (third party), keys"
command -v sshd >/dev/null 2>&1 || PATH=$PATH:/usr/sbin
if ! command -v sshd >/dev/null 2>&1; then apt-get install -y -qq openssh-server >/dev/null; fi
if ! systemctl is-active -q ssh.service && ! systemctl is-active -q ssh.socket; then
    systemctl start ssh.socket 2>/dev/null || systemctl start ssh.service
fi
for u in ada alice bob; do
    id "$u" >/dev/null 2>&1 || useradd -m -s /bin/bash -c "Full ${u^}" "$u"
    usermod -p '*' "$u"                 # no password, but not locked (a locked account may be refused by sshd)
    ssh-keygen -q -t ed25519 -N "" -f "$K/$u"
    install -d -m 700 -o "$u" -g "$u" "/home/$u/.ssh"
    install -m 600 -o "$u" -g "$u" "$K/$u.pub" "/home/$u/.ssh/authorized_keys"
done
login_ok bob || { cat "$K/err"; fail "baseline: bob cannot log in before lock is installed"; }
ok "baseline logins work"
sshd -T > "$K/sshd-before"

echo "# install"
"$REPO/install.sh" --check >/dev/null || fail "preflight on a stock sshd_config"
ok "preflight passes"
if "$REPO/install.sh" >/dev/null 2>&1; then fail "first install without --admins should fail"; fi
ok "first install requires --admins"
if "$REPO/install.sh" --admins nosuchuser >/dev/null 2>&1; then fail "unknown admin accepted"; fi
ok "unknown administrator rejected"
"$REPO/install.sh" --admins ada
"$REPO/install.sh" | grep -q "installed lock" || fail "reinstall"
grep -qx 'ADMINS="ada"' /etc/lock.conf || fail "reinstall must keep /etc/lock.conf"
ok "install and idempotent reinstall"
[ "$(stat -c %a /etc/sudoers.d/80-lock)" = 440 ] && visudo -c -f /etc/sudoers.d/80-lock >/dev/null || fail "sudoers"
systemctl is-enabled --quiet lock-cleanup.service || fail "lock-cleanup.service not enabled"
systemctl show -p Before lock-cleanup.service | grep -q ssh.service || fail "lock-cleanup must run before ssh.service"
ok "sudoers valid, cleanup unit enabled and ordered before sshd"

echo "# start, banner, motd, refusals, stop"
end=$(brt -d "+10 min" '+%Y-%m-%d %H:%M')
as alice sudo -n lock start --until "$end" | grep -q "Reserva feita: Full Alice (alice)" || fail "start by alice"
lock status | grep -q "até $(brt -d "$end" '+%d/%m/%Y %H:%M') (hora de Brasília)" || fail "end time shown in BRT on a UTC machine"
ok "regular user reserves through sudo; time read in BRT on a $(date +%Z) machine"
login_refused_with_banner bob || { cat "$K/err"; fail "bob should be refused with the banner"; }
ok "third party refused with banner"
login_ok alice && login_ok ada || fail "owner and administrator must log in"
ok "owner and administrator accepted"
/etc/update-motd.d/05-lock | grep -q "MÁQUINA RESERVADA" || fail "motd"
ok "motd shows the reservation"
if as bob sudo -n lock stop 2>/dev/null; then fail "bob ended alice's reservation"; fi
if as bob sudo -n lock stop --timer 2>/dev/null; then fail "bob used --timer"; fi
[ -e /etc/lock.state ] || fail "state lost after refused stops"
ok "third party cannot stop the reservation"
if as bob sudo -n lock start --until "$end" 2>/dev/null; then fail "overlapping reservation accepted"; fi
ok "overlapping reservation refused"
as alice sudo -n lock stop | grep -q "encerrada" || fail "stop by owner"
sshd -T > "$K/sshd-after"
diff "$K/sshd-before" "$K/sshd-after" || fail "sshd configuration differs after stop"
login_ok bob || fail "bob after stop"
ok "stop restores sshd exactly; third party logs in again"

echo "# administrator stop, CPU refusal"
as alice sudo -n lock start --until "$end" >/dev/null
as ada sudo -n lock stop >/dev/null && [ ! -e /etc/lock.state ] || fail "administrator stop"
ok "administrator ends someone else's reservation"
as bob timeout 60 bash -c 'while :; do :; done' &
burner=$!
sleep 3
out=$(as alice sudo -n lock start --until "$end" 2>&1) && fail "start with bob using CPU"
echo "$out" | grep -q "bob=" || fail "CPU report should name bob: $out"
kill "$burner" 2>/dev/null || true; wait "$burner" 2>/dev/null || true
ok "CPU in use by another user blocks start"

echo "# timer"
now=$(date +%s)
end=$(brt -d "@$(( (now / 60 + 3) * 60 ))" '+%Y-%m-%d %H:%M')     # a minute boundary 2-3 min away
as alice sudo -n lock start --until "$end" >/dev/null || fail "start for the timer test"
systemctl list-timers lock-stop.timer --no-legend | grep -q lock-stop || fail "timer not created"
wait_until_gone /etc/lock.state 100 || fail "timer did not end the reservation"
[ ! -e /etc/ssh/sshd_config.d/00-lock.conf ] && login_ok bob || fail "logins after the timer"
ok "timer ends the reservation by itself"

echo "# boot cleanup"
as alice sudo -n lock start --until "$(brt -d '+10 min' '+%Y-%m-%d %H:%M')" >/dev/null
systemctl start lock-cleanup.service
[ ! -e /etc/lock.state ] && [ ! -e /etc/ssh/sshd_config.d/00-lock.conf ] || fail "cleanup at boot"
systemctl try-reload-or-restart ssh.service
login_ok bob || fail "bob after cleanup"
ok "lock-cleanup.service removes a reservation"

echo "# preflight refuses a conflicting sshd configuration"
echo "AllowGroups staff" > /etc/ssh/sshd_config.d/99-e2e.conf
if "$REPO/install.sh" --check >/dev/null 2>&1; then fail "conflicting AllowGroups not detected"; fi
rm -f /etc/ssh/sshd_config.d/99-e2e.conf
ok "preflight detects other login restrictions"

echo "# uninstall"
as alice sudo -n lock start --until "$(brt -d '+10 min' '+%Y-%m-%d %H:%M')" >/dev/null
"$REPO/install.sh" --uninstall >/dev/null
[ ! -e /usr/local/bin/lock ] && [ ! -e /etc/sudoers.d/80-lock ] && [ ! -e /etc/lock.state ] || fail "uninstall left files"
[ ! -e /etc/ssh/sshd_config.d/00-lock.conf ] && [ -e /etc/lock.conf ] || fail "uninstall: drop-in or conf"
login_ok bob || fail "bob after uninstall"
"$REPO/install.sh" --uninstall --purge >/dev/null
[ ! -e /etc/lock.conf ] || fail "--purge kept /etc/lock.conf"
ok "uninstall ends the active reservation and removes everything; --purge removes the configuration"

echo "# all $N checks passed"
