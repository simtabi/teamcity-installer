#!/usr/bin/env bats
#
# Restore compatibility guards.
#
# Each of these combinations produces a server that will not start, with an
# error that does not explain why. Catching them before the stack is torn down
# is the whole point.

load helper

setup() {
    load_libs
    default_conf
    MANIFEST="$BATS_TEST_TMPDIR/manifest.json"
}

manifest() {
    local kind=${1:-cold} version=${2:-2026.1.3} db=${3:-postgres} pg=${4:-17}
    jq -n --arg k "$kind" --arg v "$version" --arg d "$db" --arg p "$pg" \
        '{kind:$k, stack:"teamcity", teamcity_version:$v, database:$d, postgres_major:$p, agents:3}' \
        > "$MANIFEST"
}

@test "an identical archive is accepted" {
    manifest cold 2026.1.3 postgres 17
    run backup::_check_compatible "$MANIFEST"
    [ "$status" -eq 0 ]
}

@test "an older archive is accepted" {
    manifest cold 2026.1.1 postgres 17
    run backup::_check_compatible "$MANIFEST"
    [ "$status" -eq 0 ]
}

@test "a newer TeamCity archive is refused" {
    manifest cold 2027.1 postgres 17
    run backup::_check_compatible "$MANIFEST"
    [ "$status" -ne 0 ]
}

@test "version comparison is numeric, not lexical" {
    # 2026.1.10 is newer than the running 2026.1.9 despite sorting lower as text.
    TC_VERSION=2026.1.9
    manifest cold 2026.1.10 postgres 17
    run backup::_check_compatible "$MANIFEST"
    [ "$status" -ne 0 ]

    # And the reverse must be allowed.
    TC_VERSION=2026.1.10
    manifest cold 2026.1.9 postgres 17
    run backup::_check_compatible "$MANIFEST"
    [ "$status" -eq 0 ]
}

@test "a different database backend is refused" {
    manifest cold 2026.1.3 hsqldb 17
    run backup::_check_compatible "$MANIFEST"
    [ "$status" -ne 0 ]
}

@test "a cold archive from another PostgreSQL major is refused" {
    manifest cold 2026.1.3 postgres 16
    run backup::_check_compatible "$MANIFEST"
    [ "$status" -ne 0 ]
}

@test "a logical archive crosses PostgreSQL majors" {
    # pg_dump replays into any major; only a raw PGDATA tar is pinned.
    manifest logical 2026.1.3 postgres 16
    run backup::_check_compatible "$MANIFEST"
    [ "$status" -eq 0 ]
}

@test "a native archive crosses PostgreSQL majors" {
    manifest native 2026.1.3 postgres 16
    run backup::_check_compatible "$MANIFEST"
    [ "$status" -eq 0 ]
}
