#!/usr/bin/env bats
#
# Volume mapping.
#
# This file exists because of a bug that shipped: /var/lib/docker is declared by
# the full agent image but was only mapped under Docker-in-Docker, so a default
# three-agent stack silently leaked three anonymous volumes. Every declared
# VOLUME must be mapped by name, or its contents are discarded on each recreate.

load helper

setup() { load_libs; default_conf; }

# The server image declares exactly these three.
@test "server maps all three declared volumes" {
    run render::_volume_lines TC_SERVER_VOLUMES ''
    [ "$status" -eq 0 ]
    [[ $output == *"/data/teamcity_server/datadir"* ]]
    [[ $output == *"/opt/teamcity/logs"* ]]
    [[ $output == *"/opt/teamcity/temp"* ]]
    [ "$(printf '%s\n' "$output" | grep -c ':')" -eq 3 ]
}

@test "full agent maps all eight declared volumes including /var/lib/docker" {
    TC_AGENT_IMAGE=full
    run render::_agent 1
    [ "$status" -eq 0 ]
    for path in /data/teamcity_agent/conf /opt/buildagent/work /opt/buildagent/system \
                /opt/buildagent/temp /opt/buildagent/logs /opt/buildagent/tools \
                /opt/buildagent/plugins /var/lib/docker; do
        [[ $output == *"$path"* ]] || { echo "missing mapping: $path"; return 1; }
    done
}

@test "docker volume is mapped even when Docker-in-Docker is off" {
    TC_AGENT_IMAGE=full
    TC_AGENT_DOCKER=none
    run render::_agent 1
    [[ $output == *"agent-1-docker:/var/lib/docker"* ]]
}

@test "minimal agent does not map a docker volume it never declares" {
    TC_AGENT_IMAGE=minimal
    TC_AGENT_DOCKER=none
    run render::_agent 1
    [[ $output != *"/var/lib/docker"* ]]
}

@test "volume_names matches what the compose file declares" {
    # 3 server + pgdata + jdbc-cache + 3 agents x 8
    TC_AGENTS=3
    run render::volume_names
    [ "$(printf '%s\n' "$output" | grep -c .)" -eq 29 ]
}

@test "volume_names scales with agent count" {
    TC_AGENTS=1
    run render::volume_names
    [ "$(printf '%s\n' "$output" | grep -c .)" -eq 13 ]
}

@test "every volume name is namespaced by the stack" {
    TC_STACK=other
    run render::volume_names
    while IFS= read -r v; do
        [[ $v == other_* ]] || { echo "not namespaced: $v"; return 1; }
    done <<< "$output"
}

@test "hsqldb stack declares no database volumes" {
    TC_DB=hsqldb
    run render::volume_names
    [[ $output != *pgdata* ]]
    [[ $output != *jdbc-cache* ]]
}
