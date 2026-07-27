#!/usr/bin/env bash
#
# verify.sh — live end-to-end verification against a running stack.
#
# The counterpart to `./tc test`. That suite is pure and fast and proves the
# logic; this one proves the *stack* — that the volumes really are mapped, the
# timezone really did take, the database really was seeded, and the REST paths
# really work against this TeamCity build.
#
# Everything that was once "verified by hand once, then forgotten" lives here so
# it is re-run on demand instead of drifting.
#
# Checks that cannot run yet SKIP with the reason and the command to fix it —
# they are never silently passed. The exit code counts failures only, so an
# incomplete first-run setup does not read as broken.

VERIFY_PASS=0
VERIFY_FAIL=0
VERIFY_SKIP=0

verify::_pass() { ui::row_pass "$1" "${2:-}"; VERIFY_PASS=$((VERIFY_PASS+1)); }
verify::_fail() { ui::row_fail "$1" "${2:-}"; VERIFY_FAIL=$((VERIFY_FAIL+1)); }
verify::_skip() { ui::row_skip "$1" "${2:-}"; VERIFY_SKIP=$((VERIFY_SKIP+1)); }
verify::_why()  { ui::hint "$1"; }

verify::run() {
    ui::scope verify
    VERIFY_PASS=0; VERIFY_FAIL=0; VERIFY_SKIP=0

    stack::installed || { ui::err 'No stack configured. Run the guided setup first.'; return 1; }

    ui::head "Verify — $TC_STACK"
    ui::note 'Live checks against the running stack. ./tc test covers the pure logic.'

    verify::_stack
    verify::_volumes
    verify::_timezone
    verify::_database
    verify::_rest
    verify::_backup

    ui::blank
    local total=$(( VERIFY_PASS + VERIFY_FAIL + VERIFY_SKIP ))
    if (( VERIFY_FAIL > 0 )); then
        ui::err "$VERIFY_FAIL of $total checks failed ($VERIFY_PASS passed, $VERIFY_SKIP skipped)."
        return 1
    fi
    if (( VERIFY_SKIP > 0 )); then
        ui::ok "$VERIFY_PASS passed, $VERIFY_SKIP skipped, 0 failed."
        ui::note 'Skipped checks need a prerequisite — each says which above.'
        return 0
    fi
    ui::ok "All $total checks passed."
}

# --- stack --------------------------------------------------------------------

verify::_stack() {
    ui::blank; ui::info 'Stack'

    local state; state=$(stack::state)
    case $state in
        running) verify::_pass 'all services running' ;;
        *)       verify::_fail 'all services running' "state is $state"
                 verify::_why 'Start it with: ./tc up' ; return ;;
    esac

    # datadir-init must have succeeded, or the datadir was never seeded.
    local code
    local init_id; init_id=$(stack::container datadir-init)
    if [[ -n $init_id ]]; then
        code=$(docker inspect "$init_id" -f '{{.State.ExitCode}}' 2>/dev/null || true)
    fi
    if [[ $TC_DB != postgres ]]; then
        verify::_skip 'datadir-init exited cleanly' 'bundled database, no init step'
    elif [[ $code == 0 ]]; then
        verify::_pass 'datadir-init exited cleanly'
    else
        verify::_fail 'datadir-init exited cleanly' "exit code ${code:-missing}"
    fi

    case $(stack::server_state) in
        ready)    verify::_pass 'server answers HTTP' '200, setup complete' ;;
        setup)    verify::_pass 'server answers HTTP' '503, awaiting first-run setup' ;;
        starting) verify::_fail 'server answers HTTP' 'no response' ;;
    esac
}

# --- volumes ------------------------------------------------------------------
#
# The regression that shipped once: an unmapped VOLUME silently becomes an
# anonymous volume, discarding agent caches on every recreate.

verify::_volumes() {
    ui::blank; ui::info 'Volumes'

    local -a expected; mapfile -t expected < <(render::volume_names)
    local missing=0 vol
    for vol in "${expected[@]}"; do
        docker volume inspect "$vol" >/dev/null 2>&1 || missing=$((missing+1))
    done

    if (( missing == 0 )); then
        verify::_pass 'every expected volume exists' "${#expected[@]} volumes"
    else
        verify::_fail 'every expected volume exists' "$missing missing"
    fi

    local -a containers; mapfile -t containers < <(stack::compose ps --all --quiet 2>/dev/null)
    local anon=0 c
    for c in "${containers[@]}"; do
        anon=$(( anon + $(docker inspect "$c" \
            -f '{{range .Mounts}}{{if eq .Type "volume"}}{{.Name}}{{"\n"}}{{end}}{{end}}' 2>/dev/null \
            | grep -cE '^[0-9a-f]{64}$' || true) ))
    done

    if (( anon == 0 )); then
        verify::_pass 'no anonymous volumes' 'all declared VOLUMEs mapped by name'
    else
        verify::_fail 'no anonymous volumes' "$anon leaking"
        verify::_why 'A VOLUME the image declares is going unmapped in render.sh.'
    fi

    # Per-agent count, since that is where the leak was.
    if (( TC_AGENTS > 0 )); then
        local want=7; render::_agent_has_docker_volume && want=8
        local n got bad=0
        for (( n = 1; n <= TC_AGENTS; n++ )); do
            local aid; aid=$(stack::container "agent-$n")
            got=0
            if [[ -n $aid ]]; then
                got=$(docker inspect "$aid" \
                    -f '{{range .Mounts}}{{if eq .Type "volume"}}x{{end}}{{end}}' 2>/dev/null \
                    | tr -cd x | wc -c | tr -d ' ')
            fi
            [[ $got == "$want" ]] || bad=$((bad+1))
        done
        if (( bad == 0 )); then
            verify::_pass 'each agent maps its full volume set' "$want per agent"
        else
            verify::_fail 'each agent maps its full volume set' "$bad agent(s) short of $want"
        fi
    fi
}

# --- timezone -----------------------------------------------------------------
#
# The agent image hardcodes TZ=Europe/London. Unset, every build timestamp is
# wrong, and nothing announces it.

verify::_timezone() {
    ui::blank; ui::info 'Timezone'

    local -a services=(server); local n
    for (( n = 1; n <= TC_AGENTS; n++ )); do services+=("agent-$n"); done
    [[ $TC_DB == postgres ]] && services+=(db)

    local bad=0 svc actual
    for svc in "${services[@]}"; do
        local cid; cid=$(stack::container "$svc")
        actual=''
        if [[ -n $cid ]]; then
            actual=$(docker exec "$cid" printenv TZ 2>/dev/null || true)
        fi
        [[ $actual == "$TC_TZ" ]] || { bad=$((bad+1)); verify::_why "$svc has TZ='${actual:-unset}'"; }
    done

    if (( bad == 0 )); then
        verify::_pass 'every container uses the configured zone' "$TC_TZ"
    else
        verify::_fail 'every container uses the configured zone' "$bad of ${#services[@]} wrong"
    fi
}

# --- database -----------------------------------------------------------------

verify::_database() {
    ui::blank; ui::info 'Database'

    if [[ $TC_DB != postgres ]]; then
        verify::_skip 'PostgreSQL checks' 'stack uses the bundled database'
        return
    fi

    if stack::compose exec -T db pg_isready -U "$TC_PG_USER" -d "$TC_PG_DB" >/dev/null 2>&1; then
        verify::_pass 'database accepting connections' "PostgreSQL $(backup::_pg_major)"
    else
        verify::_fail 'database accepting connections'
        return
    fi

    # The seeding that lets TeamCity skip its database wizard.
    if docker run --rm -v "$(conf::volume datadir)":/d:ro alpine:3.22 \
            sh -c 'ls /d/lib/jdbc/postgresql-*.jar' >/dev/null 2>&1; then
        verify::_pass 'JDBC driver seeded into the data directory'
    else
        verify::_fail 'JDBC driver seeded into the data directory'
    fi

    if docker run --rm -v "$(conf::volume datadir)":/d:ro alpine:3.22 \
            grep -q '^connectionUrl=jdbc:postgresql://db:5432/' /d/config/database.properties 2>/dev/null; then
        verify::_pass 'database.properties points at the stack network'
    else
        verify::_fail 'database.properties points at the stack network'
    fi

    if docker run --rm -v "$(conf::volume logs)":/l:ro alpine:3.22 \
            grep -q 'Bypassing asking a user for DB settings' /l/teamcity-server.log 2>/dev/null; then
        verify::_pass 'TeamCity skipped its database setup step'
    else
        verify::_skip 'TeamCity skipped its database setup step' 'not yet in the log'
    fi

    # uid 1000 (tcuser) must be able to write throughout, or first boot fails.
    if docker run --rm -u 1000:1000 -v "$(conf::volume datadir)":/d alpine:3.22 \
            sh -c 'touch /d/.verify-write && rm -f /d/.verify-write' >/dev/null 2>&1; then
        verify::_pass 'data directory writable by uid 1000'
    else
        verify::_fail 'data directory writable by uid 1000'
        verify::_why 'The seed step must chown to 1000:1000 on the way out.'
    fi
}

# --- REST ---------------------------------------------------------------------
#
# Needs an access token, which needs an administrator account, which needs
# someone to have accepted the licence. Skips loudly rather than failing.

verify::_rest() {
    ui::blank; ui::info 'REST and agents'

    if [[ $(stack::server_state) == setup ]]; then
        verify::_skip 'REST API reachable' 'first-run setup not finished'
        verify::_why "Run ./tc token, then complete setup at $(conf::url)"
        verify::_skip 'agents authorized' 'needs an administrator account'
        return
    fi

    if ! conf::token >/dev/null 2>&1; then
        verify::_skip 'REST API reachable' 'no access token stored'
        verify::_why 'Store one with: ./tc authorize'
        verify::_skip 'agents authorized' 'needs an access token'
        return
    fi

    local server_json
    if server_json=$(agents::_rest GET /app/rest/server 2>/dev/null); then
        verify::_pass 'REST API reachable' "$(printf '%s' "$server_json" | jq -r '.version // "?"')"
    else
        verify::_fail 'REST API reachable' 'token rejected or API unavailable'
        return
    fi

    local reported
    reported=$(printf '%s' "$server_json" | jq -r '.buildNumber // ""')
    if [[ -n $reported ]]; then
        verify::_pass 'server reports its build number' "$reported"
    fi

    local agent_json
    if ! agent_json=$(agents::_rest GET '/app/rest/agents?locator=defaultFilter:false&fields=count,agent(connected,authorized)' 2>/dev/null); then
        verify::_fail 'agent list retrievable'
        return
    fi

    local known connected authorized
    known=$(printf '%s' "$agent_json" | jq -r '.count // 0')
    connected=$(printf '%s' "$agent_json" | jq -r '[.agent[]? | select(.connected)] | length')
    authorized=$(printf '%s' "$agent_json" | jq -r '[.agent[]? | select(.authorized)] | length')

    if (( connected >= TC_AGENTS )); then
        verify::_pass 'every configured agent is connected' "$connected/$TC_AGENTS"
    else
        verify::_fail 'every configured agent is connected' "$connected/$TC_AGENTS"
        verify::_why 'Check SERVER_URL is http://server:8111, not localhost.'
    fi

    if (( authorized >= TC_AGENTS )); then
        verify::_pass 'every configured agent is authorized' "$authorized/$known"
    else
        verify::_fail 'every configured agent is authorized' "$authorized/$known"
        verify::_why 'Authorize them with: ./tc authorize'
    fi

    if (( authorized > TC_FREE_AGENTS )); then
        verify::_fail 'authorized agents within the free licence' "$authorized > $TC_FREE_AGENTS"
        verify::_why 'TeamCity pauses the whole build queue above the licensed count.'
    else
        verify::_pass 'authorized agents within the free licence' "$authorized/$TC_FREE_AGENTS"
    fi
}

# --- backup -------------------------------------------------------------------
#
# Exercises the native tier for real, then removes what it made. Opt-in with
# --deep because it stops the server briefly and writes to backups/.

verify::_backup() {
    ui::blank; ui::info 'Backup'

    if [[ ${VERIFY_DEEP:-0} != 1 ]]; then
        verify::_skip 'native backup round-trip' 'deep check'
        verify::_why 'Run ./tc verify --deep to exercise it (briefly pauses the server).'
        return
    fi

    if [[ $(stack::server_state) != ready ]] || ! conf::token >/dev/null 2>&1; then
        verify::_skip 'native backup round-trip' 'needs a set-up server and an access token'
        return
    fi

    local before; before=$(find "$BACKUP_DIR" -maxdepth 1 -name 'teamcity-native-*' | wc -l | tr -d ' ')
    if backup::_native >/dev/null 2>&1; then
        local after; after=$(find "$BACKUP_DIR" -maxdepth 1 -name 'teamcity-native-*' | wc -l | tr -d ' ')
        if (( after > before )); then
            local made; made=$(find "$BACKUP_DIR" -maxdepth 1 -name 'teamcity-native-*' | sort | tail -1)
            if [[ -f $made/manifest.json ]] && find "$made" -name '*.zip' | grep -q .; then
                verify::_pass 'native backup round-trip' "$(basename "$made")"
            else
                verify::_fail 'native backup round-trip' 'archive incomplete'
            fi
            rm -rf "$made"        # leave no clutter behind
        else
            verify::_fail 'native backup round-trip' 'no archive produced'
        fi
    else
        verify::_fail 'native backup round-trip' 'the backup call failed'
    fi
}
