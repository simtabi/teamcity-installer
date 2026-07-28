#!/usr/bin/env bash
#
# Shared test setup.
#
# The libraries are sourced directly and the few functions that reach for the
# Docker daemon or the network are stubbed. That keeps the suite pure: it runs
# with no daemon, no containers and no internet, so it can gate a commit.

LIB="${BATS_TEST_DIRNAME}/../lib"

load_libs() {
    # load_libs repoints TC_ROOT at a scratch directory, so remember where the
    # real project is for tests that need to read tracked files.
    PROJECT_ROOT="${TC_ROOT:-$PWD}"

    # log.sh first: ui.sh routes every message through it.
    # shellcheck disable=SC1090
    source "$LIB/log.sh"
    # shellcheck disable=SC1090
    source "$LIB/ui.sh"

    export TC_ROOT="$BATS_TEST_TMPDIR/project"
    mkdir -p "$TC_ROOT/stack" "$TC_ROOT/backups"

    # shellcheck disable=SC1090
    source "$LIB/conf.sh"
    # shellcheck disable=SC1090
    source "$LIB/validate.sh"
    # shellcheck disable=SC1090
    source "$LIB/render.sh"
    # shellcheck disable=SC1090
    source "$LIB/backup.sh"

    # Deterministic stand-ins for the host facts the validators consult.
    _TC_NCPU=8
    _TC_MEM=$(( 16 * 1024 * 1024 * 1024 ))

    # No daemon in the test environment.
    docker() { return 1; }
    validate::_host_port_listening() { return 1; }

    # Quiet: these tests assert on return codes, not on prose.
    ui::err()  { :; }
    ui::warn() { :; }
    ui::note() { :; }
    ui::info() { :; }
    ui::ok()   { :; }
}

# Undo that silence.
#
# Most tests assert on return codes, so quiet is right for them. A few assert on
# what the user is actually told — an upgrade that announces the wrong step is a
# real defect and a passing exit code hides it — and those need the genuine
# implementations back.
ui_speaks() {
    # shellcheck disable=SC1090
    source "$LIB/ui.sh"
}

# A known-good configuration, so each test only varies what it is about.
default_conf() {
    TC_STACK=teamcity
    TC_VERSION=2026.1.3
    TC_PORT=8111
    TC_TZ=UTC
    TC_DB=postgres
    TC_PG_VERSION=17
    TC_PG_DB=teamcity
    TC_PG_USER=teamcity
    # Obviously invented. An earlier version used a value derived from a real
    # stack's password, which a secret scanner correctly flagged once the repo
    # went public — a fixture must never be a truncation of anything real.
    TC_PG_PASSWORD='example-password-not-a-real-secret'
    TC_JDBC_VERSION=42.7.13
    TC_MEM_OPTS='-Xmx2g -XX:ReservedCodeCacheSize=640m'
    TC_AGENTS=3
    TC_AGENT_IMAGE=full
    TC_AGENT_DOCKER=none
}

write_manifest() {
    local dir=$1; shift
    mkdir -p "$dir"
    printf '%s' "$1" > "$dir/manifest.json"
}
