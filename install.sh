#!/bin/bash
# install.sh: install, upgrade or remove lock on this machine. Run as root from a checkout of the repository.
#
#   sudo ./install.sh --admins "alice bob"   first install (administrators are required)
#   sudo ./install.sh                        upgrade; keeps /etc/lock.conf
#   sudo ./install.sh --check                only run the preflight checks
#   sudo ./install.sh --uninstall [--purge]  remove lock (--purge also removes /etc/lock.conf)
#
# Options: --dry-run prints the commands instead of running them; --force installs despite sshd_config conflicts.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
BIN=/usr/local/bin/lock
CONF=/etc/lock.conf
SUDOERS=/etc/sudoers.d/80-lock
MOTD_DIR=/etc/update-motd.d
MOTD=$MOTD_DIR/05-lock
UNIT=/etc/systemd/system/lock-cleanup.service
SSHD_CONFIG=${SSHD_CONFIG:-/etc/ssh/sshd_config}
SSHD_DROPIN_DIR=/etc/ssh/sshd_config.d

ADMINS="" MODE=install DRY_RUN=0 FORCE=0 PURGE=0

say() { echo "install.sh: $*"; }
die() { echo "install.sh: ERROR: $*" >&2; exit 1; }
run() { if [ "$DRY_RUN" = 1 ]; then echo "+ $*"; else "$@"; fi; }

while [ $# -gt 0 ]; do
    case "$1" in
        --admins) [ $# -ge 2 ] || die "--admins needs a value"; ADMINS="$2"; shift 2 ;;
        --admins=*) ADMINS="${1#--admins=}"; shift ;;
        --check) MODE=check; shift ;;
        --uninstall) MODE=uninstall; shift ;;
        --purge) PURGE=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        --force) FORCE=1; shift ;;
        -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown option: $1 (see --help)" ;;
    esac
done

[ "$EUID" = 0 ] || [ "$DRY_RUN" = 1 ] || die "run as root: sudo $0 $*"

# Prints the problems found, one per line; empty output means the sshd configuration is compatible.
sshd_problems() {
    local first_include first_conflict f
    [ -r "$SSHD_CONFIG" ] || { echo "$SSHD_CONFIG not found"; return; }
    first_include=$(grep -nE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' "$SSHD_CONFIG" | head -1 | cut -d: -f1)
    if [ -z "$first_include" ]; then
        echo "$SSHD_CONFIG lacks 'Include /etc/ssh/sshd_config.d/*.conf' (add it as the first directive; default since OpenSSH 8.2 on Ubuntu 20.04)"
    fi
    first_conflict=$(grep -nE '^[[:space:]]*(AllowUsers|AllowGroups|DenyUsers|DenyGroups|Banner|Match)[[:space:]]' "$SSHD_CONFIG" \
        | grep -viE 'Banner[[:space:]]+none' | head -1 | cut -d: -f1)
    if [ -n "$first_conflict" ]; then
        echo "$SSHD_CONFIG line $first_conflict sets $(sed -n "${first_conflict}p" "$SSHD_CONFIG" | awk '{print $1}'); lock assumes it is the only one restricting logins"
    fi
    for f in "$SSHD_DROPIN_DIR"/*.conf; do
        if [ ! -e "$f" ] || [ "$f" = "$SSHD_DROPIN_DIR/00-lock.conf" ]; then continue; fi
        if grep -qiE '^[[:space:]]*(AllowUsers|AllowGroups|DenyUsers|DenyGroups|Banner|Match)[[:space:]]' "$f"; then
            echo "$f restricts logins or sets a banner; lock assumes it is the only one doing so"
        fi
    done
}

preflight() {
    local ok=1 c missing="" problems
    for c in systemctl systemd-run sshd visudo flock getent loginctl awk ps install; do
        command -v "$c" >/dev/null 2>&1 || PATH=$PATH:/usr/sbin:/sbin command -v "$c" >/dev/null 2>&1 || missing="$missing $c"
    done
    [ -z "$missing" ] || { echo "missing commands:$missing" >&2; ok=0; }
    if ! date --version 2>/dev/null | grep -q GNU && ! command -v gnudate >/dev/null 2>&1; then
        echo "GNU date not found (on Ubuntu 26.04 it is gnudate, from coreutils-from-uutils)" >&2; ok=0
    fi
    [ -d /run/systemd/system ] || { echo "systemd is not running as init" >&2; ok=0; }
    problems=$(sshd_problems)
    if [ -n "$problems" ]; then
        while IFS= read -r p; do echo "sshd: $p" >&2; done <<< "$problems"
        if [ "$FORCE" = 1 ]; then say "continuing because of --force"; else ok=0; fi
    fi
    [ -d "$MOTD_DIR" ] || say "warning: $MOTD_DIR not found; the login message (motd) will not show reservations"
    [ "$ok" = 1 ] || die "preflight failed; nothing was changed"
    say "preflight ok"
}

write_conf() {
    local a
    if [ -e "$CONF" ]; then
        [ -z "$ADMINS" ] || say "keeping the existing $CONF; --admins ignored (edit the file to change administrators)"
        return
    fi
    [ -n "$ADMINS" ] || die "first install: pass --admins \"user1 user2\" (they can always log in and undo a reservation)"
    for a in $ADMINS; do
        [[ "$a" =~ ^[a-z_][a-z0-9_.-]*$ ]] || die "invalid user name: $a"
        getent passwd "$a" >/dev/null || die "user $a does not exist on this machine"
    done
    if [ "$DRY_RUN" = 1 ]; then echo "+ write $CONF with ADMINS=\"$ADMINS\""; return; fi
    sed "s/@ADMINS@/$ADMINS/" "$HERE/etc/lock.conf" > "$CONF.new"
    chown root:root "$CONF.new"; chmod 644 "$CONF.new"; mv "$CONF.new" "$CONF"
}

do_install() {
    preflight
    run install -o root -g root -m 0755 "$HERE/src/lock" "$BIN"
    write_conf
    # sudoers: validate a hidden copy (files with a dot are ignored by @includedir) before putting it in place
    run install -o root -g root -m 0440 "$HERE/etc/sudoers.d/lock" "/etc/sudoers.d/.80-lock.new"
    if [ "$DRY_RUN" = 0 ] && ! visudo -c -f /etc/sudoers.d/.80-lock.new >/dev/null; then
        rm -f /etc/sudoers.d/.80-lock.new; die "visudo rejected the sudoers rule"
    fi
    run mv /etc/sudoers.d/.80-lock.new "$SUDOERS"
    if [ -d "$MOTD_DIR" ]; then run install -o root -g root -m 0755 "$HERE/etc/update-motd.d/05-lock" "$MOTD"; fi
    run install -o root -g root -m 0644 "$HERE/systemd/lock-cleanup.service" "$UNIT"
    run systemctl daemon-reload
    run systemctl enable --quiet lock-cleanup.service
    if [ "$DRY_RUN" = 0 ]; then
        visudo -c >/dev/null || die "visudo -c failed after the install; check $SUDOERS"
        say "installed $("$BIN" --version); administrators: $(sed -n 's/^ADMINS="\(.*\)"/\1/p' "$CONF")"
        "$BIN" status
    fi
}

do_uninstall() {
    if [ -e /etc/lock.state ] && [ -x "$BIN" ]; then say "ending the active reservation first"; run "$BIN" stop; fi
    if [ -e "$UNIT" ]; then run systemctl disable --quiet lock-cleanup.service; fi
    run rm -f "$BIN" "$SUDOERS" "$MOTD" "$UNIT"
    run systemctl daemon-reload
    if [ "$PURGE" = 1 ]; then run rm -f "$CONF"; else [ -e "$CONF" ] && say "kept $CONF (use --purge to remove it)"; fi
    say "lock removed"
}

case "$MODE" in
    check) preflight ;;
    install) do_install ;;
    uninstall) do_uninstall ;;
esac
