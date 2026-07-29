#!/usr/bin/env bats
#
# The smoke build.
#
# Every other check this console makes is a precondition: containers healthy,
# volumes mapped, REST answering, agents authorized. None of it is evidence that
# a build will run, and for most of this project's life nobody had ever asked the
# server to run one.
#
# The property these guard is the one that makes the check worth having: a green
# status is TeamCity's opinion, and only output in the build log proves the step
# executed.

load helper

setup() {
    load_libs; default_conf; ui_speaks
    # shellcheck disable=SC1090
    source "$LIB/stack.sh"
    # shellcheck disable=SC1090
    source "$LIB/agents.sh"
    # shellcheck disable=SC1090
    source "$LIB/smoke.sh"
}

@test "a green build with no step output is a failure, not a pass" {
    # A build whose step silently never ran still reports SUCCESS. Without this,
    # the check would confirm TeamCity's opinion of itself.
    agents::_rest() { printf '{"id":7,"status":"SUCCESS","agent":{"name":"a1"}}'; }
    agents::_rest_raw() { printf 'Build 7\nFinished with status NORMAL\n'; }

    run smoke::_assert 7 'marker-that-never-appeared'
    [ "$status" -ne 0 ]
    [[ $output == *'produced no output'* ]]
}

@test "a green build whose marker appears in the log passes" {
    agents::_rest() { printf '{"id":7,"status":"SUCCESS","agent":{"name":"a1"}}'; }
    agents::_rest_raw() { printf 'Step 1/1: tc-smoke-123-456\nLinux aarch64\n'; }

    run smoke::_assert 7 'tc-smoke-123-456'
    [ "$status" -eq 0 ]
    [[ $output == *'succeeded'* ]]
}

@test "a failed build reports its status and where to look" {
    agents::_rest() { printf '{"id":7,"status":"FAILURE","statusText":"step 1 exited 1","agent":{"name":"a1"}}'; }
    agents::_rest_raw() { printf ''; }

    run smoke::_assert 7 'anything'
    [ "$status" -ne 0 ]
    [[ $output == *'FAILURE'* ]]
    [[ $output == *'step 1 exited 1'* ]]
}

@test "the marker is unique per run, so a stale log cannot satisfy it" {
    # Reusing a fixed string would let last week's build log pass this week's
    # check, which is exactly the failure mode being guarded against.
    run grep -n 'marker=' "$LIB/smoke.sh"
    [[ $output == *'date +%s'* ]]
}

@test "no available agent is reported as that, not as a timeout" {
    # A build with nowhere to run sits in the queue until the deadline, and
    # "timed out after 300s" sends someone looking in entirely the wrong place.
    run grep -B4 -A4 'No connected, authorized agent' "$LIB/smoke.sh"
    [[ $output == *'authorized:true,connected:true'* ]]
    [[ $output == *'./tc agents'* ]]
}

@test "the throwaway project is removed on every exit path" {
    # Including a failure part-way through creation: a leftover project makes the
    # next run fail on a name clash, turning one bad run into a broken command.
    run grep -n 'trap .*smoke::_cleanup' "$LIB/smoke.sh"
    [ "$status" -eq 0 ]
    [[ $output == *'RETURN'* ]]
}

@test "a leftover project from an earlier crash is cleared before starting" {
    run grep -n 'smoke::_cleanup_quiet' "$LIB/smoke.sh"
    [ "$(printf '%s\n' "$output" | grep -c .)" -ge 2 ]   # called, and defined
}

@test "the waiting loop reports why a build is not running yet" {
    run grep -A12 '^smoke::_await()' "$LIB/smoke.sh"
    [[ $output == *'waitReason'* ]] || { echo 'no reason surfaced while queued'; return 1; }
}

@test "the timeout is adjustable rather than hardcoded" {
    run grep -n 'SMOKE_TIMEOUT=' "$LIB/smoke.sh"
    [[ $output == *'${SMOKE_TIMEOUT:-'* ]]
}

@test "the build check is what makes --deep deeper" {
    # Before this, --deep only lifted a time budget: a flag that added no
    # coverage while its name promised more.
    # shellcheck disable=SC1090
    source "$LIB/verify.sh"
    run grep -A4 '^verify::_build()' "$LIB/verify.sh"
    [[ $output == *'VERIFY_DEEP'* ]]
    grep -q 'verify::_build' "$LIB/verify.sh"
}

@test "smoke is reachable from the command line and the menu" {
    grep -qE '^ +smoke\)' "$LIB/main.sh" || { echo 'not dispatched'; return 1; }
    grep -q "'Smoke build|" "$LIB/main.sh"
    declare -F smoke::run >/dev/null
}
