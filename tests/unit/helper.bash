# shellcheck shell=bash disable=SC2154  # $status, $output and $lines come from bats
# Shared setup for the unit tests: a sandbox root (LOCK_TEST_ROOT) with fake /etc, /proc and /run, and the
# test doubles of tests/stubs first in PATH. The script under test never touches the real system.

REPO=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
LOCK=$REPO/src/lock

setup() {
    if [ "$EUID" = 0 ]; then
        echo "run the unit tests as a regular user: the sandbox hook is ignored for root" >&2
        return 1
    fi
    R=$(mktemp -d)
    export LOCK_TEST_ROOT=$R LOCK_TEST_UID=0
    mkdir -p "$R"/etc/ssh/sshd_config.d "$R"/run "$R"/proc "$R"/var/spool/cron/crontabs "$R"/stub
    cat > "$R/etc/lock.conf" <<'EOF'
ADMINS="admin"
CPU_LIMIT=10
MAX_DAYS=14
TIMEZONE=America/Sao_Paulo
TIMEZONE_LABEL="hora de Brasília"
EOF
    cat > "$R/etc/passwd" <<'EOF'
admin:x:1000:1000:Ada Admin,,,:/home/admin:/bin/bash
alice:x:1001:1001:Alice Owner,,,:/home/alice:/bin/bash
bob:x:1002:1002:Bob Other:/home/bob:/bin/bash
carol:x:1003:1003::/home/carol:/bin/bash
EOF
    echo "0.10 0.20 0.30 1/100 123" > "$R/proc/loadavg"
    : > "$R/stub/ps"
    : > "$R/calls.log"
    export PATH="$REPO/tests/stubs:$PATH"
    unset SUDO_USER
}

teardown() {
    [ -n "${R:-}" ] && rm -rf "$R"
}

# GNU date, whatever the platform calls it
gdate() { if command -v gnudate >/dev/null 2>&1; then gnudate "$@"; else date "$@"; fi; }

# "YYYY-MM-DD HH:MM" in São Paulo time, $1 minutes from now
until_in() { TZ=America/Sao_Paulo gdate -d "+$1 min" '+%Y-%m-%d %H:%M'; }

# fake process: proc PID UID USER TICKS
proc() {
    mkdir -p "$R/proc/$1"
    echo "$1 (some cmd) S 1 1 1 0 -1 0 0 0 0 0 $4 0 0 0 20 0 1 0 100 0 0" > "$R/proc/$1/stat"
    echo "$1 $2 $3" >> "$R/stub/ps"
}

# make process $1 use $2 more ticks between the two CPU samples
burn() {
    cat >> "$R/stub/on_sleep" <<EOF
#!/bin/bash
f=$R/proc/$1/stat; read -r l < "\$f"; rest="\${l##*) }"; h="\${l%"\$rest"}"; set -- \$rest
echo "\$h\${*:1:11} \$((\${12} + $2)) \${*:13}" > "\$f"
EOF
    chmod +x "$R/stub/on_sleep"
}

# run lock as if called through sudo by $1
as() { local u=$1; shift; run env SUDO_USER="$u" "$LOCK" "$@"; }

start_reservation() { as "${1:-alice}" start --until "$(until_in 30)"; [ "$status" -eq 0 ]; }

calls() { cat "$R/calls.log"; }

# fails if a command matching the regex was called (a bare "! cmd" does not fail a bats test)
refute_call() {
    if grep -q "$1" "$R/calls.log"; then echo "unexpected call matching '$1':" >&2; grep "$1" "$R/calls.log" >&2; return 1; fi
}
