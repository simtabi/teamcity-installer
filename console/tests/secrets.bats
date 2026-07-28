#!/usr/bin/env bats
#
# Secret hygiene in the repository itself.
#
# This file exists because a real credential reached a public commit. The test
# fixture held a 24-character truncation of a live database password, and the
# pre-publication scan searched for the *whole* 32-character value — so a prefix
# never matched. A secret scanner caught it after the fact.
#
# The lesson is that "grep for the secret you know about" is the wrong shape of
# check. These assert the properties instead: fixtures must be self-evidently
# fake, and only the example env file may be tracked.

load helper

setup() {
    PROJECT="${TC_ROOT:?TC_ROOT must be set — run through ./tc}"
    [ -d "$PROJECT" ] || skip 'project not reachable'
}

@test "no tracked file carries a high-entropy credential literal" {
    command -v git >/dev/null || skip 'git unavailable'
    cd "$PROJECT"

    # Only files git actually tracks. The live stack/.env holds a real password
    # by design and is ignored; scanning the working tree instead of the index
    # would flag it forever and train everyone to ignore this test.
    local hits
    hits=$(git ls-files -z | xargs -0 grep -InE "(PASSWORD|TOKEN|SECRET)[A-Z_]*=['\"][^'\"]{12,}['\"]" 2>/dev/null \
           | grep -vE 'example|placeholder|not-a-real|redacted|fake|dummy|000000' \
           | grep -v '\$' || true)   # a value containing $ is a reference, not a literal

    [ -z "$hits" ] || { echo "possible credential literal:"; echo "$hits"; return 1; }
}

@test "the example env file ships no filled-in credentials" {
    local example="$PROJECT/stack/.env.example"
    [ -f "$example" ]

    # Every secret-ish key must be present but empty.
    local key
    for key in TC_PG_PASSWORD TC_ADMIN_PASSWORD; do
        grep -qE "^$key=''\$" "$example" \
            || { echo "$key in .env.example is not empty"; return 1; }
    done
}

@test "the live env file is ignored, and near-miss names too" {
    command -v git >/dev/null || skip 'git unavailable'
    cd "$PROJECT"
    git check-ignore -q stack/.env      || { echo 'stack/.env is not ignored'; return 1; }
    git check-ignore -q stack/.secrets  || { echo 'stack/.secrets is not ignored'; return 1; }
    # A stray copy is the classic accident.
    git check-ignore -q stack/.env.local || { echo 'stack/.env.local would be tracked'; return 1; }
    git check-ignore -q stack/.env.bak   || { echo 'stack/.env.bak would be tracked'; return 1; }
}

@test "the example env file is NOT ignored — it is meant to be tracked" {
    command -v git >/dev/null || skip 'git unavailable'
    cd "$PROJECT"
    run git check-ignore -q stack/.env.example
    [ "$status" -ne 0 ]
}

@test "no real env file is tracked by git" {
    command -v git >/dev/null || skip 'git unavailable'
    cd "$PROJECT"
    local tracked
    tracked=$(git ls-files 'stack/.env*' | grep -v '\.env\.example$' || true)
    [ -z "$tracked" ] || { echo "tracked env files: $tracked"; return 1; }
}

@test "logs and backups are never tracked" {
    command -v git >/dev/null || skip 'git unavailable'
    cd "$PROJECT"
    local tracked
    tracked=$(git ls-files 'logs/*.log' 'backups/teamcity-*' || true)
    [ -z "$tracked" ] || { echo "tracked runtime artifacts: $tracked"; return 1; }
}

# --- administrator bootstrap --------------------------------------------------

@test "a generated admin password satisfies the password validator" {
    load_libs
    local pw
    for _ in 1 2 3 4 5; do
        pw=$(validate::gen_password)
        run validate::db_password "$pw"
        [ "$status" -eq 0 ] || { echo "generated a weak password: $pw"; return 1; }
    done
}

@test "the example env ships an empty admin password" {
    local example="$PROJECT/stack/.env.example"
    grep -qE "^TC_ADMIN_USER='admin'\$"  "$example"
    grep -qE "^TC_ADMIN_PASSWORD=''\$"   "$example"
}

@test "the generated admin password is never written to a log" {
    command -v git >/dev/null || skip 'git unavailable'
    cd "$PROJECT"
    # admin.sh must not hand the password to log::, only to the terminal.
    run grep -nE 'log::[a-z]+ .*\$pass' console/lib/admin.sh
    [ "$status" -ne 0 ]
}

# --- git must work against the bind-mounted checkout ---------------------------
#
# The console runs as root inside the container against a directory owned by the
# user outside it, which git rejects as "dubious ownership". That failed only in
# CI — the local checkout happened to be configured around it — so every push
# was red while `make check` was green. The image declares the directory safe.

@test "git operates on the mounted repository without an ownership complaint" {
    command -v git >/dev/null || skip 'git unavailable'
    cd "$PROJECT"

    run git status --porcelain
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ $output != *"dubious ownership"* ]]
}

# --- the example must stay machine-neutral ------------------------------------
#
# It is tracked and shipped, so it must not carry anything specific to whoever
# last touched it. A stray edit had put a real local timezone in place of UTC,
# which would have handed every new user someone else's clock.

@test "the example ships neutral defaults, not one machine's settings" {
    local ex="${PROJECT:?}/stack/.env.example"

    grep -qE "^TC_TZ='UTC'\$"          "$ex" || { echo 'TC_TZ is not the neutral UTC'; return 1; }
    grep -qE "^TC_STACK='teamcity'\$"  "$ex" || { echo 'TC_STACK is not the default'; return 1; }
    grep -qE "^TC_PORT='8111'\$"       "$ex" || { echo 'TC_PORT is not the default'; return 1; }
    grep -qE "^TC_ADMIN_USER='admin'\$" "$ex" || { echo 'TC_ADMIN_USER is not the default'; return 1; }
}

@test "nothing in the console writes to the example" {
    # It is an input, never an output. A tool that rewrote it would quietly turn
    # one person's configuration into everyone's defaults.
    run grep -rnE '>[[:space:]]*"?\$?\{?EXAMPLE_FILE|>[[:space:]]*.*\.env\.example' "$LIB"
    [ "$status" -ne 0 ] || { echo "$output"; return 1; }
}
