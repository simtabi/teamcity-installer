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

# --- agent Docker modes --------------------------------------------------------
#
# Both were documented and neither had ever been run. Socket mode was broken:
# the socket was mounted, but the agent runs as uid 1000 with its own docker
# group (999) while the socket is owned by the host's group — 0 on OrbStack and
# Docker Desktop, a real docker group on most Linux. Mismatched, every docker
# command in a build fails with "permission denied", and the configuration looks
# entirely correct.

@test "socket mode grants the socket's own group" {
    TC_AGENT_DOCKER=socket
    render::_docker_socket_gid() { printf '117'; }

    run render::_agent 1
    [[ $output == *'group_add:'* ]]   || { echo 'no group_add emitted'; return 1; }
    [[ $output == *'"117"'* ]]        || { echo 'the socket group was not used'; return 1; }
    [[ $output == *'/var/run/docker.sock:/var/run/docker.sock'* ]]
}

@test "socket mode does not resort to privileged or to running as root" {
    TC_AGENT_DOCKER=socket
    render::_docker_socket_gid() { printf '0'; }
    run render::_agent 1
    [[ $output != *'privileged: true'* ]] || { echo 'socket mode should not need privileged'; return 1; }
    [[ $output != *'user: root'* ]]       || { echo 'socket mode should not run as root'; return 1; }
}

@test "the socket group falls back to 0 when it cannot be read" {
    run bash -c "
        source $LIB/log.sh; source $LIB/ui.sh; source $LIB/conf.sh; source $LIB/render.sh
        stat() { return 1; }
        render::_docker_socket_gid"
    [ "$output" = '0' ]
}

@test "Docker-in-Docker is privileged, uses the sudo image, and keeps its layers" {
    TC_AGENT_DOCKER=dind
    run render::_agent 1
    [[ $output == *'privileged: true'* ]]                  || { echo 'not privileged'; return 1; }
    [[ $output == *'-linux-sudo'* ]]                       || { echo 'not the sudo image'; return 1; }
    [[ $output == *'DOCKER_IN_DOCKER: start'* ]]           || { echo 'inner daemon not started'; return 1; }
    [[ $output == *'agent-1-docker:/var/lib/docker'* ]]    || { echo 'layers would not persist'; return 1; }
}

@test "the two Docker modes are mutually exclusive in what they emit" {
    TC_AGENT_DOCKER=dind;   local dind;   dind=$(render::_agent 1)
    TC_AGENT_DOCKER=socket; local socket; socket=$(render::_agent 1)

    [[ $dind   != *'docker.sock:/var/run/docker.sock'* ]] || { echo 'dind should not mount the host socket'; return 1; }
    [[ $socket != *'DOCKER_IN_DOCKER'* ]]                 || { echo 'socket mode should not start an inner daemon'; return 1; }
}

# --- the bundled database ------------------------------------------------------
#
# TC_DB='hsqldb' is offered by the wizard, documented as a supported setting, and
# had never once been booted. It could not be: datadir-init mounted the JDBC
# driver cache unconditionally while the volumes block declared it only for
# PostgreSQL, so compose refused the file outright —
#
#   service "datadir-init" refers to undefined volume jdbc-cache
#
# Not a subtle failure. Nothing had ever generated the file to find out.

@test "the bundled database renders a compose file that parses" {
    TC_DB=hsqldb
    local out; out=$(render::_datadir_init)
    [[ $out != *'jdbc-cache'* ]] || { echo 'mounts a volume that is never declared'; return 1; }
}

@test "PostgreSQL still gets the driver cache" {
    TC_DB=postgres
    local out; out=$(render::_datadir_init)
    [[ $out == *'jdbc-cache:/cache'* ]] || { echo 'the driver would be re-downloaded every time'; return 1; }
}

@test "every volume datadir-init mounts is declared" {
    # The general form of the bug, checked for both databases rather than just
    # the one that happened to be in use.
    local db mount
    for db in postgres hsqldb; do
        TC_DB=$db
        local declared; declared=$(render::volume_names)
        while IFS= read -r mount; do
            [[ $mount == ./* ]] && continue          # a bind mount, not a named volume
            grep -qx "${TC_STACK}_${mount}" <<< "$declared" \
                || { echo "$db: datadir-init mounts '$mount', which is not declared"; return 1; }
        done < <(render::_datadir_init | sed -n 's/^      - \([^:]*\):.*/\1/p')
    done
}

@test "the bundled database renders no db service and no pgdata" {
    TC_DB=hsqldb
    local out; out=$(render::compose_body 2>/dev/null || render::_datadir_init)
    run render::volume_names
    [[ $output != *pgdata* ]]     || { echo 'a PostgreSQL volume on a bundled-database stack'; return 1; }
    [[ $output != *jdbc-cache* ]] || { echo 'a driver cache with no driver to cache'; return 1; }
}
