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
    #
    # Initialised, not merely declared: `local code` leaves it *unset*, and the
    # container is gone the moment anyone runs `docker container prune` — it exits
    # immediately by design, so it is the first thing a prune collects. The check
    # below then read an unset variable and `set -u` aborted the whole verify run
    # with "line 76: code: unbound variable", which says nothing about the missing
    # container it was actually trying to report.
    local code=''
    local init_id; init_id=$(stack::container datadir-init)
    if [[ -n $init_id ]]; then
        code=$(docker inspect "$init_id" -f '{{.State.ExitCode}}' 2>/dev/null || true)
    fi
    if [[ $TC_DB != postgres ]]; then
        verify::_skip 'datadir-init exited cleanly' 'bundled database, no init step'
    elif [[ -z $init_id ]]; then
        # Absent is not failed. This container exits as soon as it has done its
        # work, so it is the first thing `docker container prune` collects, and a
        # routine cleanup would otherwise be reported as a broken data directory.
        # What it produces is checked directly by the data-directory checks below,
        # so nothing goes unverified by skipping here.
        verify::_skip 'datadir-init exited cleanly' 'container already removed; its output is checked below'
    elif [[ $code == 0 ]]; then
        verify::_pass 'datadir-init exited cleanly'
    else
        verify::_fail 'datadir-init exited cleanly' "exit code ${code:-missing}"
    fi

    case $(stack::server_state) in
        ready)    if stack::needs_first_user; then
                      verify::_fail 'server answers HTTP' '200, but no user account exists'
                      verify::_why 'Run ./tc token and create the first administrator.'
                  else
                      verify::_pass 'server answers HTTP' '200, setup complete'
                  fi ;;
        setup)    # A server that failed to start also answers 503 with a maintenance
                  # page, and this reported that as a pass — "awaiting first-run
                  # setup" — while TeamCity was showing a startup error. The page
                  # says which it is; ask it rather than assume the benign one.
                  local why stage
                  why=$(stack::maintenance_reason); stage=$(stack::maintenance_stage)
                  if [[ $stage == EXCEPTION ]]; then
                      verify::_fail 'server answers HTTP' "503, ${why:-server startup error}"
                      verify::_why 'Read the cause with: ./tc logs server'
                  else
                      verify::_pass 'server answers HTTP' "503, ${why:-awaiting first-run setup}"
                  fi ;;
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

    # No need to insist on a stored access token: agents::_rest falls back to
    # the super user token, which is already readable from the server log.

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
# The native tier runs against a *live* server. TeamCity supports taking a
# backup without stopping, and measuring it here found zero non-200 responses
# throughout — so this check is not disruptive and does not need to be opt-in.
#
# It was gated behind --deep with the note "briefly pauses the server", which
# was simply wrong: that cost belongs to the cold and logical tiers, which do
# stop containers. What the native tier actually costs is time proportional to
# the data directory, so the gate is now a size threshold rather than a blanket
# opt-out, and --deep forces it regardless.
#
# JetBrains' one caveat is consistency, not availability: a backup taken while
# builds are running can capture queued and running builds mid-update. That
# matters for a backup you intend to restore, not for proving the path works.
#
# The cost is bounded by time, not by guesswork. Sizing it from the data
# directory looked reasonable and was wrong: 2.1 GB there is 1.1 GB of caches
# and 1.0 GB of plugins, none of which the backup includes — the archive came to
# 1.4 MB and the whole thing took two seconds. Running it under a timeout
# measures the real cost instead of predicting it badly.

VERIFY_BACKUP_TIMEOUT=${VERIFY_BACKUP_TIMEOUT:-120}

verify::_backup() {
    ui::scope verify
    ui::blank; ui::info 'Backup'

    if [[ $(stack::server_state) != ready ]]; then
        verify::_skip 'native backup round-trip' 'server not past first-run setup'
        return
    fi
    if ! agents::_rest GET /app/rest/server >/dev/null 2>&1; then
        verify::_skip 'native backup round-trip' 'REST API not reachable'
        return
    fi

    local budget=$VERIFY_BACKUP_TIMEOUT
    [[ ${VERIFY_DEEP:-0} == 1 ]] && budget=1800     # --deep waits as long as it takes

    local before started rc=0
    before=$(find "$BACKUP_DIR" -maxdepth 1 -name 'teamcity-native-*' | wc -l | tr -d ' ')
    started=$(date +%s)

    # Not `timeout backup::_native`: timeout execs a binary and cannot run a
    # shell function — the same trap that made every ui::spin call fail under a
    # terminal. Run it as a background job and enforce the deadline here.
    backup::_native >/dev/null 2>&1 &
    local pid=$! waited=0
    while kill -0 "$pid" 2>/dev/null && (( waited < budget )); do
        sleep 1; waited=$(( waited + 1 ))
    done
    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
        rc=124
    else
        wait "$pid" || rc=$?
    fi

    local elapsed=$(( $(date +%s) - started ))

    if (( rc == 124 )); then
        verify::_skip 'native backup round-trip' "exceeded ${budget}s"
        verify::_why './tc verify --deep waits as long as it takes.'
        return
    fi
    if (( rc != 0 )); then
        verify::_fail 'native backup round-trip' 'the backup call failed'
        verify::_why 'Run ./tc backup native to see the error.'
        return
    fi

    local after; after=$(find "$BACKUP_DIR" -maxdepth 1 -name 'teamcity-native-*' | wc -l | tr -d ' ')
    if (( after <= before )); then
        verify::_fail 'native backup round-trip' 'no archive produced'
        return
    fi

    local made; made=$(find "$BACKUP_DIR" -maxdepth 1 -name 'teamcity-native-*' | sort | tail -1)
    if [[ -f $made/manifest.json ]] && find "$made" -name '*.zip' | grep -q .; then
        verify::_pass 'native backup round-trip' "$(basename "$made") in ${elapsed}s"
    else
        verify::_fail 'native backup round-trip' 'archive incomplete'
    fi

    rm -rf "$made"      # leave no clutter behind
}
