#!/usr/bin/env bats
#
# Validators.
#
# Includes a regression for the mem_opts pattern, which was written as an
# unquoted regex containing a space — bash splits that operand, so the check was
# a syntax error rather than the check it appeared to be.

load helper

setup() {
    load_libs; default_conf
    # shellcheck disable=SC1090
    source "$LIB/upgrade.sh"   # the direction guard is validation in all but name
}

# --- memory -------------------------------------------------------------------

@test "mem_opts accepts the image default with both flags" {
    run validate::mem_opts '-Xmx2g -XX:ReservedCodeCacheSize=640m'
    [ "$status" -eq 0 ]
}

@test "mem_opts rejects a heap below TeamCity's floor" {
    run validate::mem_opts '-Xmx256m'
    [ "$status" -ne 0 ]
}

@test "mem_opts accepts exactly 1g" {
    run validate::mem_opts '-Xmx1g'
    [ "$status" -eq 0 ]
}

@test "mem_opts requires an -Xmx" {
    run validate::mem_opts '-XX:ReservedCodeCacheSize=640m'
    [ "$status" -ne 0 ]
}

@test "mem_opts rejects shell metacharacters" {
    run validate::mem_opts '-Xmx2g; rm -rf /'
    [ "$status" -ne 0 ]
}

@test "mem_opts rejects empty" {
    run validate::mem_opts ''
    [ "$status" -ne 0 ]
}

# --- passwords ----------------------------------------------------------------

@test "db_password rejects anything shorter than 16" {
    run validate::db_password '0123456789abcde'
    [ "$status" -ne 0 ]
}

@test "db_password rejects characters that break .env or the JDBC URL" {
    for bad in 'aaaaaaaaaaaaaaaa$x' 'aaaaaaaaaaaaaaaa"x' "aaaaaaaaaaaaaaaa'x" 'aaaaaaaaaaaaaaaa\x' 'aaaaaaaaaaaaaaaa`x'; do
        run validate::db_password "$bad"
        [ "$status" -ne 0 ] || { echo "accepted: $bad"; return 1; }
    done
}

@test "generated passwords always satisfy the password validator" {
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        local pw; pw=$(validate::gen_password)
        run validate::db_password "$pw"
        [ "$status" -eq 0 ] || { echo "generated an invalid password: $pw"; return 1; }
    done
}

# --- names --------------------------------------------------------------------

@test "stack_name accepts a plain lowercase name" {
    run validate::stack_name 'teamcity'
    [ "$status" -eq 0 ]
}

@test "stack_name rejects names Docker cannot use as a project prefix" {
    for bad in 'Bad_Name' 'UPPER' '9lives' '-leading' 'a' 'has space' ''; do
        run validate::stack_name "$bad"
        [ "$status" -ne 0 ] || { echo "accepted: $bad"; return 1; }
    done
}

@test "db_identifier rejects a leading digit" {
    run validate::db_identifier '9db'
    [ "$status" -ne 0 ]
}

# --- ports --------------------------------------------------------------------

@test "port rejects privileged, out-of-range and non-numeric" {
    for bad in 80 1023 65536 99999 abc ''; do
        run validate::port "$bad"
        [ "$status" -ne 0 ] || { echo "accepted: $bad"; return 1; }
    done
}

@test "port accepts a free unprivileged port" {
    run validate::port 8111
    [ "$status" -eq 0 ]
}

# --- agents -------------------------------------------------------------------

@test "agent_count accepts up to the free licence limit" {
    for n in 0 1 2 3; do
        run validate::agent_count "$n"
        [ "$status" -eq 0 ] || { echo "rejected: $n"; return 1; }
    done
}

@test "agent_count refuses to exceed the licence without an explicit opt-in" {
    run validate::agent_count 4
    [ "$status" -ne 0 ]
}

@test "agent_count allows exceeding the licence when opted in" {
    TC_ALLOW_EXTRA_AGENTS=1
    run validate::agent_count 4
    [ "$status" -eq 0 ]
}

# --- timezone -----------------------------------------------------------------

@test "timezone accepts a real zone and rejects a fictional one" {
    run validate::timezone 'UTC';           [ "$status" -eq 0 ]
    run validate::timezone 'Europe/Berlin'; [ "$status" -eq 0 ]
    run validate::timezone 'Mars/Olympus';  [ "$status" -ne 0 ]
}

# --- version ------------------------------------------------------------------

@test "tc_version rejects tags that are not TeamCity versions" {
    for bad in latest 2026 v2026.1 ''; do
        run validate::tc_version "$bad"
        [ "$status" -ne 0 ] || { echo "accepted: $bad"; return 1; }
    done
}

# --- upgrade direction ---------------------------------------------------------

# The console addresses the user on stderr, which `run` does not capture.
direction() { upgrade::_check_direction "$@" 2>&1; }

@test "an older target is refused, and the message says why" {
    ui_speaks
    TC_VERSION=2026.1.3
    run direction 2025.11.7
    [ "$status" -eq 1 ]
    [[ $output == *'older than the running 2026.1.3'* ]]
    [[ $output == *'restore a'* ]] || { echo 'no route back offered'; return 1; }
}

@test "upgrade direction sorts 2026.1.10 above 2026.1.9" {
    # Lexically, "2026.1.10" < "2026.1.9" — the guard would then refuse a real
    # upgrade and wave through a real downgrade. sort -V is what stops that.
    TC_VERSION=2026.1.9
    run upgrade::_check_direction 2026.1.10
    [ "$status" -eq 0 ]

    TC_VERSION=2026.1.10
    run upgrade::_check_direction 2026.1.9
    [ "$status" -eq 1 ]
}

@test "an unqualified version upgrades to its own patch releases" {
    TC_VERSION=2026.1
    run upgrade::_check_direction 2026.1.1
    [ "$status" -eq 0 ]
}

@test "the memory probe survives an unreachable Docker daemon" {
    # `docker info --format` prints "0" for the template and exits non-zero when
    # it cannot connect, so a naive `|| echo 0` yields two lines and the caller's
    # (( )) dies with a bash syntax error.
    docker() { printf '0\n'; return 1; }
    unset _TC_MEM

    run validate::_docker_mem_bytes
    [ "$status" -eq 0 ]
    [ "$output" = '0' ]

    unset _TC_MEM
    local vm; vm=$(validate::_docker_mem_bytes)
    run bash -c "(( $vm > 0 ))"           # must be a valid expression, not a parse error
    [ "$status" -eq 1 ]
}

@test "a garbage memory reading is treated as unknown, not as a size" {
    docker() { printf 'error during connect\n'; return 1; }
    unset _TC_MEM
    run validate::_docker_mem_bytes
    [ "$output" = '0' ]
}
