#!/usr/bin/env bats
# Unit tests of src/lock in a sandbox (see helper.bash). Run with: make test

load helper

# ---------------------------------------------------------------- basics

@test "version and help" {
    run "$LOCK" --version
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^lock\ [0-9]+\.[0-9]+\.[0-9]+$ ]]
    run "$LOCK" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"sudo lock start"* ]]
}

@test "unknown command prints usage and exits 2" {
    run "$LOCK" frobnicate
    [ "$status" -eq 2 ]
    [[ "$output" == *"uso:"* ]]
}

@test "status without reservation" {
    run "$LOCK" status
    [ "$status" -eq 0 ]
    [ "$output" = "Nenhuma reserva ativa em testhost." ]
}

@test "start and stop require root" {
    LOCK_TEST_UID=1001 as alice start --until "$(until_in 30)"
    [ "$status" -eq 1 ]
    [[ "$output" == *"rode com sudo"* ]]
    LOCK_TEST_UID=1001 as alice stop
    [ "$status" -eq 1 ]
    [[ "$output" == *"rode com sudo"* ]]
}

# ---------------------------------------------------------------- argument validation

@test "start without --until is refused" {
    as alice start
    [ "$status" -eq 1 ]
    [[ "$output" == *"uso: sudo lock start --until"* ]]
}

@test "start refuses malformed, past, too distant and unknown arguments" {
    as alice start --until "amanhã cedo"
    [ "$status" -eq 1 ]; [[ "$output" == *"não entendi a hora"* ]]
    as alice start --until "tomorrow"
    [ "$status" -eq 1 ]; [[ "$output" == *"não entendi a hora"* ]]
    as alice start --until "2026-02-30 10:00"
    [ "$status" -eq 1 ]; [[ "$output" == *"não entendi a hora"* ]]
    as alice start --until "2020-01-01 10:00"
    [ "$status" -eq 1 ]; [[ "$output" == *"já passou"* ]]
    as alice start --until "$(until_in 0)"
    [ "$status" -eq 1 ]; [[ "$output" == *"menos de 1 min"* ]]
    as alice start --until "$(until_in $((15 * 24 * 60)))"
    [ "$status" -eq 1 ]; [[ "$output" == *"mais de 14 dias"* ]]
    as alice start --until "$(until_in 30)" --name Alice
    [ "$status" -eq 1 ]; [[ "$output" == *"argumento desconhecido: --name"* ]]
    [ ! -e "$R/etc/lock.state" ]
}

@test "--until=VALUE form is accepted" {
    as alice start --until="$(until_in 30)"
    [ "$status" -eq 0 ]
}

@test "--until is read in the configured time zone, whatever the caller's TZ" {
    u=$(until_in 120)
    TZ=Asia/Tokyo as alice start --until "$u"
    [ "$status" -eq 0 ]
    expected=$(TZ=America/Sao_Paulo gdate -d "$u" +%s)
    [ "$(cut -d'|' -f2 "$R/etc/lock.state")" = "$expected" ]
    grep -q "systemd-run .*--on-calendar=$(TZ=UTC gdate -d "@$expected" '+%Y-%m-%d %H:%M:%S') UTC" "$R/calls.log"
}

# ---------------------------------------------------------------- start

@test "start by a regular user applies drop-in, banner, state, timer and notice" {
    u=$(until_in 30)
    as alice start --until "$u"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Reserva feita: Alice Owner (alice)"* ]]
    [[ "$output" == *"Logins novos só para: admin alice."* ]]
    grep -qx "AllowUsers admin alice" "$R/etc/ssh/sshd_config.d/00-lock.conf"
    grep -qx "Banner $R/etc/lock.banner" "$R/etc/ssh/sshd_config.d/00-lock.conf"
    grep -q "^Alice Owner está medindo tempo em testhost até .* (hora de Brasília)" "$R/etc/lock.banner"
    grep -q "fale com Alice Owner" "$R/etc/lock.banner"
    grep -q "^alice|[0-9]*|Alice Owner$" "$R/etc/lock.state"
    calls | grep -qx "sshd -t"
    calls | grep -q "^systemctl try-reload-or-restart ssh.service"
    calls | grep -q "^systemd-run --quiet --unit=lock-stop .*AccuracySec=1s .* /usr/local/bin/lock stop --timer$"
    calls | grep -q "^wall Alice Owner está medindo tempo"
}

@test "an administrator's reservation does not list them twice" {
    as admin start --until "$(until_in 30)"
    [ "$status" -eq 0 ]
    grep -qx "AllowUsers admin" "$R/etc/ssh/sshd_config.d/00-lock.conf"
}

@test "empty GECOS falls back to the login" {
    as carol start --until "$(until_in 30)"
    [ "$status" -eq 0 ]
    grep -q "^carol|[0-9]*|carol$" "$R/etc/lock.state"
}

@test "start refuses when a reservation is active and changes nothing" {
    start_reservation alice
    before=$(cat "$R/etc/ssh/sshd_config.d/00-lock.conf" "$R/etc/lock.state")
    as bob start --until "$(until_in 60)"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Já há reserva ativa: Alice Owner (alice)"* ]]
    [[ "$output" == *"reserva NÃO feita"* ]]
    [ "$(cat "$R/etc/ssh/sshd_config.d/00-lock.conf" "$R/etc/lock.state")" = "$before" ]
}

@test "start rolls back when sshd rejects the configuration" {
    echo 255 > "$R/stub/sshd_rc"
    as alice start --until "$(until_in 30)"
    [ "$status" -eq 1 ]
    [[ "$output" == *"o sshd recusou a configuração"* ]]
    [ ! -e "$R/etc/ssh/sshd_config.d/00-lock.conf" ]
    [ ! -e "$R/etc/lock.banner" ]
    [ ! -e "$R/etc/lock.state" ]
    refute_call systemd-run
}

@test "start warns when the timer cannot be created, but keeps the reservation" {
    echo 1 > "$R/stub/systemd_run_rc"
    as alice start --until "$(until_in 30)"
    [ "$status" -eq 0 ]
    [[ "$output" == *"não consegui agendar o fim automático"* ]]
    [ -e "$R/etc/lock.state" ]
}

@test "a concurrent start or stop is refused" {
    exec 8> "$R/run/lock-cmd.lock"
    flock -n 8
    as alice start --until "$(until_in 30)"
    exec 8>&-
    [ "$status" -eq 1 ]
    [[ "$output" == *"em andamento"* ]]
}

# ---------------------------------------------------------------- checks on other users' load

@test "CPU in use now by another user blocks start" {
    proc 500 1002 bob 1000
    burn 500 200                       # 200 ticks in 2 s = 100% of a core
    as alice start --until "$(until_in 30)"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Outros usuários estão usando CPU agora (100% de um núcleo: bob=100%)"* ]]
    [[ "$output" == *"Carga: 0.10 0.20 0.30"* ]]
    [ ! -e "$R/etc/lock.state" ]
}

@test "CPU of the owner, of system users and past CPU of idle processes do not block start" {
    proc 500 1001 alice 10
    burn 500 400                       # the owner's own load
    proc 501 0 root 10
    burn 501 400                       # root
    proc 502 112 ollama 10
    burn 502 400                       # system account
    proc 503 1002 bob 999999           # long-lived, idle now
    proc 504 1003 carol 10
    burn 504 10                        # 5%, below CPU_LIMIT
    as alice start --until "$(until_in 30)"
    [ "$status" -eq 0 ]
}

@test "CPU of several users adds up against the limit" {
    proc 500 1002 bob 0;   burn 500 12
    proc 501 1003 carol 0; burn 501 12
    as alice start --until "$(until_in 30)"
    [ "$status" -eq 1 ]
    [[ "$output" == *"(12% de um núcleo:"* ]]
}

@test "a process name with spaces and parentheses is parsed" {
    mkdir -p "$R/proc/600"
    echo "600 (weird) name (x)) R 1 1 1 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 100 0 0" > "$R/proc/600/stat"
    echo "600 1002 bob" >> "$R/stub/ps"
    burn 600 200
    as alice start --until "$(until_in 30)"
    [ "$status" -eq 1 ]
    [[ "$output" == *"bob=100%"* ]]
}

@test "another user's GPU process blocks start; the owner's does not" {
    proc 700 1001 alice 0
    echo 700 > "$R/stub/gpu_pids"
    as alice start --until "$(until_in 30)"
    [ "$status" -eq 0 ]
    as alice stop
    proc 701 1002 bob 0
    printf '700\n701\n' > "$R/stub/gpu_pids"
    as alice start --until "$(until_in 30)"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Há processos de outros na GPU: bob(pid 701)."* ]]
}

@test "running Docker containers of others block start; the owner's do not" {
    touch "$R/stub/docker_up"
    echo c1 > "$R/stub/docker_ps"
    echo "/home/alice/proj []" > "$R/stub/docker_label_c1"
    as alice start --until "$(until_in 30)"
    [ "$status" -eq 0 ]
    as alice stop
    printf 'c1\nc2\nc3\n' > "$R/stub/docker_ps"
    echo " [/nvme/bob/data:/data]" > "$R/stub/docker_label_c2"
    echo " []" > "$R/stub/docker_label_c3"
    as alice start --until "$(until_in 30)"
    [ "$status" -eq 1 ]
    [[ "$output" == *"ctr-c2(bob)"* ]]
    [[ "$output" == *"ctr-c3(dono desconhecido)"* ]]
    [[ "$output" != *"ctr-c1"* ]]
}

@test "Docker is ignored when the daemon does not answer" {
    echo c2 > "$R/stub/docker_ps"
    echo " [/home/bob:/x]" > "$R/stub/docker_label_c2"
    as alice start --until "$(until_in 30)"
    [ "$status" -eq 0 ]
}

@test "open sessions and crontabs of others are only warnings" {
    printf '3 1002 bob - 900 user - no -\n4 1001 alice - 901 user - no -\n5 1002 bob - 902 manager - no -\n' > "$R/stub/sessions"
    touch "$R/var/spool/cron/crontabs/carol" "$R/var/spool/cron/crontabs/root" "$R/var/spool/cron/crontabs/alice"
    as alice start --until "$(until_in 30)"
    [ "$status" -eq 0 ]
    [[ "$output" == *"sessões abertas de: bob (continuam abertas"* ]]
    [[ "$output" == *"crontabs de: carol (continuam rodando)"* ]]
}

# ---------------------------------------------------------------- stop

@test "stop by the owner undoes everything" {
    start_reservation alice
    : > "$R/calls.log"
    as alice stop
    [ "$status" -eq 0 ]
    [ "$output" = "Reserva de Alice Owner (alice) encerrada; logins liberados." ]
    [ ! -e "$R/etc/ssh/sshd_config.d/00-lock.conf" ]
    [ ! -e "$R/etc/lock.banner" ]
    [ ! -e "$R/etc/lock.state" ]
    calls | grep -qx "sshd -t"
    calls | grep -q "^systemctl try-reload-or-restart ssh.service"
    calls | grep -qx "systemctl stop lock-stop.timer"
    calls | grep -q "^wall A reserva de Alice Owner (alice) em testhost terminou"
}

@test "stop is idempotent" {
    as alice stop
    [ "$status" -eq 0 ]
    [ "$output" = "Nenhuma reserva ativa (nada a desfazer)." ]
}

@test "stop by another regular user is refused" {
    start_reservation alice
    as bob stop
    [ "$status" -eq 1 ]
    [[ "$output" == *"a reserva é de Alice Owner (alice)"* ]]
    [ -e "$R/etc/lock.state" ]
    [ -e "$R/etc/ssh/sshd_config.d/00-lock.conf" ]
}

@test "stop by an administrator ends someone else's reservation" {
    start_reservation alice
    as admin stop
    [ "$status" -eq 0 ]
    [ ! -e "$R/etc/lock.state" ]
}

@test "stop run directly by root (no sudo) is allowed" {
    start_reservation alice
    run "$LOCK" stop
    [ "$status" -eq 0 ]
    [ ! -e "$R/etc/lock.state" ]
}

@test "--timer and --boot are refused through sudo" {
    start_reservation alice
    as alice stop --timer
    [ "$status" -eq 1 ]; [[ "$output" == *"só para o systemd"* ]]
    as admin stop --boot
    [ "$status" -eq 1 ]; [[ "$output" == *"só para o systemd"* ]]
    as alice stop --force
    [ "$status" -eq 1 ]; [[ "$output" == *"uso: sudo lock stop"* ]]
    [ -e "$R/etc/lock.state" ]
}

@test "stop --timer reloads sshd but does not stop its own timer" {
    start_reservation alice
    : > "$R/calls.log"
    run "$LOCK" stop --timer
    [ "$status" -eq 0 ]
    [ ! -e "$R/etc/lock.state" ]
    calls | grep -q "^systemctl try-reload-or-restart ssh.service"
    refute_call "systemctl stop lock-stop.timer"
    calls | grep -q "^wall "
}

@test "stop --boot cleans up without touching sshd or broadcasting" {
    start_reservation alice
    : > "$R/calls.log"
    run "$LOCK" stop --boot
    [ "$status" -eq 0 ]
    [ ! -e "$R/etc/ssh/sshd_config.d/00-lock.conf" ]
    [ ! -e "$R/etc/lock.state" ]
    refute_call "^sshd"
    refute_call "try-reload"
    refute_call "^wall"
}

@test "stop --boot without reservation is silent" {
    run "$LOCK" stop --boot
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# ---------------------------------------------------------------- status

@test "status shows owner, end and who may log in, also to regular users" {
    start_reservation alice
    LOCK_TEST_UID=1002 run "$LOCK" status
    [ "$status" -eq 0 ]
    [[ "${lines[0]}" == "Reserva ativa em testhost: Alice Owner (alice) está medindo tempo até "*" (hora de Brasília)." ]]
    [ "${lines[1]}" = "Logins por ssh só para: admin alice. Em caso de urgência, fale com Alice Owner." ]
    [ "${#lines[@]}" -eq 2 ]
}

@test "configuration file overrides limits and time zone label" {
    cat >> "$R/etc/lock.conf" <<'EOF'
CPU_LIMIT=200
TIMEZONE=UTC
TIMEZONE_LABEL="UTC"
EOF
    proc 500 1002 bob 0; burn 500 300
    u=$(TZ=UTC gdate -d "+30 min" '+%Y-%m-%d %H:%M')
    as alice start --until "$u"
    [ "$status" -eq 0 ]
    [ "$(cut -d'|' -f2 "$R/etc/lock.state")" = "$(TZ=UTC gdate -d "$u" +%s)" ]
    grep -q "(UTC)" "$R/etc/lock.banner"
}
