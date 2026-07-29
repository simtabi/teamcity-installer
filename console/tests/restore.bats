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

# --- retention across stacks ---------------------------------------------------
#
# Archive names carry no stack — every one is "teamcity-<kind>-<stamp>" whatever
# the stack is called. A second stack sharing the checkout counted its backups
# against the same limit and deleted the first stack's, oldest-first.

_archive() {   # _archive <name> <stack>
    mkdir -p "$BACKUP_DIR/$1"
    printf '{"kind":"cold","stack":"%s"}\n' "$2" > "$BACKUP_DIR/$1/manifest.json"
}

@test "retention counts only this stack's archives" {
    TC_STACK=teamcity TC_BACKUP_KEEP=2
    _archive teamcity-cold-1 teamcity
    _archive teamcity-cold-2 teamcity
    _archive teamcity-cold-3 teamcity

    run backup::prune
    [ ! -d "$BACKUP_DIR/teamcity-cold-1" ]     # oldest of ours, correctly gone
    [ -d "$BACKUP_DIR/teamcity-cold-2" ]
    [ -d "$BACKUP_DIR/teamcity-cold-3" ]
}

@test "another stack's archives are never deleted by our retention" {
    TC_STACK=teamcity TC_BACKUP_KEEP=1
    _archive teamcity-cold-1 tcupg
    _archive teamcity-cold-2 tcupg
    _archive teamcity-cold-3 teamcity

    run backup::prune
    [ -d "$BACKUP_DIR/teamcity-cold-1" ] || { echo "deleted another stack's backup"; return 1; }
    [ -d "$BACKUP_DIR/teamcity-cold-2" ] || { echo "deleted another stack's backup"; return 1; }
    [ -d "$BACKUP_DIR/teamcity-cold-3" ]
}

@test "an unattributable archive is left alone rather than pruned" {
    TC_STACK=teamcity TC_BACKUP_KEEP=1
    mkdir -p "$BACKUP_DIR/teamcity-cold-mystery"       # no manifest at all
    _archive teamcity-cold-2 teamcity

    run backup::prune
    [ -d "$BACKUP_DIR/teamcity-cold-mystery" ] || { echo 'deleted a backup it could not identify'; return 1; }
    [ -d "$BACKUP_DIR/teamcity-cold-2" ]
}

@test "the owning stack is read from the manifest" {
    _archive teamcity-cold-9 someplace
    [ "$(backup::_archive_stack "$BACKUP_DIR/teamcity-cold-9")" = 'someplace' ]
}

@test "an archive with no manifest has no owner, rather than a wrong one" {
    mkdir -p "$BACKUP_DIR/teamcity-cold-bare"
    [ -z "$(backup::_archive_stack "$BACKUP_DIR/teamcity-cold-bare")" ]
}

@test "retention still prunes normally when every archive is ours" {
    TC_STACK=teamcity TC_BACKUP_KEEP=1
    _archive teamcity-cold-1 teamcity
    _archive teamcity-cold-2 teamcity
    run backup::prune
    [ ! -d "$BACKUP_DIR/teamcity-cold-1" ]
    [ -d "$BACKUP_DIR/teamcity-cold-2" ]
}

# --- retention order -----------------------------------------------------------
#
# `find | sort` sorts paths as strings, and every archive name begins with its
# kind, so every "teamcity-cold-…" preceded every "teamcity-logical-…" whatever
# the dates were. Retention deleted from the front of that list calling each one
# the oldest — which, with a cold backup taken minutes ago and a logical one from
# the morning, meant deleting the newest archive on the machine.

@test "archives come back in age order, not kind order" {
    _archive teamcity-logical-20260728-101354 teamcity
    _archive teamcity-native-20260728-101609  teamcity
    _archive teamcity-cold-20260728-230243    teamcity
    _archive teamcity-logical-20260728-230515 teamcity

    run backup::_archives_oldest_first
    [ "${lines[0]##*/}" = 'teamcity-logical-20260728-101354' ]
    [ "${lines[1]##*/}" = 'teamcity-native-20260728-101609' ]
    [ "${lines[2]##*/}" = 'teamcity-cold-20260728-230243' ]
    [ "${lines[3]##*/}" = 'teamcity-logical-20260728-230515' ]
}

@test "retention deletes the genuinely oldest, across kinds" {
    TC_STACK=teamcity TC_BACKUP_KEEP=2
    _archive teamcity-logical-20260728-101354 teamcity   # oldest
    _archive teamcity-native-20260728-101609  teamcity   # next
    _archive teamcity-cold-20260728-230243    teamcity   # newest but sorts first by name
    _archive teamcity-logical-20260728-230515 teamcity   # newest

    run backup::prune
    [ ! -d "$BACKUP_DIR/teamcity-logical-20260728-101354" ]
    [ ! -d "$BACKUP_DIR/teamcity-native-20260728-101609" ]
    [ -d "$BACKUP_DIR/teamcity-cold-20260728-230243" ]    || { echo 'deleted the newest cold archive'; return 1; }
    [ -d "$BACKUP_DIR/teamcity-logical-20260728-230515" ] || { echo 'deleted the newest logical archive'; return 1; }
}

@test "a kind sorting first alphabetically is not treated as oldest" {
    TC_STACK=teamcity TC_BACKUP_KEEP=1
    _archive teamcity-cold-20260729-090000    teamcity   # newest, but "cold" < "logical"
    _archive teamcity-logical-20260701-090000 teamcity   # a month older

    run backup::prune
    [ -d "$BACKUP_DIR/teamcity-cold-20260729-090000" ] || { echo 'deleted the newer archive'; return 1; }
    [ ! -d "$BACKUP_DIR/teamcity-logical-20260701-090000" ]
}

@test "dates order before times within the same day" {
    _archive teamcity-cold-20260728-235959 teamcity
    _archive teamcity-cold-20260729-000001 teamcity
    run backup::_archives_oldest_first
    [ "${lines[0]##*/}" = 'teamcity-cold-20260728-235959' ]
}

@test "an oddly named directory is still ordered deterministically, not dropped" {
    _archive teamcity-cold-20260728-101010 teamcity
    _archive teamcity-strange              teamcity
    run backup::_archives_oldest_first
    [ "${#lines[@]}" -eq 2 ] || { echo 'an archive vanished from the list'; return 1; }
}

# --- one owner per fact --------------------------------------------------------
#
# These are guards against a repeat, not against a specific bug. The same defect
# was fixed three times in three modules because each module had re-derived a
# fact it should have asked for. A grep-shaped test is crude, but it fails when
# someone reintroduces the duplication, which is the only property that matters
# here.

@test "archive ordering has exactly one implementation" {
    # Every other listing must go through it, or half of them sort by kind.
    run grep -n 'find "\$BACKUP_DIR".*teamcity-\*' "$LIB/backup.sh"
    local offenders=0 line
    while IFS= read -r line; do
        [[ $line == *'_archives_oldest_first'* ]] && continue
        [[ $line == *'sort'* ]] && { echo "sorts archives itself: $line"; offenders=$((offenders+1)); }
    done <<< "$output"
    [ "$offenders" -eq 0 ]
}

@test "the restore chooser and the listing share that ordering" {
    run grep -c '_archives_oldest_first' "$LIB/backup.sh"
    [ "$output" -ge 3 ]     # the definition, prune, list, restore
}
