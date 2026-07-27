#!/usr/bin/env bats
#
# Logging.
#
# Redaction is the reason most of this file exists. Unlike the diagnostics
# bundle, which is built on demand, this surface writes continuously and lands on
# disk — a secret that reaches it stays there.

load helper

setup() {
    load_libs
    default_conf
    export LOG_DIR="$BATS_TEST_TMPDIR/logs"
    # shellcheck disable=SC1090
    source "$LIB/log.sh"
    LOG_DIR="$BATS_TEST_TMPDIR/logs"
    TC_SESSION='test'
    TC_LOG_LEVEL='DEBUG'
    mkdir -p "$LOG_DIR"
}

# --- routing ------------------------------------------------------------------

@test "the scope prefix picks the file" {
    log::info stack.up 'starting'
    log::info backup.cold 'archiving'
    [ -f "$LOG_DIR/stack.log" ]
    [ -f "$LOG_DIR/backup.log" ]
    grep -q 'starting'  "$LOG_DIR/stack.log"
    grep -q 'archiving' "$LOG_DIR/backup.log"
}

@test "a line carries all six fields" {
    log::info stack.up 'a message here'
    run cat "$LOG_DIR/stack.log"
    # timestamp  LEVEL  session  scope  stack  message
    [[ $output =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[+-][0-9]{4}[[:space:]]+INFO[[:space:]]+test[[:space:]]+stack\.up[[:space:]]+teamcity[[:space:]]+a\ message\ here$ ]]
}

@test "one session id links a run across tools" {
    log::info stack.up 'x'
    log::info backup.cold 'y'
    [ "$(grep -hc '  test  ' "$LOG_DIR"/*.log | paste -sd+ - | bc)" -eq 2 ]
}

# --- redaction ----------------------------------------------------------------

@test "the configured database password never reaches disk" {
    log::info stack.up "connecting as $TC_PG_USER with $TC_PG_PASSWORD"
    run grep -F "$TC_PG_PASSWORD" "$LOG_DIR/stack.log"
    [ "$status" -ne 0 ]
    grep -q '«redacted»' "$LOG_DIR/stack.log"
}

@test "credential-shaped text is redacted whatever its source" {
    log::info stack.up 'password=hunter2 token=abc123def456 more'
    log::info stack.up 'Authorization: Bearer eyJhbGciOi.signature'
    log::info stack.up 'POSTGRES_PASSWORD=s3cr3tvalue'

    run cat "$LOG_DIR/stack.log"
    [[ $output != *hunter2* ]]
    [[ $output != *abc123def456* ]]
    [[ $output != *eyJhbGciOi.signature* ]]
    [[ $output != *s3cr3tvalue* ]]
}

@test "redaction does not eat the surrounding message" {
    log::info stack.up 'connecting with password=hunter2 to the database'
    grep -q 'connecting with' "$LOG_DIR/stack.log"
    grep -q 'to the database' "$LOG_DIR/stack.log"
}

# --- levels -------------------------------------------------------------------

@test "level filtering drops anything below the threshold" {
    TC_LOG_LEVEL=ERROR
    log::debug stack.up 'debug line'
    log::info  stack.up 'info line'
    log::warn  stack.up 'warn line'
    log::error stack.up 'error line'

    run cat "$LOG_DIR/stack.log"
    [[ $output != *'debug line'* ]]
    [[ $output != *'info line'* ]]
    [[ $output != *'warn line'* ]]
    [[ $output == *'error line'* ]]
}

@test "OFF writes nothing" {
    TC_LOG_LEVEL=OFF
    log::error stack.up 'should not appear'
    [ ! -s "$LOG_DIR/stack.log" ] || [ ! -f "$LOG_DIR/stack.log" ]
}

# --- rotation -----------------------------------------------------------------

@test "a log rotates at the size limit and keeps only TC_LOG_KEEP" {
    TC_LOG_MAX_KB=1
    TC_LOG_KEEP=3

    local i
    for i in $(seq 1 400); do
        log::info stack.up "padding line $i ----------------------------------------"
    done

    [ -f "$LOG_DIR/stack.log" ]
    [ -f "$LOG_DIR/stack.log.1" ]
    [ ! -f "$LOG_DIR/stack.log.4" ]
}

# --- robustness ---------------------------------------------------------------

@test "logging never fails the operation it describes" {
    LOG_DIR=/proc/nonexistent/nope
    run log::info stack.up 'this cannot be written anywhere'
    [ "$status" -eq 0 ]
}

@test "every tool the console names has a routable scope" {
    local t
    for t in $(log::tools); do
        log::info "$t.check" 'x'
        [ -f "$LOG_DIR/$t.log" ] || { echo "no file for tool: $t"; return 1; }
    done
}
