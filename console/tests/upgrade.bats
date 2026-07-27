#!/usr/bin/env bats
#
# Upgrade direction guard. TeamCity will not start against a data directory a
# newer server has already upgraded, and says so unhelpfully.

load helper

setup() {
    load_libs
    default_conf
    # shellcheck disable=SC1090
    source "$LIB/upgrade.sh"
}

@test "upgrading forward is allowed" {
    TC_VERSION=2026.1.1
    run upgrade::_check_direction 2026.1.3
    [ "$status" -eq 0 ]
}

@test "downgrading is refused" {
    TC_VERSION=2026.1.3
    run upgrade::_check_direction 2026.1.1
    [ "$status" -ne 0 ]
}

@test "across minor versions" {
    TC_VERSION=2025.11.7
    run upgrade::_check_direction 2026.1
    [ "$status" -eq 0 ]

    TC_VERSION=2026.1
    run upgrade::_check_direction 2025.11.7
    [ "$status" -ne 0 ]
}

@test "double-digit patches compare numerically" {
    TC_VERSION=2026.1.9
    run upgrade::_check_direction 2026.1.10
    [ "$status" -eq 0 ]

    TC_VERSION=2026.1.10
    run upgrade::_check_direction 2026.1.9
    [ "$status" -ne 0 ]
}
