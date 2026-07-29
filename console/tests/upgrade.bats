#!/usr/bin/env bats
#
# Upgrades.
#
# The maintenance parsers exist because "setup" is not one state. TeamCity uses
# the same 503 maintenance page for the licence agreement, a data directory
# upgrade and the first administrator, and the console used to announce the
# second of those whichever it was — telling a user to confirm an upgrade while
# TeamCity was asking them to accept a licence.

load helper

setup() {
    load_libs; default_conf; ui_speaks
    # shellcheck disable=SC1090
    source "$LIB/stack.sh"
    # shellcheck disable=SC1090
    source "$LIB/upgrade.sh"
}

page() {
    cat <<'HTML'


<!--
Page: maintenance-welcome
Stage: LICENSE_AGREEMENT_SCREEN
State revision: 28
Timestamp: Tue Jul 28 16:21:31 EDT 2026
[Stage description: Review and accept TeamCity license agreement to continue using the product]
-->
<!DOCTYPE html>
HTML
}

@test "the maintenance stage is read from the page TeamCity serves" {
    stack::_maintenance_page() { page; }
    run stack::maintenance_stage
    [ "$output" = 'LICENSE_AGREEMENT_SCREEN' ]
}

@test "the stage description is read verbatim, brackets stripped" {
    stack::_maintenance_page() { page; }
    run stack::maintenance_reason
    [ "$output" = 'Review and accept TeamCity license agreement to continue using the product' ]
}

@test "a data directory upgrade is reported as itself, not as a licence step" {
    stack::_maintenance_page() {
        printf '<!--\nStage: UPGRADE_DATA_DIRECTORY\n[Stage description: Confirm the data directory upgrade]\n-->\n'
    }
    [ "$(stack::maintenance_stage)" = 'UPGRADE_DATA_DIRECTORY' ]
    [ "$(stack::maintenance_reason)" = 'Confirm the data directory upgrade' ]
}

@test "an unreachable server yields nothing rather than a guess" {
    stack::_maintenance_page() { return 1; }
    [ -z "$(stack::maintenance_stage)" ]
    [ -z "$(stack::maintenance_reason)" ]
}

@test "a page with no marker yields nothing" {
    stack::_maintenance_page() { printf '<!DOCTYPE html><html><body>hello</body></html>\n'; }
    [ -z "$(stack::maintenance_stage)" ]
    [ -z "$(stack::maintenance_reason)" ]
}

@test "the maintenance probe does not use curl -f, which discards a 503 body" {
    # The maintenance page *is* a 503. -f would throw away the only thing worth
    # reading, and the stage would silently always be empty.
    run grep -A4 'stack::_maintenance_page()' "$LIB/stack.sh"
    [[ $output != *'curl -f'* ]]
}

@test "the maintenance probe addresses the host, not the console container" {
    run grep -A4 'stack::_maintenance_page()' "$LIB/stack.sh"
    [[ $output == *'host.docker.internal'* ]]
    [[ $output != *'localhost'* ]]
}

# The console addresses the user on stderr, which `run` does not capture, so the
# watcher is called through this rather than directly.
watch() { upgrade::_watch_maintenance "$@" 2>&1; }

@test "the watcher tells the user what TeamCity is actually asking for" {
    stack::server_ready()      { return 1; }
    stack::server_state()      { printf 'setup'; }
    stack::super_user_token()  { printf '8490157034461772482'; }
    stack::maintenance_reason() { printf 'Review and accept TeamCity license agreement to continue using the product'; }

    run watch
    [ "$status" -eq 0 ]
    [[ $output == *'accept TeamCity license agreement'* ]]
    [[ $output == *'8490157034461772482'* ]]
    [[ $output != *'confirm the data directory upgrade'* ]]
}

@test "with no reason available the watcher still says what to do, without inventing a step" {
    stack::server_ready()       { return 1; }
    stack::server_state()       { printf 'setup'; }
    stack::super_user_token()   { printf 'tok123'; }
    stack::maintenance_reason() { printf ''; }

    run watch
    [ "$status" -eq 0 ]
    [[ $output == *'maintenance page'* ]]
    [[ $output == *'tok123'* ]]
}

@test "a ready server needs no maintenance step at all" {
    stack::server_ready() { return 0; }
    run watch
    [ "$status" -eq 0 ]
    [[ $output == *'No maintenance confirmation was needed'* ]]
}

@test "the user is told this is a wait, not a hang" {
    stack::server_ready()       { return 1; }
    stack::server_state()       { printf 'setup'; }
    stack::super_user_token()   { printf 'tok123'; }
    stack::maintenance_reason() { printf 'Confirm the data directory upgrade'; }

    run watch
    [[ $output == *'not a hang'* ]]
}

@test "the rollback archive is named when one was taken" {
    stack::server_ready()       { return 1; }
    stack::server_state()       { printf 'setup'; }
    stack::super_user_token()   { printf 'tok123'; }
    stack::maintenance_reason() { printf 'Confirm the data directory upgrade'; }

    run watch "$BATS_TEST_TMPDIR/teamcity-cold-20260728-162003"
    [[ $output == *'teamcity-cold-20260728-162003'* ]]
    [[ $output == *'./tc restore'* ]]
}

# --- verify's reading of the same page -----------------------------------------

@test "a server that failed to start is not reported as awaiting setup" {
    # Both answer 503 with a maintenance page. Reported as a pass, a wedged
    # server looks like a stack waiting politely for its first administrator.
    stack::maintenance_stage()  { printf 'EXCEPTION'; }
    stack::maintenance_reason() { printf 'TeamCity server startup error'; }

    [ "$(stack::maintenance_stage)" = 'EXCEPTION' ]
    run grep -A10 'setup)' "$LIB/verify.sh"
    [[ $output == *'EXCEPTION'* ]]       || { echo 'verify does not distinguish a startup error'; return 1; }
    [[ $output == *'verify::_fail'* ]]   || { echo 'a startup error is still a pass'; return 1; }
    [[ $output == *'./tc logs server'* ]] || { echo 'no route to the cause'; return 1; }
}

@test "a genuine first run is still a pass, not a failure" {
    run grep -A10 'setup)' "$LIB/verify.sh"
    [[ $output == *'verify::_pass'* ]]
    [[ $output == *'awaiting first-run setup'* ]]
}

# --- booting is not the same as waiting for you --------------------------------

@test "a still-booting server reads as starting, not as awaiting setup" {
    stack::_probe() { [[ $1 == /mnt ]] && printf '200' || printf '503'; }
    stack::maintenance_stage() { printf 'APPLICATION_STARTING'; }
    [ "$(stack::server_state)" = 'starting' ]
}

@test "a server genuinely awaiting the licence still reads as setup" {
    stack::_probe() { [[ $1 == /mnt ]] && printf '200' || printf '503'; }
    stack::maintenance_stage() { printf 'LICENSE_AGREEMENT_SCREEN'; }
    [ "$(stack::server_state)" = 'setup' ]
}

@test "an unreadable stage falls back to setup rather than looping forever" {
    # Silence must not turn a genuine first run into an endless wait.
    stack::_probe() { [[ $1 == /mnt ]] && printf '200' || printf '503'; }
    stack::maintenance_stage() { printf ''; }
    [ "$(stack::server_state)" = 'setup' ]
}

@test "a server answering on login.html is ready regardless of any stage" {
    stack::_probe() { printf '200'; }
    stack::maintenance_stage() { printf 'APPLICATION_STARTING'; }
    [ "$(stack::server_state)" = 'ready' ]
}

@test "a server answering nothing is starting, without a page fetch" {
    stack::_probe() { printf '000'; }
    stack::maintenance_stage() { echo 'the page should not have been fetched' >&2; printf 'X'; }
    [ "$(stack::server_state)" = 'starting' ]
}

@test "a restored stack is not told to create the administrator it already has" {
    # The regression in one line: booting reads as starting, so nothing downstream
    # reaches the first-run guidance.
    stack::_probe() { [[ $1 == /mnt ]] && printf '200' || printf '503'; }
    stack::maintenance_stage() { printf 'APPLICATION_STARTING'; }

    run stack::server_responding
    [ "$status" -ne 0 ] || { echo 'a booting server was treated as responding'; return 1; }
    run stack::server_ready
    [ "$status" -ne 0 ]
}
