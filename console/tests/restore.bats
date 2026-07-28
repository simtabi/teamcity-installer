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

# --- credentials must survive a restore intact --------------------------------
#
# An archive carries its own database credentials in the restored
# database.properties, and the PostgreSQL volume expects them. stack/.env keeps
# whatever it held before, so a restore left the config claiming a password the
# database did not have — invisible until the pgdata volume was recreated.

@test "restore realigns .env with the restored data directory" {
    default_conf
    source "$LIB/backup.sh"

    TC_PG_PASSWORD='example-old-password'
    docker() { printf 'example-archive-password'; }
    conf::save() { SAVED=1; }
    ui::note() { :; }

    backup::_realign_db_password
    [ "$TC_PG_PASSWORD" = 'example-archive-password' ]
    [ "${SAVED:-0}" = 1 ]
}

@test "realignment is a no-op when the passwords already agree" {
    default_conf
    source "$LIB/backup.sh"

    TC_PG_PASSWORD='same'
    docker() { printf 'same'; }
    conf::save() { SAVED=1; }

    backup::_realign_db_password
    [ "${SAVED:-0}" = 0 ]
}

@test "realignment is skipped for the bundled database" {
    default_conf
    source "$LIB/backup.sh"
    TC_DB=hsqldb
    conf::save() { SAVED=1; }
    backup::_realign_db_password
    [ "${SAVED:-0}" = 0 ]
}

# --- the native restore has three preconditions --------------------------------
#
# maintainDB refuses to run unless: the data directory's config/ is empty, the
# target database settings file exists *outside* that directory, and the target
# database has no tables. Each was discovered by hitting it, and the first two
# are circular — it needs a database.properties to know where to restore, and
# putting one in the data directory is what makes config/ non-empty.

@test "the target database settings live outside the data directory" {
    # -T must not point into the data directory, or config/ is never empty.
    run grep -oE '\-T [^ ]+' "$LIB/backup.sh"
    [ "$status" -eq 0 ]
    [[ $output != *"/data/teamcity_server/datadir"* ]] \
        || { echo "-T points inside the data directory: $output"; return 1; }
}

@test "the staging directory is under the project, not the container's /tmp" {
    # Bind-mount sources are resolved by the daemon on the host; a path from the
    # console's own mktemp does not exist there and mounts as empty.
    grep -q 'BACKUP_DIR/.restore-staging' "$LIB/backup.sh"
    run grep -n 'staging=$(mktemp -d)$' "$LIB/backup.sh"
    [ "$status" -ne 0 ]
}

@test "the native restore clears the data directory and the database first" {
    local fn; fn=$(sed -n '/^backup::_restore_native/,/^}/p' "$LIB/backup.sh")
    [[ $fn == *"find /d -mindepth 1 -delete"* ]] || { echo 'data directory is not cleared'; return 1; }
    [[ $fn == *'DROP SCHEMA'* ]]                 || { echo 'target database is not cleared'; return 1; }
    # …but keeps the driver it needs to reach PostgreSQL at all.
    [[ $fn == *'postgresql-*.jar'* ]]            || { echo 'JDBC driver is not preserved'; return 1; }
}

@test "restored volumes are labelled so Compose does not disown them" {
    grep -q 'com.docker.compose.project' "$LIB/backup.sh"
    run grep -n 'docker volume create "' "$LIB/backup.sh"
    [ "$status" -ne 0 ]
}
