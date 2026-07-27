#!/usr/bin/env bats
#
# Configuration round-tripping.
#
# This file exists because stack/.env once meant two different things: Compose
# read TC_MEM_OPTS='-Xmx2g -XX:ReservedCodeCacheSize=640m' as one value, while
# bash `source` read it as an assignment followed by a command and tried to run
# "-XX:ReservedCodeCacheSize=640m".

load helper

setup() { load_libs; default_conf; }

@test "a value containing spaces survives save and load" {
    conf::save
    TC_MEM_OPTS='clobbered'
    conf::load
    [ "$TC_MEM_OPTS" = '-Xmx2g -XX:ReservedCodeCacheSize=640m' ]
}

@test "every setting survives a round trip" {
    conf::save
    local stack=$TC_STACK version=$TC_VERSION port=$TC_PORT pw=$TC_PG_PASSWORD agents=$TC_AGENTS
    TC_STACK=x TC_VERSION=x TC_PORT=x TC_PG_PASSWORD=x TC_AGENTS=x
    conf::load
    [ "$TC_STACK" = "$stack" ]
    [ "$TC_VERSION" = "$version" ]
    [ "$TC_PORT" = "$port" ]
    [ "$TC_PG_PASSWORD" = "$pw" ]
    [ "$TC_AGENTS" = "$agents" ]
}

@test "loading does not execute the file" {
    conf::save
    printf "TC_STACK='pwned'\ntouch %s/EXECUTED\n" "$BATS_TEST_TMPDIR" >> "$ENV_FILE"
    conf::load
    [ ! -e "$BATS_TEST_TMPDIR/EXECUTED" ]
}

@test "malformed lines are skipped, not fatal" {
    conf::save
    printf '\nnot a setting\n# comment\n   \n' >> "$ENV_FILE"
    run conf::load
    [ "$status" -eq 0 ]
}

@test "keys that are not valid identifiers are ignored" {
    printf "%s\n" "TC_STACK='ok'" "rm -rf /=1" "2BAD='x'" > "$ENV_FILE"
    conf::load
    [ "$TC_STACK" = 'ok' ]
}

@test "the env file is written owner-only" {
    conf::save
    [ "$(stat -c '%a' "$ENV_FILE")" = '600' ]
}

@test "a value containing a quote round-trips" {
    TC_TZ="Europe/Berlin"
    conf::save
    conf::load
    [ "$TC_TZ" = 'Europe/Berlin' ]
}

@test "agent tag follows image and docker mode" {
    TC_AGENT_IMAGE=full   TC_AGENT_DOCKER=none
    [ "$(conf::agent_tag)" = 'jetbrains/teamcity-agent:2026.1.3' ]

    TC_AGENT_IMAGE=minimal TC_AGENT_DOCKER=none
    [ "$(conf::agent_tag)" = 'jetbrains/teamcity-minimal-agent:2026.1.3' ]

    # Docker-in-Docker needs the sudo variant regardless of the image choice.
    TC_AGENT_IMAGE=minimal TC_AGENT_DOCKER=dind
    [ "$(conf::agent_tag)" = 'jetbrains/teamcity-agent:2026.1.3-linux-sudo' ]
}
