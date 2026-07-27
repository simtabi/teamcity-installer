#!/usr/bin/env bash
#
# doctor.sh — diagnostics.
#
# One screen answering "why isn't this working?" without needing to know which
# docker command to reach for.

doctor::run() {
    ui::scope doctor
    ui::head "Doctor — $TC_STACK"

    doctor::_daemon
    doctor::_containers
    doctor::_http
    doctor::_database
    doctor::_agents
    doctor::_storage
    doctor::_anonymous_volumes

    local state; state=$(stack::state)
    if [[ $state != running ]]; then
        doctor::_logs
    fi

    ui::blank
    ui::note 'Export a shareable bundle from the menu if you need to hand this on.'
}

doctor::_daemon() {
    ui::blank
    ui::info 'Docker'
    ui::note "  daemon    $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo unreachable)"
    ui::note "  compose   $(docker compose version --short 2>/dev/null || echo missing)"
    ui::note "  arch      $(docker version --format '{{.Server.Arch}}' 2>/dev/null || echo unknown)"
    ui::note "  cpus/mem  $(validate::_docker_ncpu) / $(numfmt --to=iec "$(validate::_docker_mem_bytes)" 2>/dev/null || echo '?')B"
}

doctor::_containers() {
    ui::blank
    ui::info 'Containers'

    if ! stack::installed; then
        ui::note '  no stack configured'
        return
    fi

    local json; json=$(stack::compose ps --all --format json 2>/dev/null || true)
    if [[ -z $json ]]; then
        ui::note '  none created'
        return
    fi

    printf '%s\n' "$json" | jq -rs '
        (if type == "array" and (.[0] | type) == "array" then .[0] else . end) | .[]
        | "  \(.Service)\t\(.State)\t\(.Health // "-")\t\(.Status)"' 2>/dev/null \
        | expand -t 20,32,44 >&2
}

doctor::_http() {
    ui::blank
    ui::info 'HTTP'
    local code state
    code=$(stack::_probe /login.html)
    state=$(stack::server_state)

    case $state in
        ready)    ui::note "  $(conf::url)  →  $code, ready" ;;
        setup)    ui::note "  $(conf::url)  →  $code, up but awaiting first-run setup"
                  ui::note '  It will ask for a super user token first. Get it with:  ./tc token' ;;
        starting) ui::note "  $(conf::url)  →  no response (still starting, or not running)" ;;
    esac
}

doctor::_database() {
    [[ $TC_DB == postgres ]] || { ui::blank; ui::info 'Database'; ui::note '  bundled HSQLDB'; return; }

    ui::blank
    ui::info 'Database'
    if stack::compose exec -T db pg_isready -U "$TC_PG_USER" -d "$TC_PG_DB" >/dev/null 2>&1; then
        local ver size
        ver=$(backup::_pg_major)
        size=$(stack::compose exec -T db psql -U "$TC_PG_USER" -d "$TC_PG_DB" -tAc \
            "SELECT pg_size_pretty(pg_database_size('$TC_PG_DB'));" 2>/dev/null | tr -d '[:space:]')
        ui::note "  PostgreSQL $ver, accepting connections"
        ui::note "  database size  ${size:-unknown}"
    else
        ui::note '  not accepting connections'
    fi
}

doctor::_agents() {
    ui::blank
    ui::info 'Agents'

    if ! conf::token >/dev/null 2>&1; then
        ui::note "  configured: $TC_AGENTS  (store an access token to see server-side state)"
        return
    fi

    local json
    json=$(agents::_rest GET '/app/rest/agents?locator=defaultFilter:false&fields=count,agent(connected,authorized)' 2>/dev/null) \
        || { ui::note '  REST unavailable'; return; }

    local total connected authorized
    total=$(printf '%s' "$json" | jq -r '.count // 0')
    connected=$(printf '%s' "$json" | jq -r '[.agent[]? | select(.connected)] | length')
    authorized=$(printf '%s' "$json" | jq -r '[.agent[]? | select(.authorized)] | length')

    ui::note "  configured $TC_AGENTS · known $total · connected $connected · authorized $authorized"

    if (( authorized > TC_FREE_AGENTS )); then
        ui::warn "  $authorized authorized exceeds the free licence ($TC_FREE_AGENTS) — the build queue is paused"
    fi
    if (( connected < TC_AGENTS )); then
        ui::warn "  $(( TC_AGENTS - connected )) agent(s) not connected"
        ui::note '  Check SERVER_URL points at http://server:8111, not localhost.'
    fi
}

doctor::_storage() {
    ui::blank
    ui::info 'Volumes'

    local -a volumes; mapfile -t volumes < <(render::volume_names 2>/dev/null)
    local vol total=0

    for vol in "${volumes[@]}"; do
        docker volume inspect "$vol" >/dev/null 2>&1 || continue
        total=$(( total + 1 ))
    done

    ui::note "  $total of ${#volumes[@]} expected volume(s) exist"

    # The Type is "Local Volumes", two words, so splitting on whitespace and
    # taking field 2 yields the literal word "Volumes".
    local used
    used=$(docker system df --format '{{.Type}}|{{.Size}}' 2>/dev/null \
        | awk -F'|' '$1 == "Local Volumes" {print $2}' | head -1)
    # Same trap as backup::_cold: a trailing `&&` would make this function return
    # non-zero whenever the size could not be read, aborting doctor under set -e.
    if [[ -n ${used:-} ]]; then
        ui::note "  docker volume usage overall  $used"
    fi

    return 0
}

# An anonymous volume is what Docker creates for a declared VOLUME left
# unmapped, so a non-zero count here means the renderer has regressed.
#
# Scoped to this stack's own containers on purpose. A daemon-wide dangling count
# picks up volumes from every other project on the machine, which is both noise
# and not ours to comment on.
doctor::_anonymous_volumes() {
    ui::blank
    ui::info 'Anonymous volumes'

    local -a containers
    mapfile -t containers < <(stack::compose ps --all --quiet 2>/dev/null)

    if (( ${#containers[@]} == 0 )); then
        ui::note '  no containers to inspect'
        return
    fi

    local count=0 c
    for c in "${containers[@]}"; do
        count=$(( count + $(docker inspect "$c" \
            -f '{{range .Mounts}}{{if eq .Type "volume"}}{{.Name}}{{"\n"}}{{end}}{{end}}' 2>/dev/null \
            | grep -cE '^[0-9a-f]{64}$' || true) ))
    done

    if (( count == 0 )); then
        ui::note '  none — every volume this stack declares is mapped by name'
    else
        ui::warn "  $count anonymous volume(s) attached to this stack"
        ui::note '  A VOLUME declared by one of the images is going unmapped;'
        ui::note '  its contents are discarded on every recreate.'
    fi
}

doctor::_logs() {
    ui::blank
    ui::info 'Recent server log'
    stack::compose logs --tail 50 server 2>&1 | sed 's/^/  /' >&2 || ui::note '  unavailable'
}

# --- bundle -------------------------------------------------------------------

doctor::bundle() {
    ui::scope doctor
    mkdir -p "$BACKUP_DIR"
    local name; name="diagnostics-$(date +%Y%m%d-%H%M%S)"
    local dir="$BACKUP_DIR/$name"
    mkdir -p "$dir"

    ui::spin 'Collecting diagnostics' -- bash -c "
        {
            echo '== docker info =='   ; docker info 2>&1
            echo; echo '== compose ps =='; docker compose --file '$COMPOSE_FILE' --project-directory '$STACK_DIR' --env-file '$ENV_FILE' ps --all 2>&1
            echo; echo '== volumes =='  ; docker volume ls 2>&1
            echo; echo '== disk =='     ; docker system df -v 2>&1
        } > '$dir/environment.txt' 2>&1

        docker compose --file '$COMPOSE_FILE' --project-directory '$STACK_DIR' --env-file '$ENV_FILE' \
            logs --tail 2000 > '$dir/compose.log' 2>&1 || true

        cp '$COMPOSE_FILE' '$dir/docker-compose.yml' 2>/dev/null || true
        sed 's/^TC_PG_PASSWORD=.*/TC_PG_PASSWORD=<redacted>/' '$ENV_FILE' > '$dir/env.txt' 2>/dev/null || true
    "

    ui::ok "Bundle written to backups/$name"
    ui::note 'Passwords are redacted and the access token is not included.'
}
